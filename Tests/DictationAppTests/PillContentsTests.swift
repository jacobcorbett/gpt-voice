import XCTest
@testable import GPTVoice

final class PillContentsTests: XCTestCase {
    func testAnEmptyConfigurationStillShowsRecording() throws {
        let contents = PillContents(waveform: false, timer: false, recordingDot: false,
                                    cancelButton: false, stopButton: false, statusText: false)
        XCTAssertTrue(contents.showsWaveform)
        XCTAssertEqual(try JSONDecoder().decode(PillContents.self, from: JSONEncoder().encode(contents)), contents)
    }

    func testWaveformCanBeHiddenWhenTimerOrDotIsVisible() {
        var contents = PillContents.standard
        contents.waveform = false
        XCTAssertFalse(contents.showsWaveform)
        contents.timer = false
        XCTAssertFalse(contents.showsWaveform)
        contents.recordingDot = false
        XCTAssertTrue(contents.showsWaveform)
    }
}
