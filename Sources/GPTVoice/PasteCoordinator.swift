import AppKit
import ApplicationServices
import Carbon.HIToolbox
import DictationCore

struct PastePlatform {
    var isAutomaticPasteAvailable: (() -> Bool)? = nil
    var postPaste: (() -> Bool)? = nil
}

/// Serial owner of the clipboard lease and paste delivery.
/// Call `beginSession()` when recording starts and `deliver(text:automaticPaste:)` when the transcript arrives.
@MainActor
final class PasteCoordinator {
    /// Time that the target app gets to read the pasteboard before the old content returns.
    static let restoreDelay: UInt64 = 750_000_000

    private let pasteboard: NSPasteboard
    private let platform: PastePlatform?
    private var keepTranscriptOnClipboard = false
    private var target: PasteTarget?
    private var snapshot: ClipboardSnapshot?
    private var delivery: Task<PasteOutcome, Never>?

    init(pasteboard: NSPasteboard = .general, platform: PastePlatform? = nil) {
        self.pasteboard = pasteboard
        self.platform = platform
    }

    /// True while a paste or a clipboard restore is pending. Block new recordings while true.
    var isLeasePending: Bool { delivery != nil }

    /// Waits for any pending paste and clipboard restore to finish.
    func waitForLease() async {
        while let pending = delivery { _ = await pending.value }
    }

    /// Captures the paste target and the clipboard. Call at recording start.
    func beginSession(keepTranscriptOnClipboard: Bool = false) {
        self.keepTranscriptOnClipboard = keepTranscriptOnClipboard
        target = PasteTarget.captureFrontmost()
        snapshot = ClipboardSnapshot.capture(pasteboard, includingContents: !keepTranscriptOnClipboard)
    }

    /// Drops the captured target and clipboard, for example after Cancel.
    func endSession() {
        target = nil
        snapshot = nil
    }

    /// Explicit user Copy. Writes the original transcript.
    func copy(_ text: String) {
        write(text)
    }

    /// Delivers a transcript once. Never replaces a clipboard that changed since `beginSession()`.
    func deliver(text: String, automaticPaste: Bool,
                 onPasted: ((PasteOutcome) -> Void)? = nil) async -> PasteOutcome {
        await waitForLease()
        let task = Task { () -> PasteOutcome in
            let outcome = await self.performDelivery(text: text, automaticPaste: automaticPaste, onPasted: onPasted)
            self.endSession()
            self.delivery = nil
            return outcome
        }
        delivery = task
        return await task.value
    }

    private func performDelivery(text: String, automaticPaste: Bool,
                                 onPasted: ((PasteOutcome) -> Void)?) async -> PasteOutcome {
        if let snapshot, pasteboard.changeCount != snapshot.changeCount {
            return .preservedNewerClipboard
        }
        let reason: PasteOutcome.ManualReason?
        if !automaticPaste {
            reason = .automaticPasteOff
        } else if let available = platform?.isAutomaticPasteAvailable {
            reason = available() ? nil : .noTarget
        } else if !AccessibilityPermission.check() {
            reason = .accessibilityMissing
        } else if target == nil || snapshot == nil {
            reason = .noTarget
        } else if target?.isStillFrontmost() != true {
            reason = .targetChanged
        } else {
            reason = nil
        }
        if let reason {
            write(text)
            return .copied(reason)
        }

        let ownedChange = write(TranscriptText.forAutomaticPaste(text))
        guard platform?.postPaste?() ?? postCommandV() else {
            // Keep the transcript on the clipboard for manual recovery.
            return .copied(.injectionFailed)
        }
        let outcome = PasteOutcome.pasted(appName: target?.appName)
        onPasted?(outcome)
        if keepTranscriptOnClipboard { return outcome }
        try? await Task.sleep(nanoseconds: Self.restoreDelay)
        if pasteboard.changeCount == ownedChange, let snapshot {
            snapshot.restore(to: pasteboard)
        }
        return outcome
    }

    @discardableResult
    private func write(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Posts Command+V with explicit flags. Never posts Return.
    private func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .privateState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
