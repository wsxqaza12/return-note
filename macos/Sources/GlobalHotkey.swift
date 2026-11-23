import AppKit
import Carbon

/// Register one system hotkey; no keyboard monitoring or Accessibility permission.
final class GlobalHotkey {
    private let signature: OSType = 0x526E4F74 // RnOt
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }
    func register() -> Bool {
        guard handler == nil else { return hotkey != nil }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let target = GetApplicationEventTarget()
        let install = InstallEventHandler(target, { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr,
                  key.signature == owner.signature, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            owner.action()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard install == noErr else { return false }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey),
                                         EventHotKeyID(signature: signature, id: 1), target, 0, &hotkey)
        return result == noErr
    }

    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
