import Carbon

@MainActor
final class EmergencyShortcut {
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private let action: @MainActor () -> Void

    init?(action: @escaping @MainActor () -> Void) {
        self.action = action
        let target = GetApplicationEventTarget()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(target, { _, event, context in
            var pressed = EventHotKeyID(signature: 0, id: 0)
            guard let context,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr,
                  pressed.signature == 0x54475544, pressed.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<EmergencyShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let id = EventHotKeyID(signature: 0x54475544, id: 1)
        guard RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | shiftKey | optionKey),
                                  id, target, 0, &hotkey) == noErr else { return nil }
    }

    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
