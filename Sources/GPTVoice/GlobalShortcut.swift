import Carbon.HIToolbox
import Foundation
import AppKit

/// Uses Carbon for key combinations and AppKit event monitors for standalone Fn.
/// Fn monitoring requires Accessibility permission; ordinary shortcuts do not.
@MainActor
final class GlobalShortcut {
    enum RegistrationError: LocalizedError, Equatable {
        case invalid(HotkeySpec.Problem)
        case conflict
        case systemShortcut(HotkeySpec)
        case system(OSStatus)
        case functionKeyAccess
        case functionKeyMonitor

        var errorDescription: String? {
            switch self {
            case .invalid(let problem): return problem.message
            case .conflict: return "Another app uses this shortcut. Choose another one."
            case .systemShortcut(let spec):
                return spec == .commandSpace
                    ? "Spotlight uses Command–Space. Turn off or change that shortcut in System Settings → Keyboard → Keyboard Shortcuts → Spotlight, then try again."
                    : "macOS uses this shortcut. Change it in System Settings → Keyboard → Keyboard Shortcuts, then try again."
            case .system(let status): return "macOS could not register this shortcut (error \(status))."
            case .functionKeyAccess:
                return "Allow GPT Voice in System Settings > Privacy & Security > Accessibility to use Fn, then try again."
            case .functionKeyMonitor:
                return "macOS could not listen for Fn. Choose another shortcut or restart GPT Voice."
            }
        }
    }

    private static let signature: OSType = 0x4344_6374 // "CDct"

    private(set) var current: HotkeySpec?
    private var currentRef: EventHotKeyRef?
    private(set) var currentID: UInt32 = 0
    private static var nextID: UInt32 = 1
    private var handlerRef: EventHandlerRef?
    private var functionGlobalMonitor: Any?
    private var functionLocalMonitor: Any?
    private var functionGesture = FunctionKeyGesture()
    private var functionActivation = FunctionKeyActivation()
    private var functionStartedHold = false
    var mode: ShortcutMode = .toggle {
        didSet { resetFunctionActivation() }
    }
    var doubleTapToToggle = false {
        didSet { resetFunctionActivation() }
    }
    private let onPress: @MainActor () -> Void
    private let onRelease: @MainActor () -> Void
    private let onCancel: @MainActor () -> Void
    private let onToggle: @MainActor () -> Void

    init(onPress: @escaping @MainActor () -> Void,
         onRelease: @escaping @MainActor () -> Void = {},
         onCancel: @escaping @MainActor () -> Void = {},
         onToggle: (@MainActor () -> Void)? = nil) {
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onToggle = onToggle ?? onPress
        installHandler()
    }

    deinit {
        if let currentRef { UnregisterEventHotKey(currentRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        if let functionGlobalMonitor { NSEvent.removeMonitor(functionGlobalMonitor) }
        if let functionLocalMonitor { NSEvent.removeMonitor(functionLocalMonitor) }
    }

    /// Registers `spec` as the active shortcut. The previous shortcut stays
    /// active when the new registration fails.
    func replace(with spec: HotkeySpec) throws {
        if let problem = spec.problem { throw RegistrationError.invalid(problem) }
        if spec.isFunctionOnly {
            try registerFunctionKey()
            return
        }
        if Self.isSystemShortcutEnabled(spec) { throw RegistrationError.systemShortcut(spec) }
        if spec == current, currentRef != nil { return }

        let previousRef = currentRef
        // The same combination cannot register twice. Release it first, and put it back on failure.
        let sameCombination = previousRef != nil && current.map {
            $0.keyCode == spec.keyCode && $0.modifiers == spec.modifiers
        } == true
        if sameCombination, let previousRef {
            UnregisterEventHotKey(previousRef)
            currentRef = nil
        }

        let id = Self.nextID
        Self.nextID &+= 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            if sameCombination, let old = current { restore(old) }
            throw status == OSStatus(eventHotKeyExistsErr) ? RegistrationError.conflict : RegistrationError.system(status)
        }
        if !sameCombination, let previousRef { UnregisterEventHotKey(previousRef) }
        currentRef = ref
        currentID = id
        removeFunctionMonitors()
        current = spec
    }

    /// Removes the active shortcut.
    func unregister() {
        if let currentRef { UnregisterEventHotKey(currentRef) }
        currentRef = nil
        removeFunctionMonitors()
        current = nil
    }

    private func registerFunctionKey() throws {
        guard AccessibilityPermission.check() else { throw RegistrationError.functionKeyAccess }
        if current == .function, functionGlobalMonitor != nil, functionLocalMonitor != nil { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .systemDefined]
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleFunctionEvent(event)
        }) else { throw RegistrationError.functionKeyMonitor }
        guard let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handleFunctionEvent(event)
            return event
        }) else {
            NSEvent.removeMonitor(global)
            throw RegistrationError.functionKeyMonitor
        }
        // Keep the previous shortcut active until both monitors are installed.
        if let currentRef { UnregisterEventHotKey(currentRef) }
        currentRef = nil
        removeFunctionMonitors()
        functionGlobalMonitor = global
        functionLocalMonitor = local
        current = .function
    }

    private func handleFunctionEvent(_ event: NSEvent) {
        guard current == .function else { return }
        // systemDefined events (including media keys) do not have an AppKit keyCode.
        let code: UInt16 = event.type == .systemDefined ? 0 : event.keyCode
        handleFunctionGesture(functionGesture.update(type: event.type, keyCode: code, modifiers: event.modifierFlags),
                              at: event.timestamp, interruptsDoubleTap: event.type != .flagsChanged || Int(code) != kVK_Function)
    }

    func handleFunctionGesture(_ gesture: FunctionKeyGesture.Action?, at timestamp: TimeInterval,
                               interruptsDoubleTap: Bool = false) {
        switch gesture {
        case .pressed:
            functionActivation.press(at: timestamp)
            if mode == .hold {
                // Show the pill and start capture on key-down. A quick tap or
                // chord cancels its short recording without sending any audio.
                functionStartedHold = true
                onPress()
            }
        case .released:
            let action = functionActivation.release(at: timestamp, mode: mode,
                                                     doubleTap: doubleTapToToggle)
            if functionStartedHold, action == nil { onCancel() }
            functionStartedHold = false
            deliverFunctionAction(action)
        case .cancelled:
            resetFunctionActivation()
        case nil:
            // Typing between two Fn taps breaks the double-tap gesture.
            if interruptsDoubleTap { resetFunctionActivation() }
        }
    }

    private func deliverFunctionAction(_ action: FunctionKeyActivation.Action?) {
        switch action {
        case .beginHold: onPress()
        case .endHold: onRelease()
        case .cancelHold: onCancel()
        case .toggle: onToggle()
        case nil: break
        }
    }

    private func resetFunctionActivation() {
        let action = functionActivation.cancel()
        if functionStartedHold { onCancel() }
        else { deliverFunctionAction(action) }
        functionStartedHold = false
    }

    private func removeFunctionMonitors() {
        resetFunctionActivation()
        if let functionGlobalMonitor { NSEvent.removeMonitor(functionGlobalMonitor) }
        if let functionLocalMonitor { NSEvent.removeMonitor(functionLocalMonitor) }
        functionGlobalMonitor = nil
        functionLocalMonitor = nil
        functionGesture = FunctionKeyGesture()
    }

    private func restore(_ spec: HotkeySpec) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: currentID),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if status == noErr { currentRef = ref } else { current = nil }
    }

    func handlePress(id: UInt32, released: Bool = false) {
        guard id == currentID, currentRef != nil else { return }
        if released { onRelease() } else { onPress() }
    }

    static func isSystemShortcutEnabled(_ spec: HotkeySpec) -> Bool {
        var shortcuts: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&shortcuts) == noErr,
              let entries = shortcuts?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard (entry[kHISymbolicHotKeyEnabled] as? NSNumber)?.boolValue == true,
                  let code = entry[kHISymbolicHotKeyCode] as? NSNumber,
                  let modifiers = entry[kHISymbolicHotKeyModifiers] as? NSNumber else { return false }
            return HotkeySpec(keyCode: code.uint32Value, modifiers: modifiers.uint32Value) == spec
        }
    }

    private func installHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalShortcut.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
            guard hotKeyID.id == shortcut.currentID, shortcut.currentRef != nil else {
                return OSStatus(eventNotHandledErr)
            }
            let id = hotKeyID.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async { shortcut.handlePress(id: id, released: released) }
            return noErr
        }, eventTypes.count, &eventTypes, context, &handlerRef)
    }
}
