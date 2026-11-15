import Carbon.HIToolbox
import XCTest
@testable import GPTVoice

final class GlobalShortcutTests: XCTestCase {
    @MainActor
    func testTwoShortcutsHaveIndependentPressAndReleaseCallbacks() throws {
        var firstPresses = 0
        var secondPresses = 0
        var secondReleases = 0
        let first = GlobalShortcut(onPress: { firstPresses += 1 })
        let second = GlobalShortcut(onPress: { secondPresses += 1 }, onRelease: { secondReleases += 1 })
        defer { first.unregister(); second.unregister() }
        try first.replace(with: HotkeySpec(keyCode: UInt32(kVK_F16), modifiers: UInt32(controlKey | optionKey | shiftKey)))
        try second.replace(with: HotkeySpec(keyCode: UInt32(kVK_F17), modifiers: UInt32(controlKey | optionKey | shiftKey)))
        XCTAssertNotEqual(first.currentID, second.currentID)
        first.handlePress(id: second.currentID)
        second.handlePress(id: first.currentID)
        XCTAssertEqual(firstPresses, 0)
        XCTAssertEqual(secondPresses, 0)
        first.handlePress(id: first.currentID)
        second.handlePress(id: second.currentID)
        second.handlePress(id: second.currentID, released: true)
        XCTAssertEqual(firstPresses, 1)
        XCTAssertEqual(secondPresses, 1)
        XCTAssertEqual(secondReleases, 1)
        second.unregister()
        second.handlePress(id: second.currentID)
        XCTAssertEqual(secondPresses, 1)
    }

    @MainActor
    func testFnWithoutAccessibilityKeepsThePreviousShortcut() async throws {
        guard !AccessibilityPermission.check() else {
            throw XCTSkip("Accessibility is already granted to this test process.")
        }
        let shortcut = GlobalShortcut(onPress: {})
        defer { shortcut.unregister() }
        let previous = HotkeySpec(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | shiftKey))
        try shortcut.replace(with: previous)
        XCTAssertThrowsError(try shortcut.replace(with: .function)) { error in
            XCTAssertEqual(error as? GlobalShortcut.RegistrationError, .functionKeyAccess)
        }
        XCTAssertEqual(shortcut.current, previous)
    }

    @MainActor
    func testFailedReplacementKeepsThePreviousShortcut() async throws {
        let first = GlobalShortcut(onPress: {})
        let second = GlobalShortcut(onPress: {})
        defer { first.unregister(); second.unregister() }
        let a = HotkeySpec(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | shiftKey))
        let b = HotkeySpec(keyCode: UInt32(kVK_F20), modifiers: UInt32(controlKey | optionKey | shiftKey))
        try first.replace(with: a)
        try second.replace(with: b)
        XCTAssertThrowsError(try second.replace(with: a))
        XCTAssertEqual(second.current, b)
    }

    @MainActor
    func testCommandSpaceUsesCurrentSystemSettings() async throws {
        let shortcut = GlobalShortcut(onPress: {})
        defer { shortcut.unregister() }
        if GlobalShortcut.isSystemShortcutEnabled(.commandSpace) {
            XCTAssertThrowsError(try shortcut.replace(with: .commandSpace)) { error in
                XCTAssertEqual(error as? GlobalShortcut.RegistrationError, .systemShortcut(.commandSpace))
            }
        } else {
            do {
                try shortcut.replace(with: .commandSpace)
                XCTAssertEqual(shortcut.current, .commandSpace)
            } catch GlobalShortcut.RegistrationError.conflict {
                throw XCTSkip("Another app currently owns Command–Space.")
            }
        }
    }
}
