import Foundation

/// User preferences. Stores only settings and onboarding state.
/// Never stores credentials, audio, or transcripts.
@MainActor
final class AppPreferences: ObservableObject {
    private enum Key {
        static let hotkey = "hotkey"
        static let preferredMicrophoneUID = "preferredMicrophoneUID"
        static let preferredMicrophoneName = "preferredMicrophoneName"
        static let shortcutMode = "shortcutMode"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let doubleTapFnToToggle = "doubleTapFnToToggle"
        static let toggleShortcutEnabled = "toggleShortcutEnabled"
        static let toggleHotkey = "toggleHotkey"
        static let pillContents = "pillContents"
        static let automaticPaste = "automaticPaste"
        static let keepTranscriptOnClipboard = "keepTranscriptOnClipboard"
        static let soundCues = "soundCues"
        static let onboardingCompleted = "onboardingCompleted"
        static let theme = "theme"
        static let accent = "accent"
        static let overlayPlacement = "overlayPlacement"
        static let manualPasteHelpDismissed = "manualPasteHelpDismissed"
    }

    @Published var overlayPlacement: OverlayPlacement {
        didSet { defaults.set(overlayPlacement.rawValue, forKey: Key.overlayPlacement) }
    }

    @Published var manualPasteHelpDismissed: Bool {
        didSet { defaults.set(manualPasteHelpDismissed, forKey: Key.manualPasteHelpDismissed) }
    }

    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    @Published var accent: AccentChoice {
        didSet { defaults.set(accent.rawValue, forKey: Key.accent) }
    }

    @Published var preferredMicrophoneUID: String {
        didSet { defaults.set(preferredMicrophoneUID, forKey: Key.preferredMicrophoneUID) }
    }

    @Published var preferredMicrophoneName: String {
        didSet { defaults.set(preferredMicrophoneName, forKey: Key.preferredMicrophoneName) }
    }

    private let defaults: UserDefaults

    @Published var shortcutMode: ShortcutMode {
        didSet { defaults.set(shortcutMode.rawValue, forKey: Key.shortcutMode) }
    }

    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    @Published var doubleTapFnToToggle: Bool {
        didSet { defaults.set(doubleTapFnToToggle, forKey: Key.doubleTapFnToToggle) }
    }

    @Published var toggleShortcutEnabled: Bool {
        didSet { defaults.set(toggleShortcutEnabled, forKey: Key.toggleShortcutEnabled) }
    }

    @Published var toggleHotkey: HotkeySpec {
        didSet { if let data = try? JSONEncoder().encode(toggleHotkey) { defaults.set(data, forKey: Key.toggleHotkey) } }
    }

    @Published var pillContents: PillContents {
        didSet { if let data = try? JSONEncoder().encode(pillContents) { defaults.set(data, forKey: Key.pillContents) } }
    }

    @Published var hotkey: HotkeySpec {
        didSet {
            guard let data = try? JSONEncoder().encode(hotkey) else { return }
            defaults.set(data, forKey: Key.hotkey)
        }
    }

    @Published var automaticPaste: Bool {
        didSet { defaults.set(automaticPaste, forKey: Key.automaticPaste) }
    }

    @Published var keepTranscriptOnClipboard: Bool {
        didSet { defaults.set(keepTranscriptOnClipboard, forKey: Key.keepTranscriptOnClipboard) }
    }

    @Published var soundCues: Bool {
        didSet { defaults.set(soundCues, forKey: Key.soundCues) }
    }

    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showMenuBarIcon: true,
            Key.automaticPaste: true,
            Key.soundCues: false,
            Key.onboardingCompleted: false
        ])
        let stored = defaults.data(forKey: Key.hotkey).flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
        hotkey = stored.flatMap { $0.isValid ? $0 : nil } ?? .default
        preferredMicrophoneUID = defaults.string(forKey: Key.preferredMicrophoneUID) ?? ""
        preferredMicrophoneName = defaults.string(forKey: Key.preferredMicrophoneName) ?? ""
        shortcutMode = defaults.string(forKey: Key.shortcutMode).flatMap(ShortcutMode.init(rawValue:)) ?? .toggle
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        doubleTapFnToToggle = defaults.bool(forKey: Key.doubleTapFnToToggle)
        toggleShortcutEnabled = defaults.bool(forKey: Key.toggleShortcutEnabled)
        toggleHotkey = defaults.data(forKey: Key.toggleHotkey)
            .flatMap { try? JSONDecoder().decode(HotkeySpec.self, from: $0) }
            .flatMap { $0.isValid ? $0 : nil } ?? .default
        pillContents = defaults.data(forKey: Key.pillContents)
            .flatMap { try? JSONDecoder().decode(PillContents.self, from: $0) } ?? .standard
        automaticPaste = defaults.bool(forKey: Key.automaticPaste)
        keepTranscriptOnClipboard = defaults.bool(forKey: Key.keepTranscriptOnClipboard)
        soundCues = defaults.bool(forKey: Key.soundCues)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        theme = defaults.string(forKey: Key.theme).flatMap(AppTheme.init(rawValue:)) ?? .system
        accent = defaults.string(forKey: Key.accent).flatMap(AccentChoice.init(rawValue:)) ?? .system
        overlayPlacement = defaults.string(forKey: Key.overlayPlacement)
            .flatMap(OverlayPlacement.init(rawValue:)) ?? .bottom
        manualPasteHelpDismissed = defaults.bool(forKey: Key.manualPasteHelpDismissed)
    }
}
