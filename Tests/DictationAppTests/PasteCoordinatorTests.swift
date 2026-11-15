import AppKit
import DictationCore
import XCTest
@testable import GPTVoice

final class PasteCoordinatorTests: XCTestCase {
    @MainActor
    func testRetainingTranscriptLeavesItReadyForAnotherPaste() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        var pasteCount = 0
        let coordinator = PasteCoordinator(pasteboard: board, platform: PastePlatform(
            isAutomaticPasteAvailable: { true }, postPaste: { pasteCount += 1; return true }))
        coordinator.beginSession(keepTranscriptOnClipboard: true)
        var notified = false
        let result = await coordinator.deliver(text: "Hello world", automaticPaste: true) { _ in
            notified = true
            XCTAssertEqual(board.string(forType: .string), "Hello world")
        }
        guard case .pasted = result else { return XCTFail("Expected automatic paste") }
        XCTAssertTrue(notified)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertFalse(coordinator.isLeasePending)
        XCTAssertEqual(board.string(forType: .string), "Hello world")
    }

    @MainActor
    func testSuccessIsReportedBeforeClipboardRestoration() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        let coordinator = PasteCoordinator(pasteboard: board, platform: PastePlatform(
            isAutomaticPasteAvailable: { true }, postPaste: { true }))
        coordinator.beginSession()
        var notified = false
        _ = await coordinator.deliver(text: "Transcript", automaticPaste: true) { _ in
            notified = true
            XCTAssertTrue(coordinator.isLeasePending)
            XCTAssertEqual(board.string(forType: .string), "Transcript")
        }
        XCTAssertTrue(notified)
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }

    @MainActor
    func testNewerClipboardIsProtectedWithRetentionEnabled() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var pasted = false
        let coordinator = PasteCoordinator(pasteboard: board, platform: PastePlatform(
            isAutomaticPasteAvailable: { true }, postPaste: { pasted = true; return true }))
        coordinator.beginSession(keepTranscriptOnClipboard: true)
        board.clearContents()
        board.setString("newer copy", forType: .string)
        let result = await coordinator.deliver(text: "Transcript", automaticPaste: true)
        XCTAssertEqual(result, .preservedNewerClipboard)
        XCTAssertFalse(pasted)
        XCTAssertEqual(board.string(forType: .string), "newer copy")
    }

    @MainActor
    func testRestorationDoesNotOverwriteACopyMadeAfterPaste() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let coordinator = PasteCoordinator(pasteboard: board, platform: PastePlatform(
            isAutomaticPasteAvailable: { true }, postPaste: { true }))
        coordinator.beginSession()
        _ = await coordinator.deliver(text: "Transcript", automaticPaste: true) { _ in
            board.clearContents()
            board.setString("newer copy", forType: .string)
        }
        XCTAssertEqual(board.string(forType: .string), "newer copy")
    }

    @MainActor
    func testFailedInjectionKeepsTextForManualRecovery() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let coordinator = PasteCoordinator(pasteboard: board, platform: PastePlatform(
            isAutomaticPasteAvailable: { true }, postPaste: { false }))
        coordinator.beginSession()
        let result = await coordinator.deliver(text: "Transcript", automaticPaste: true) { _ in
            XCTFail("A failed paste must not announce success")
        }
        XCTAssertEqual(result, .copied(.injectionFailed))
        XCTAssertEqual(board.string(forType: .string), "Transcript")
    }
}
