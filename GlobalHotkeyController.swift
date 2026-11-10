import AppKit
import Carbon.HIToolbox

/// Registers exclusive combinations instead of observing key events delivered to other apps.
final class GlobalHotkeyController {
    struct Shortcut {
        let id: UInt32
        let keyCode: UInt32
        let modifiers: NSEvent.ModifierFlags
        let title: String
    }
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    private var registeredIDs = Set<UInt32>()
    private var pressed = Set<UInt32>()
    private var generation: UInt32 = 0
    var onPress: ((UInt32) -> Void)?

    #if DISKOUT_HOTKEY_TESTING
    var eventSignatureForTesting: UInt32 { generation }
    #endif

    func register(_ shortcuts: [Shortcut]) -> [String] {
        precondition(Thread.isMainThread)
        invalidate()
        generation &+= 1
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<GlobalHotkeyController>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == controller.generation,
                  controller.registeredIDs.contains(identifier.id) else {
                return OSStatus(eventNotHandledErr)
            }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                controller.pressed.remove(identifier.id)
            } else if controller.pressed.insert(identifier.id).inserted {
                controller.onPress?(identifier.id)
            }
            return noErr
        }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return shortcuts.map(\.title) }
        var failed: [String] = []
        for shortcut in shortcuts {
            var reference: EventHotKeyRef?
            var flags: UInt32 = 0
            for (flag, carbon) in [(NSEvent.ModifierFlags.command, cmdKey), (.option, optionKey),
                                    (.control, controlKey), (.shift, shiftKey)] where shortcut.modifiers.contains(flag) {
                flags |= UInt32(carbon)
            }
            let status = RegisterEventHotKey(shortcut.keyCode, flags,
                EventHotKeyID(signature: generation, id: shortcut.id), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference {
                registrations.append(reference)
                registeredIDs.insert(shortcut.id)
            }
            else { failed.append(shortcut.title) }
        }
        return failed
    }

    func invalidate() {
        precondition(Thread.isMainThread)
        registrations.forEach { UnregisterEventHotKey($0) }
        registrations.removeAll()
        registeredIDs.removeAll()
        pressed.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { invalidate() }
}
