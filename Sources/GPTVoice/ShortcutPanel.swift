import SwiftUI

/// Keycaps and recorder, quiet presets, then the receipt test. Start and stop are explained by the caller once.
struct ShortcutPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var preferences: AppPreferences

    init(model: AppModel) {
        self.model = model
        self.preferences = model.preferences
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsGroup {
                SettingsRow(title: "Mode", detail: preferences.shortcutMode.detail) {
                    AppSegmented(label: "Dictation shortcut mode", options: ShortcutMode.allCases,
                                 title: \.title,
                                 selection: Binding(get: { preferences.shortcutMode }, set: { model.setShortcutMode($0) }))
                        .disabled(!model.canChangeSettings)
                }
                SettingsRow(title: "Shortcut") {
                    KeycapsView(spec: preferences.hotkey)
                }
                SettingsRow(title: "Change") {
                    ShortcutRecorderField(model: model, isEnabled: model.canChangeSettings)
                        .frame(width: 220, height: 30)
                }
                SettingsRow(title: "Presets") {
                    HStack(spacing: 6) {
                        Button("Fn") { _ = model.setHotkey(.function) }
                            .buttonStyle(AppButtonStyle(kind: .secondary, small: true))
                            .disabled(!model.canChangeSettings || (preferences.hotkey == .function && model.hotkeyError == nil))
                            .accessibilityLabel("Use Fn")
                        Button("Command–Space") { model.useCommandSpace() }
                            .buttonStyle(AppButtonStyle(kind: .secondary, small: true))
                            .disabled(!model.canChangeSettings || model.commandSpaceIsActive)
                            .accessibilityLabel("Use Command–Space")
                        Button("Default") { model.resetHotkey() }
                            .buttonStyle(AppButtonStyle(kind: .secondary, small: true))
                            .disabled(!model.canChangeSettings || preferences.hotkey == .default)
                            .accessibilityLabel("Reset to default shortcut")
                    }
                }
                ShortcutTestRow(model: model)
            }

            SettingsGroup(title: "Hands-free recording") {
                SettingsRow(title: "Double-tap Fn to toggle",
                            detail: "In Hold mode, tap Fn twice to start. Tap it twice again to finish.") {
                    AppToggle(label: "Double-tap Fn to toggle",
                              isOn: Binding(get: { preferences.doubleTapFnToToggle },
                                            set: { model.setDoubleTapFnToToggle($0) }))
                        .disabled(!model.canChangeSettings || !preferences.hotkey.isFunctionOnly || preferences.shortcutMode != .hold)
                }
                SettingsRow(title: "Separate toggle shortcut",
                            detail: "Press once to start recording, then again to finish.") {
                    AppToggle(label: "Separate toggle shortcut",
                              isOn: Binding(get: { preferences.toggleShortcutEnabled },
                                            set: { model.setToggleShortcutEnabled($0) }))
                        .disabled(!model.canChangeSettings)
                }
                SettingsRow(title: "Toggle shortcut") {
                    KeycapsView(spec: preferences.toggleHotkey)
                }
                SettingsRow(title: "Change toggle shortcut", showsDivider: model.toggleHotkeyError != nil) {
                    ShortcutRecorderField(model: model, isEnabled: model.canChangeSettings, target: .toggle)
                        .frame(width: 220, height: 30)
                }
                if let error = model.toggleHotkeyError {
                    Text(error).font(AppType.controlSmall).foregroundStyle(.secondary)
                }
            }

            if let error = model.hotkeyError {
                SettingsGroup {
                    StatusRow(tone: .problem, symbol: "exclamationmark.triangle.fill",
                              title: "That shortcut cannot be used", detail: error) {
                        if model.hotkeyBlockedBySystem {
                            Button("Keyboard settings") { model.openKeyboardShortcutsSettings() }
                                .buttonStyle(AppButtonStyle(kind: .secondary, showsArrow: true, small: true))
                        }
                    }
                }
            }

            InfoDisclosure(label: "Shortcut not responding?",
                           text: "For Fn, allow Accessibility access and set System Settings > Keyboard > Press 🌐 key to > Do Nothing. Keep Globe mapped to Globe under Modifier Keys. In Hold mode, using Fn with another key discards the recording. Another app may use the same keys. The recorder cannot capture keys macOS keeps, such as Command–Space. Use the preset for those.")
        }
        // Never leave a listening test behind when the panel goes away.
        .onDisappear { model.endShortcutTest() }
    }
}
