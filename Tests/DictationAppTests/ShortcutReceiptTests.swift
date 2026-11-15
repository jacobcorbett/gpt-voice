import AppKit
import Carbon.HIToolbox
import XCTest
@testable import GPTVoice

final class ShortcutReceiptTests: XCTestCase {
    @MainActor
    func testShortcutCheckDoesNotStartTheMicrophoneOrChangeTheClipboard() throws {
        let suite = "shortcut-receipt-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        // Avoid the user's real dictation shortcut and macOS input-source shortcuts.
        preferences.hotkey = HotkeySpec(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | shiftKey))
        let clipboard = NSPasteboard.withUniqueName()
        clipboard.setString("Keep my clipboard", forType: .string)
        let model = AppModel(preferences: preferences, pasteboard: clipboard, history: TranscriptionHistory(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("gpt-voice-test-\(UUID().uuidString)/history.json")))
        defer { model.cleanup(); clipboard.releaseGlobally() }
        model.activate()
        guard model.hotkeyError == nil else {
            throw XCTSkip(model.hotkeyError ?? "The shortcut is unavailable in this test process.")
        }

        model.beginShortcutTest()
        XCTAssertEqual(model.shortcutTestStatus, .listening)
        model.receiveGlobalShortcut()
        XCTAssertEqual(model.shortcutTestStatus, .received)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(clipboard.string(forType: .string), "Keep my clipboard")

        // A repeated press stays in the test until it is explicitly closed.
        model.receiveGlobalShortcut()
        XCTAssertEqual(model.phase, .idle)
        model.receiveToggleShortcut()
        model.releaseGlobalShortcut()
        XCTAssertEqual(model.shortcutTestStatus, .received)
        XCTAssertEqual(model.phase, .idle)
        model.endShortcutTest()
        XCTAssertEqual(model.shortcutTestStatus, .idle)
    }
}
