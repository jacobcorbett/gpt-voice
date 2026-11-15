import AppKit
import Carbon.HIToolbox
import XCTest
@testable import GPTVoice

final class ShortcutBehaviorTests: XCTestCase {
    func testHoldReleaseBeforeMicrophoneReadyStopsWhenItStarts() {
        var state = HoldToDictateState()
        XCTAssertTrue(state.press(canStart: true))
        XCTAssertFalse(state.press(canStart: true))
        XCTAssertFalse(state.release(isPreparing: true))
        XCTAssertTrue(state.recordingStarted())
        XCTAssertFalse(state.recordingStarted())
        XCTAssertFalse(state.release(isPreparing: false))
    }

    func testHoldReleaseOnlyStopsTheRecordingItOwns() {
        var state = HoldToDictateState()
        XCTAssertFalse(state.release(isPreparing: false))
        XCTAssertFalse(state.press(canStart: false))
        XCTAssertFalse(state.release(isPreparing: false))
        XCTAssertTrue(state.press(canStart: true))
        XCTAssertFalse(state.recordingStarted())
        XCTAssertTrue(state.release(isPreparing: false))
        XCTAssertFalse(state.release(isPreparing: false))
    }

    func testCancellationClearsPendingHoldAndRelease() {
        var state = HoldToDictateState()
        XCTAssertTrue(state.press(canStart: true))
        XCTAssertFalse(state.release(isPreparing: true))
        state.reset()
        XCTAssertFalse(state.recordingStarted())
        XCTAssertFalse(state.release(isPreparing: false))
        XCTAssertTrue(state.press(canStart: true))
    }

    func testFnReportsHoldEdgesAndCancellationWithoutAReleaseAfterChord() {
        var gesture = FunctionKeyGesture()
        let fn = UInt16(kVK_Function)
        XCTAssertEqual(gesture.update(type: .flagsChanged, keyCode: fn, modifiers: .function), .pressed)
        XCTAssertEqual(gesture.update(type: .flagsChanged, keyCode: fn, modifiers: .function), nil)
        XCTAssertEqual(gesture.update(type: .keyDown, keyCode: UInt16(kVK_Delete), modifiers: .function), .cancelled)
        XCTAssertNil(gesture.update(type: .flagsChanged, keyCode: fn, modifiers: []))
        XCTAssertEqual(gesture.update(type: .flagsChanged, keyCode: fn, modifiers: .function), .pressed)
        XCTAssertEqual(gesture.update(type: .flagsChanged, keyCode: fn, modifiers: []), .released)
    }

    @MainActor
    func testFnStartsOnKeyDownAndDoubleTapLatchesTheSecondCapture() {
        var events: [String] = []
        let shortcut = GlobalShortcut(onPress: { events.append("press") },
                                     onRelease: { events.append("release") },
                                     onCancel: { events.append("cancel") },
                                     onToggle: { events.append("toggle") })
        shortcut.mode = .hold
        shortcut.doubleTapToToggle = true
        shortcut.handleFunctionGesture(.pressed, at: 0)
        XCTAssertEqual(events, ["press"], "Fn down must start synchronously")
        shortcut.handleFunctionGesture(.released, at: 0.05)
        shortcut.handleFunctionGesture(.pressed, at: 0.12)
        shortcut.handleFunctionGesture(.released, at: 0.17)
        XCTAssertEqual(events, ["press", "cancel", "press", "toggle"])
        events = []
        shortcut.handleFunctionGesture(.pressed, at: 1)
        shortcut.handleFunctionGesture(.released, at: 1.5)
        XCTAssertEqual(events, ["press", "release"])
        events = []
        shortcut.handleFunctionGesture(.pressed, at: 2)
        shortcut.handleFunctionGesture(.cancelled, at: 2.01)
        shortcut.handleFunctionGesture(.released, at: 2.02)
        XCTAssertEqual(events, ["press", "cancel"])
    }

    @MainActor
    func testPreferencesKeepExistingDefaultsAndPersistNewChoices() {
        let suite = "shortcut-behavior-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.shortcutMode, .toggle)
        XCTAssertTrue(preferences.showMenuBarIcon)
        XCTAssertFalse(preferences.keepTranscriptOnClipboard)
        preferences.shortcutMode = .hold
        preferences.showMenuBarIcon = false
        preferences.doubleTapFnToToggle = true
        preferences.toggleShortcutEnabled = true
        preferences.pillContents = .minimal
        preferences.keepTranscriptOnClipboard = true
        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.shortcutMode, .hold)
        XCTAssertFalse(reloaded.showMenuBarIcon)
        XCTAssertTrue(reloaded.doubleTapFnToToggle)
        XCTAssertTrue(reloaded.toggleShortcutEnabled)
        XCTAssertEqual(reloaded.pillContents, .minimal)
        XCTAssertTrue(reloaded.keepTranscriptOnClipboard)
        defaults.set("unknown-future-mode", forKey: "shortcutMode")
        XCTAssertEqual(AppPreferences(defaults: defaults).shortcutMode, .toggle)
    }

    @MainActor
    func testDuplicatePrimaryAndToggleShortcutsAreRejected() {
        let suite = "duplicate-shortcut-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: AppPreferences(defaults: defaults))
        defer { model.cleanup() }
        model.setToggleShortcutEnabled(true)
        XCTAssertFalse(model.preferences.toggleShortcutEnabled)
        XCTAssertNotNil(model.toggleHotkeyError)
        XCTAssertFalse(model.setToggleHotkey(model.preferences.hotkey))
    }

    @MainActor
    func testMenuBarVisibilityFollowsPreference() {
        let suite = "status-menu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.showMenuBarIcon = false
        let history = TranscriptionHistory(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("gpt-voice-test-\(UUID().uuidString)/history.json"))
        let model = AppModel(preferences: preferences, history: history)
        defer { model.cleanup() }
        let menu = StatusMenuController(model: model, windows: WindowCoordinator(model: model))
        XCTAssertFalse(menu.isVisible)
        preferences.showMenuBarIcon = true
        XCTAssertTrue(menu.isVisible)
        preferences.showMenuBarIcon = false
        XCTAssertFalse(menu.isVisible)
    }
}
