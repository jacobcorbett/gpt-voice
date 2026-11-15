import Foundation

enum ShortcutMode: String, CaseIterable, Identifiable {
    case toggle, hold
    var id: String { rawValue }
    var title: String { self == .hold ? "Hold" : "Toggle" }
    var detail: String {
        self == .hold
            ? "Hold to record. Release to transcribe."
            : "Press once to start. Press again to stop."
    }
}

/// Tracks only recordings opened by a held shortcut, including a release while
/// the microphone is still starting. A release must not stop a menu recording.
struct HoldToDictateState {
    private(set) var ownsRecording = false
    private(set) var stopWhenReady = false

    mutating func press(canStart: Bool) -> Bool {
        guard canStart, !ownsRecording else { return false }
        ownsRecording = true
        stopWhenReady = false
        return true
    }

    mutating func release(isPreparing: Bool) -> Bool {
        guard ownsRecording else { return false }
        ownsRecording = false
        stopWhenReady = isPreparing
        return !isPreparing
    }

    mutating func recordingStarted() -> Bool {
        let stop = stopWhenReady
        stopWhenReady = false
        return stop
    }

    mutating func reset() { self = HoldToDictateState() }
}
