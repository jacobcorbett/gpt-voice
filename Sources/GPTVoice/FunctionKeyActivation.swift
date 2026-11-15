import Foundation

/// Interprets Fn edges without recording audio. Short taps can form a toggle
/// gesture, while a held key owns a recording only until its release.
struct FunctionKeyActivation {
    enum Action: Equatable { case beginHold, endHold, cancelHold, toggle }
    static let holdDelay: TimeInterval = 0.18
    static let doubleTapInterval: TimeInterval = 0.35
    private var pressedAt: TimeInterval?
    private var previousTapAt: TimeInterval?
    private var holdBegan = false

    mutating func press(at time: TimeInterval) { pressedAt = time }

    mutating func held() -> Action? {
        guard pressedAt != nil, !holdBegan else { return nil }
        holdBegan = true
        previousTapAt = nil
        return .beginHold
    }

    mutating func release(at time: TimeInterval, mode: ShortcutMode, doubleTap: Bool) -> Action? {
        guard let start = pressedAt else { return nil }
        pressedAt = nil
        if holdBegan || (mode == .hold && time - start >= Self.holdDelay) {
            holdBegan = false
            previousTapAt = nil
            return .endHold
        }
        if mode == .toggle { previousTapAt = nil; return .toggle }
        guard doubleTap, time - start < Self.holdDelay else { previousTapAt = nil; return nil }
        if let previous = previousTapAt, time - previous <= Self.doubleTapInterval {
            previousTapAt = nil
            return .toggle
        }
        previousTapAt = time
        return nil
    }

    mutating func cancel() -> Action? {
        let action: Action? = holdBegan ? .cancelHold : nil
        self = FunctionKeyActivation()
        return action
    }
}
