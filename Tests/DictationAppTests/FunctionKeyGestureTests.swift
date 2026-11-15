import AppKit
import Carbon.HIToolbox
import XCTest
@testable import GPTVoice

final class FunctionKeyGestureTests: XCTestCase {
    private let fn = UInt16(kVK_Function)

    func testFnTogglesOnceOnRelease() {
        var gesture = FunctionKeyGesture()
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .function))
        XCTAssertTrue(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .function))
        XCTAssertTrue(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
    }

    func testFnChordsDoNotToggle() {
        for code in [kVK_Delete, kVK_LeftArrow, kVK_F1, kVK_ANSI_A] {
            var gesture = FunctionKeyGesture()
            XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .function))
            XCTAssertFalse(gesture.consume(type: .keyDown, keyCode: UInt16(code), modifiers: .function))
            XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
            XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .function))
            XCTAssertTrue(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
        }
    }

    func testOtherModifiersCancelTheTapEvenWhenReleasedBeforeFn() {
        var gesture = FunctionKeyGesture()
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .function))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: UInt16(kVK_Command), modifiers: [.function, .command]))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: UInt16(kVK_Command), modifiers: .function))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
    }

    func testFnPressedWithOtherModifiersDoesNotToggle() {
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            var gesture = FunctionKeyGesture()
            XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: [.function, modifier]))
            XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: modifier))
        }
    }

    func testMediaKeysCancelTheTap() {
        var gesture = FunctionKeyGesture()
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .function))
        XCTAssertFalse(gesture.consume(type: .systemDefined, keyCode: 0, modifiers: .function))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
    }

    func testFunctionFlagOnNavigationKeysIsNotAnFnTap() {
        var gesture = FunctionKeyGesture()
        XCTAssertFalse(gesture.consume(type: .keyDown, keyCode: UInt16(kVK_LeftArrow), modifiers: [.function, .numericPad]))
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: []))
    }

    func testCapsLockDoesNotPreventFnTap() {
        var gesture = FunctionKeyGesture()
        XCTAssertFalse(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: [.function, .capsLock]))
        XCTAssertTrue(gesture.consume(type: .flagsChanged, keyCode: fn, modifiers: .capsLock))
    }
}
