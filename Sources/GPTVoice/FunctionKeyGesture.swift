import AppKit
import Carbon.HIToolbox

/// Tracks standalone Fn presses, releases and cancellation by other keys.
/// Shared by the shortcut recorder and the local/global event monitors.
struct FunctionKeyGesture {
    enum Action { case pressed, released, cancelled }
    private var isCandidate = false

    mutating func consume(type: NSEvent.EventType, keyCode: UInt16,
                          modifiers: NSEvent.ModifierFlags) -> Bool {
        update(type: type, keyCode: keyCode, modifiers: modifiers) == .released
    }

    mutating func update(type: NSEvent.EventType, keyCode: UInt16,
                         modifiers: NSEvent.ModifierFlags) -> Action? {
        guard type == .flagsChanged else {
            let cancelled = isCandidate
            isCandidate = false
            return cancelled ? .cancelled : nil
        }
        let otherModifiers = modifiers.intersection([.control, .option, .shift, .command])
        guard Int(keyCode) == kVK_Function else {
            let cancelled = isCandidate
            isCandidate = false
            return cancelled ? .cancelled : nil
        }
        if modifiers.contains(.function) {
            guard !isCandidate else { return nil }
            isCandidate = otherModifiers.isEmpty
            return isCandidate ? .pressed : nil
        }
        let tapped = isCandidate && otherModifiers.isEmpty
        isCandidate = false
        return tapped ? .released : nil
    }
}
