import AppKit
import ApplicationServices
import AVFoundation
import DictationCore
import ServiceManagement

/// Owns dictation, sign-in, permissions, shortcut, and preferences for every view.
@MainActor
final class AppModel: NSObject, ObservableObject {
    let preferences: AppPreferences
    let history: TranscriptionHistory

    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var connection: ConnectionStatus = .checking
    @Published private(set) var cliAvailable = CodexAuthentication.cliAvailable
    @Published private(set) var authError: String?
    @Published private(set) var microphone = PermissionStatus(AudioCapture.microphoneStatus)
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published private(set) var accessibilityTrusted = AccessibilityPermission.check()
    @Published private(set) var hotkeyError: String?
    @Published private(set) var toggleHotkeyError: String?
    /// True when the last shortcut failed because a macOS shortcut, such as Spotlight, owns it.
    @Published private(set) var hotkeyBlockedBySystem = false
    @Published private(set) var isCapturingShortcut = false
    @Published private(set) var shortcutTestStatus: ShortcutTestStatus = .idle
    @Published private(set) var launchAtLogin = LaunchAtLoginStatus.current()
    @Published private(set) var launchAtLoginError: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    /// The last successful transcript. Memory only.
    @Published private(set) var lastTranscript: String?
    @Published private(set) var practiceTranscript: String?
    @Published private(set) var isPracticeSession = false

    private let audio: AudioCapture
    private let availableInputDevices: () -> [AudioInputDevice]
    private var inputDeviceMonitor: AudioInputDeviceMonitor?
    private let paste: PasteCoordinator
    private let transcribeAudio: @Sendable (URL) async throws -> String
    private var shortcut: GlobalShortcut?
    private var toggleShortcut: GlobalShortcut?
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var signInTask: Task<Void, Never>?
    private var activeAudio: URL?
    private var failedAudio: URL?
    private var meterTimer: Timer?
    private var permissionRefresh: Task<Void, Never>?
    private var isPracticingInOnboarding = false
    private var holdState = HoldToDictateState()
    private var toggleOwnsRecording = false
    private var stopToggleWhenReady = false

    static let installCodexURL = URL(string: "https://developers.openai.com/codex/cli/")!

    init(preferences: AppPreferences? = nil, pasteboard: NSPasteboard? = nil,
         history: TranscriptionHistory? = nil,
         inputDeviceProvider: AudioInputDeviceProvider? = nil,
         transcribeAudio: @escaping @Sendable (URL) async throws -> String = {
             try await TranscriptionClient().transcribe(file: $0)
         }) {
        self.preferences = preferences ?? AppPreferences()
        self.availableInputDevices = inputDeviceProvider?.snapshot ?? AudioInputDevices.available
        self.history = history ?? TranscriptionHistory()
        self.transcribeAudio = transcribeAudio
        audio = AudioCapture()
        paste = PasteCoordinator(pasteboard: pasteboard ?? .general)
        super.init()
        inputDeviceMonitor = AudioInputDeviceMonitor { [weak self] in self?.refreshInputDevices() }
        audio.onMaximumDuration = { [weak self] url in self?.captureEnded(url: url) }
        audio.onFailure = { [weak self] error, url in self?.captureFailed(error, url: url) }
        shortcut = GlobalShortcut(onPress: { [weak self] in self?.receiveGlobalShortcut() },
                                  onRelease: { [weak self] in self?.releaseGlobalShortcut() },
                                  onCancel: { [weak self] in self?.cancelHeldShortcut() },
                                  onToggle: { [weak self] in self?.receiveFunctionToggle() })
        toggleShortcut = GlobalShortcut(onPress: { [weak self] in self?.receiveToggleShortcut() })
        shortcut?.mode = self.preferences.shortcutMode
        shortcut?.doubleTapToToggle = self.preferences.doubleTapFnToToggle
        refreshStatus()
    }

    // MARK: Derived state

    var statusText: String { phase.statusText }
    var canStart: Bool { !phase.isBusy && !paste.isLeasePending }
    var canRetry: Bool { failedAudio != nil && !phase.isBusy }
    var canChangeSettings: Bool { !phase.isBusy && !paste.isLeasePending }
    var hotkey: HotkeySpec { preferences.hotkey }
    var preferredMicrophoneUnavailable: Bool {
        !preferences.preferredMicrophoneUID.isEmpty &&
            AudioInputDevices.resolvedUID(preferences.preferredMicrophoneUID, devices: inputDevices) == nil
    }
    var commandSpaceIsActive: Bool {
        hotkey == .commandSpace && shortcut?.current == .commandSpace && hotkeyError == nil
    }
    var isReadyToDictate: Bool {
        connection.isUsable && (microphone == .granted || microphone == .notRequested)
    }

    /// Items still missing for onboarding. Accessibility is optional.
    var missingRequirements: [String] {
        var missing: [String] = []
        if !connection.isUsable { missing.append("Sign in with ChatGPT") }
        if microphone != .granted { missing.append("Allow microphone access") }
        if hotkeyError != nil || shortcut?.current == nil { missing.append("Choose a working shortcut") }
        return missing
    }

    // MARK: Lifecycle

    /// Registers the saved shortcut. Call once after launch.
    func activate() {
        shortcut?.mode = preferences.shortcutMode
        shortcut?.doubleTapToToggle = preferences.doubleTapFnToToggle
        do {
            try shortcut?.replace(with: preferences.hotkey)
            hotkeyError = nil
        } catch {
            hotkeyError = error.localizedDescription
            if case GlobalShortcut.RegistrationError.systemShortcut = error { hotkeyBlockedBySystem = true }
        }
        activateToggleShortcut()
    }

    private func activateToggleShortcut() {
        guard preferences.toggleShortcutEnabled, !isCapturingShortcut else { toggleShortcut?.unregister(); return }
        guard preferences.toggleHotkey != preferences.hotkey else {
            toggleShortcut?.unregister()
            toggleHotkeyError = "Choose a different shortcut from the main dictation shortcut."
            return
        }
        do {
            try toggleShortcut?.replace(with: preferences.toggleHotkey)
            toggleHotkeyError = nil
        } catch { toggleHotkeyError = error.localizedDescription }
    }

    /// Rechecks sign-in, permissions, and login item status without prompting.
    func refreshStatus() {
        refreshInputDevices()
        cliAvailable = CodexAuthentication.cliAvailable
        if signInTask == nil { connection = ConnectionStatus.current() }
        microphone = PermissionStatus(AudioCapture.microphoneStatus)
        accessibilityTrusted = AccessibilityPermission.check()
        launchAtLogin = LaunchAtLoginStatus.current()
        recheckPermissionsAfterReturn()
    }

    /// macOS can publish a permission change after its Settings window loses focus.
    /// Recheck briefly so the UI reflects the grant without another click.
    private func recheckPermissionsAfterReturn() {
        permissionRefresh?.cancel()
        permissionRefresh = Task { [weak self] in
            for delay in [300_000_000, 700_000_000, 1_500_000_000] as [UInt64] {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, !Task.isCancelled else { return }
                let microphone = PermissionStatus(AudioCapture.microphoneStatus)
                let accessibility = AccessibilityPermission.check()
                if self.microphone != microphone { self.microphone = microphone }
                if self.accessibilityTrusted != accessibility { self.accessibilityTrusted = accessibility }
            }
        }
    }

    func completeOnboarding() {
        guard missingRequirements.isEmpty else { return }
        preferences.onboardingCompleted = true
    }

    /// Stops all work and deletes every owned audio file. Call on quit.
    func cleanup() {
        inputDeviceMonitor?.stop()
        permissionRefresh?.cancel()
        permissionRefresh = nil
        endShortcutTest()
        isPracticingInOnboarding = false
        cancel()
        signInTask?.cancel()
        signInTask = nil
        audio.cleanup()
        failedAudio = nil
        practiceTranscript = nil
        shortcut?.unregister()
        toggleShortcut?.unregister()
    }

    // MARK: Dictation

    /// Starts recording when idle. Stops and transcribes when recording.
    func toggleDictation() {
        if phase == .recording { stopDictation() } else { startDictation() }
    }

    func startDictation() {
        endShortcutTest()
        startCapture(practice: isPracticingInOnboarding)
    }

    func beginPractice() {
        endShortcutTest()
        isPracticingInOnboarding = true
    }

    func startPracticeDictation() {
        startCapture(practice: true)
    }

    func endPractice() {
        isPracticingInOnboarding = false
        guard isPracticeSession else { return }
        cancel()
        practiceTranscript = nil
    }

    private func startCapture(practice: Bool) {
        guard canStart, !isCapturingShortcut else { return }
        isPracticeSession = practice
        if practice { practiceTranscript = nil }
        // The hotkey path must not wait for full permissions/device-list refresh.
        connection = ConnectionStatus.current()
        guard connection.isUsable else {
            fail(DictationFailure(message: "Sign in with ChatGPT in Settings, then start dictation.", recovery: .none,
                                  overlayMessage: "Sign in to ChatGPT"))
            return
        }
        discardFailedAudio()
        generation += 1
        let current = generation
        phase = .preparing
        operation = Task {
            await Task.yield()
            await paste.waitForLease()
            guard current == generation else { return }
            if !isPracticeSession { paste.beginSession(keepTranscriptOnClipboard: preferences.keepTranscriptOnClipboard) }
            do {
                try await audio.start(preferredDeviceUID: preferences.preferredMicrophoneUID)
            } catch let error as AudioCaptureError {
                guard current == generation else { return }
                microphone = PermissionStatus(AudioCapture.microphoneStatus)
                fail(DictationFailure(captureError: error, audioKept: false))
                return
            } catch {
                guard current == generation else { return }
                fail(DictationFailure(captureError: .startFailed, audioKept: false))
                return
            }
            guard current == generation else { audio.cancel(); return }
            microphone = .granted
            phase = .recording
            startMeter()
            cue(.start)
            if holdState.recordingStarted() || stopToggleWhenReady {
                stopToggleWhenReady = false
                toggleOwnsRecording = false
                stopDictation()
            }
        }
    }

    func stopDictation() {
        guard phase == .recording, let url = try? audio.stop() else { return }
        captureEnded(url: url)
    }

    /// Cancels recording or transcription. Deletes the audio. A stale result never pastes.
    /// Paste delivery is short and cannot be cancelled, so it keeps its clipboard lease.
    func cancel() {
        holdState.reset()
        toggleOwnsRecording = false
        stopToggleWhenReady = false
        let pasting = phase == .pasting
        if !pasting { generation += 1 }
        operation?.cancel()
        operation = nil
        stopMeter()
        audio.cancel()
        if let activeAudio { audio.remove(activeAudio) }
        activeAudio = nil
        discardFailedAudio()
        guard !pasting else { return }
        paste.endSession()
        isPracticeSession = false
        phase = .idle
    }

    /// Sends the kept audio again.
    func retry() {
        guard canRetry, let url = failedAudio else { return }
        failedAudio = nil
        generation += 1
        let current = generation
        phase = .preparing
        operation = Task {
            await paste.waitForLease()
            guard current == generation else { return }
            if !isPracticeSession { paste.beginSession(keepTranscriptOnClipboard: preferences.keepTranscriptOnClipboard) }
            transcribe(url)
        }
    }

    func copyTranscript(_ text: String) {
        guard !paste.isLeasePending else { return }
        paste.copy(text)
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        paste.copy(lastTranscript)
        if !phase.isBusy { phase = .finished(.copied(.automaticPasteOff)) }
    }

    /// Pastes the last transcript into the current frontmost app.
    func pasteLastTranscript() {
        guard let text = lastTranscript, canStart else { return }
        isPracticeSession = false
        generation += 1
        let current = generation
        phase = .pasting
        operation = Task {
            await paste.waitForLease()
            paste.beginSession(keepTranscriptOnClipboard: preferences.keepTranscriptOnClipboard)
            let outcome = await paste.deliver(text: text, automaticPaste: true) { outcome in
                guard current == self.generation else { return }
                self.phase = .finished(outcome)
            }
            if current == generation, phase != .finished(outcome) { phase = .finished(outcome) }
        }
    }

    /// Test path: transcribes a supplied audio file and delivers it like a recording. No microphone use.
    /// The supplied file is not owned, so it is never deleted.
    func transcribeFile(_ url: URL, forPractice: Bool = false) {
        guard canStart else { return }
        isPracticeSession = forPractice
        if forPractice { practiceTranscript = nil }
        refreshStatus()
        discardFailedAudio()
        generation += 1
        let current = generation
        phase = .preparing
        operation = Task {
            await paste.waitForLease()
            guard current == generation else { return }
            if !isPracticeSession { paste.beginSession(keepTranscriptOnClipboard: preferences.keepTranscriptOnClipboard) }
            transcribe(url)
        }
    }

    /// Hides a finished or failed status. Failed audio stays available for Retry.
    func dismissStatus() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    var isPasteLeasePending: Bool { paste.isLeasePending }

    func waitForPasteLease() async { await paste.waitForLease() }

    func waitForDeliveryAndHistory() async {
        if phase == .pasting || paste.isLeasePending { await operation?.value }
        await paste.waitForLease()
        await history.waitForPendingChanges()
    }

    func openMicrophoneSettings() { SystemSettingsLink.microphone.open() }
    func openAccessibilitySettings() { SystemSettingsLink.accessibility.open() }

    func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    // MARK: Permissions

    /// Asks for microphone access the first time. Opens System Settings after a denial.
    func requestMicrophone() {
        switch AudioCapture.microphoneStatus {
        case .notDetermined:
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                microphone = PermissionStatus(AudioCapture.microphoneStatus)
            }
        case .authorized:
            microphone = .granted
        default:
            openMicrophoneSettings()
        }
    }

    /// Shows the macOS Accessibility prompt. The user grants access in System Settings.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        accessibilityTrusted = AccessibilityPermission.check()
    }

    // MARK: Sign-in

    func signIn() {
        guard signInTask == nil else { return }
        cliAvailable = CodexAuthentication.cliAvailable
        guard cliAvailable else {
            authError = "Install Codex CLI, then select Sign in with ChatGPT."
            return
        }
        authError = nil
        connection = .signingIn
        signInTask = Task {
            do {
                try await CodexAuthentication.signIn { url in
                    await MainActor.run { _ = NSWorkspace.shared.open(url) }
                }
            } catch {
                if !Task.isCancelled {
                    authError = "Sign-in did not finish. Select Sign in with ChatGPT to try again."
                }
            }
            guard !Task.isCancelled else { return }
            signInTask = nil
            connection = ConnectionStatus.current()
            if connection.isUsable { authError = nil }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        connection = ConnectionStatus.current()
    }

    /// Renews the shared sign-in through Codex CLI.
    func reconnect() {
        guard signInTask == nil else { return }
        guard cliAvailable else { signIn(); return }
        authError = nil
        connection = .renewing
        signInTask = Task {
            do {
                _ = try await CodexAuthentication.refresh()
            } catch {
                if !Task.isCancelled {
                    authError = "Renewal failed. Select Sign in with ChatGPT to sign in again."
                }
            }
            guard !Task.isCancelled else { return }
            signInTask = nil
            connection = ConnectionStatus.current()
        }
    }

    func openInstallCodex() { NSWorkspace.shared.open(Self.installCodexURL) }

    // MARK: Shortcut

    /// Waits for the registered shortcut without starting the microphone.
    func beginShortcutTest() {
        guard canChangeSettings else { return }
        if isCapturingShortcut { endShortcutCapture() }
        guard shortcut?.current != nil, hotkeyError == nil else {
            shortcutTestStatus = .unavailable(hotkeyError ?? "Choose a working shortcut first.")
            return
        }
        shortcutTestStatus = .listening
    }

    func endShortcutTest() { shortcutTestStatus = .idle }

    func receiveGlobalShortcut() {
        switch shortcutTestStatus {
        case .listening, .received:
            shortcutTestStatus = .received
        case .idle, .unavailable:
            if preferences.shortcutMode == .hold {
                guard !isCapturingShortcut, holdState.press(canStart: canStart) else { return }
                toggleOwnsRecording = false
                stopToggleWhenReady = false
                startDictation()
            } else {
                receiveToggleShortcut()
            }
        }
    }

    func releaseGlobalShortcut() {
        guard preferences.shortcutMode == .hold else { return }
        if holdState.release(isPreparing: phase == .preparing), phase == .recording { stopDictation() }
    }

    /// The second quick Fn tap keeps its already-started recording alive. When
    /// hands-free recording is already active, the next double-tap stops it.
    func receiveFunctionToggle() {
        if holdState.ownsRecording {
            holdState.reset()
            toggleOwnsRecording = true
            stopToggleWhenReady = false
        } else {
            receiveToggleShortcut()
        }
    }

    /// A double-tap or the dedicated toggle shortcut starts a hands-free recording.
    /// Repeating that same gesture stops it, including during microphone startup.
    func receiveToggleShortcut() {
        switch shortcutTestStatus {
        case .listening, .received:
            shortcutTestStatus = .received
            return
        case .idle, .unavailable: break
        }
        guard !isCapturingShortcut else { return }
        if phase == .recording {
            holdState.reset()
            toggleOwnsRecording = false
            stopDictation()
        } else if phase == .preparing, toggleOwnsRecording {
            stopToggleWhenReady = true
        } else if canStart {
            holdState.reset()
            toggleOwnsRecording = true
            stopToggleWhenReady = false
            startDictation()
        }
    }

    func cancelHeldShortcut() {
        guard holdState.ownsRecording else { return }
        if phase == .preparing || phase == .recording { cancel() } else { holdState.reset() }
    }

    func setShortcutMode(_ mode: ShortcutMode) {
        guard canChangeSettings else { return }
        endShortcutTest()
        holdState.reset()
        preferences.shortcutMode = mode
        shortcut?.mode = mode
    }

    func setDoubleTapFnToToggle(_ enabled: Bool) {
        guard canChangeSettings else { return }
        preferences.doubleTapFnToToggle = enabled
        shortcut?.doubleTapToToggle = enabled
    }

    func setToggleShortcutEnabled(_ enabled: Bool) {
        guard canChangeSettings else { return }
        if enabled, !setToggleHotkey(preferences.toggleHotkey) { return }
        preferences.toggleShortcutEnabled = enabled
        if enabled { activateToggleShortcut() }
        else { toggleShortcut?.unregister(); toggleHotkeyError = nil }
    }

    @discardableResult
    func setToggleHotkey(_ spec: HotkeySpec) -> Bool {
        guard canChangeSettings else { return false }
        guard spec != preferences.hotkey else {
            toggleHotkeyError = "Choose a different shortcut from the main dictation shortcut."
            return false
        }
        do {
            try toggleShortcut?.replace(with: spec)
            preferences.toggleHotkey = spec
            toggleHotkeyError = nil
            if !preferences.toggleShortcutEnabled { toggleShortcut?.unregister() }
            return true
        } catch {
            toggleHotkeyError = error.localizedDescription
            return false
        }
    }

    /// Suspends the global shortcut so the recorder receives the keys.
    func beginShortcutCapture() {
        endShortcutTest()
        guard canChangeSettings else {
            hotkeyError = "Finish the current dictation, then change the shortcut."
            return
        }
        isCapturingShortcut = true
        shortcut?.unregister()
        toggleShortcut?.unregister()
    }

    /// Restores the saved shortcut if the recorder did not save a new one.
    func endShortcutCapture() {
        isCapturingShortcut = false
        activate()
    }

    /// Registers a new shortcut and saves it only on success. The previous shortcut stays on failure.
    @discardableResult
    func setHotkey(_ spec: HotkeySpec) -> Bool {
        guard canChangeSettings else {
            hotkeyError = "Finish the current dictation, then change the shortcut."
            return false
        }
        endShortcutTest()
        if preferences.toggleShortcutEnabled, spec == preferences.toggleHotkey {
            hotkeyError = "Choose a different shortcut from the separate toggle shortcut."
            return false
        }
        do {
            hotkeyBlockedBySystem = false
            try shortcut?.replace(with: spec)
            preferences.hotkey = spec
            hotkeyError = nil
            return true
        } catch {
            hotkeyError = error.localizedDescription
            if case GlobalShortcut.RegistrationError.systemShortcut = error {
                hotkeyBlockedBySystem = true
            }
            if shortcut?.current == nil, !isCapturingShortcut { try? shortcut?.replace(with: preferences.hotkey) }
            return false
        }
    }

    func resetHotkey() { setHotkey(.default) }

    /// Tries Command–Space. The recorder cannot capture it while macOS owns it, so this preset exists.
    func useCommandSpace() { setHotkey(.commandSpace) }

    func openKeyboardShortcutsSettings() { SystemSettingsLink.keyboardShortcuts.open() }

    /// Shows a recorder error, for example a reserved shortcut, without changing registration.
    func reportShortcutProblem(_ problem: HotkeySpec.Problem) {
        hotkeyError = problem.message
        hotkeyBlockedBySystem = false
    }

    func reportToggleShortcutProblem(_ problem: HotkeySpec.Problem) {
        toggleHotkeyError = problem.message
    }

    // MARK: Behavior

    func refreshInputDevices() {
        let devices = availableInputDevices()
        if inputDevices != devices { inputDevices = devices }
        if let preferred = devices.first(where: { $0.uid == preferences.preferredMicrophoneUID }),
           preferences.preferredMicrophoneName != preferred.name {
            preferences.preferredMicrophoneName = preferred.name
        }
    }

    func setPreferredMicrophone(_ uid: String) {
        guard canChangeSettings else { return }
        if uid.isEmpty {
            preferences.preferredMicrophoneUID = ""
            preferences.preferredMicrophoneName = ""
        } else if let device = inputDevices.first(where: { $0.uid == uid }) {
            preferences.preferredMicrophoneUID = device.uid
            preferences.preferredMicrophoneName = device.name
        }
    }


    func setAutomaticPaste(_ value: Bool) {
        guard canChangeSettings else { return }
        preferences.automaticPaste = value
    }

    func setSoundCues(_ value: Bool) {
        guard canChangeSettings else { return }
        preferences.soundCues = value
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLoginError = enabled
                ? "Launch at login could not be turned on. Open Login Items and allow GPT Voice."
                : "Launch at login could not be turned off. Remove GPT Voice in Login Items."
        }
        launchAtLogin = LaunchAtLoginStatus.current()
    }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Private

    private func captureEnded(url: URL) {
        toggleOwnsRecording = false
        stopToggleWhenReady = false
        stopMeter()
        cue(.stop)
        generation += 1
        transcribe(url)
    }

    private func captureFailed(_ error: AudioCaptureError, url: URL?) {
        stopMeter()
        generation += 1
        operation = nil
        failedAudio = url
        fail(DictationFailure(captureError: error, audioKept: url != nil))
    }

    /// Transcribes and delivers one file. Uses the current generation to reject stale results.
    private func transcribe(_ url: URL) {
        let current = generation
        activeAudio = url
        phase = .transcribing
        operation = Task {
            let text: String
            do {
                text = try await transcribeAudio(url)
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                activeAudio = nil
                let failure = DictationFailure(transcriptionError: error)
                if failure.keepsAudio { failedAudio = url } else { audio.remove(url) }
                fail(failure)
                return
            }
            guard current == generation, !Task.isCancelled else { return }
            activeAudio = nil
            audio.remove(url)
            lastTranscript = text
            if isPracticeSession {
                practiceTranscript = text
                operation = nil
                paste.endSession()
                phase = .finished(.previewed)
                return
            }
            let completedAt = Date()
            phase = .pasting
            var recordedHistory = false
            let finish: (PasteOutcome) -> Void = { [self] outcome in
                if !recordedHistory {
                    recordedHistory = true
                    history.record(HistoryEntry(text: text, createdAt: completedAt, delivery: HistoryDelivery(outcome)))
                }
                if current == generation, phase != .finished(outcome) { phase = .finished(outcome) }
            }
            let outcome = await paste.deliver(text: text, automaticPaste: preferences.automaticPaste, onPasted: finish)
            finish(outcome)
            if current == generation { operation = nil }
        }
    }

    private func fail(_ failure: DictationFailure) {
        holdState.reset()
        toggleOwnsRecording = false
        stopToggleWhenReady = false
        operation = nil
        if !failure.keepsAudio { paste.endSession() }
        phase = .failed(failure)
        cue(.failure)
    }

    private func discardFailedAudio() {
        if let failedAudio { audio.remove(failedAudio) }
        failedAudio = nil
    }

    private func cue(_ sound: SoundCue) {
        if preferences.soundCues { sound.play() }
    }

    private func startMeter() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, target: self, selector: #selector(meterTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        elapsed = 0
        level = 0
    }

    @objc private func meterTick() {
        guard audio.isRecording else { stopMeter(); return }
        elapsed = audio.elapsed
        level = audio.currentLevel()
    }
}
