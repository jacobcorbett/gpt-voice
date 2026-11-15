import XCTest
@testable import GPTVoice

final class FunctionKeyActivationTests: XCTestCase {
    func testDoubleTapTogglesOnceAndCanBeRepeatedToFinish() {
        var state = FunctionKeyActivation()
        for base in [0.0, 1.0] {
            state.press(at: base)
            XCTAssertNil(state.release(at: base + 0.05, mode: .hold, doubleTap: true))
            state.press(at: base + 0.15)
            XCTAssertEqual(state.release(at: base + 0.2, mode: .hold, doubleTap: true), .toggle)
        }
        state.press(at: 1.25)
        XCTAssertNil(state.release(at: 1.3, mode: .hold, doubleTap: true))
    }

    func testHoldUsesReleaseAndClearsAnEarlierTap() {
        var state = FunctionKeyActivation()
        state.press(at: 0)
        XCTAssertNil(state.release(at: 0.05, mode: .hold, doubleTap: true))
        state.press(at: 0.1)
        XCTAssertEqual(state.held(), .beginHold)
        XCTAssertNil(state.held())
        XCTAssertEqual(state.release(at: 1, mode: .hold, doubleTap: true), .endHold)
        state.press(at: 1.1)
        XCTAssertNil(state.release(at: 1.15, mode: .hold, doubleTap: true))
    }

    func testSlowTapsAndDisabledDoubleTapDoNotToggle() {
        var state = FunctionKeyActivation()
        state.press(at: 0)
        XCTAssertNil(state.release(at: 0.05, mode: .hold, doubleTap: true))
        state.press(at: 0.6)
        XCTAssertNil(state.release(at: 0.65, mode: .hold, doubleTap: true))
        state.press(at: 0.7)
        XCTAssertNil(state.release(at: 0.75, mode: .hold, doubleTap: false))
    }

    func testChordsCancelBothTheHoldAndPendingDoubleTap() {
        var state = FunctionKeyActivation()
        state.press(at: 0)
        XCTAssertNil(state.release(at: 0.05, mode: .hold, doubleTap: true))
        XCTAssertNil(state.cancel())
        state.press(at: 0.1)
        XCTAssertNil(state.release(at: 0.15, mode: .hold, doubleTap: true))
        state.press(at: 1)
        XCTAssertEqual(state.held(), .beginHold)
        XCTAssertEqual(state.cancel(), .cancelHold)
        XCTAssertNil(state.release(at: 2, mode: .hold, doubleTap: true))
        XCTAssertNil(state.held())
    }

    func testSingleTapToggleModeAndReleaseWithoutPress() {
        var state = FunctionKeyActivation()
        XCTAssertNil(state.release(at: 0, mode: .toggle, doubleTap: true))
        state.press(at: 1)
        XCTAssertEqual(state.release(at: 1.1, mode: .toggle, doubleTap: true), .toggle)
    }

    func testHoldUsesElapsedTimeWithoutWaitingForATimer() {
        var state = FunctionKeyActivation()
        state.press(at: 0)
        XCTAssertNil(state.release(at: 0.05, mode: .hold, doubleTap: true))
        state.press(at: 0.1)
        XCTAssertEqual(state.release(at: 0.3, mode: .hold, doubleTap: true), .endHold)
    }
}
