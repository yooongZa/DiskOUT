import AppKit
import Carbon.HIToolbox

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
private enum GlobalHotkeyControllerTests {
    static func main() {
        _ = NSApplication.shared
        let first = GlobalHotkeyController()
        let second = GlobalHotkeyController()
        let shortcut = GlobalHotkeyController.Shortcut(id: 7, keyCode: UInt32(kVK_F19),
            modifiers: [.command, .option, .control, .shift], title: "test F19")
        expect(first.register([shortcut]).isEmpty, "isolated test shortcut registers")
        expect(second.register([shortcut]) == [shortcut.title], "exclusive collision is reported instead of sharing the shortcut")
        var presses = 0
        first.onPress = { id in expect(id == 7, "the registered role is dispatched"); presses += 1 }
        func send(_ kind: UInt32, signature: UInt32) {
            var event: EventRef?
            expect(CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(),
                               EventAttributes(kEventAttributeUserEvent), &event) == noErr, "create test Carbon event")
            var identifier = EventHotKeyID(signature: signature, id: 7)
            SetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              MemoryLayout<EventHotKeyID>.size, &identifier)
            SendEventToEventTarget(event!, GetApplicationEventTarget())
            ReleaseEvent(event!)
        }
        let signature = first.eventSignatureForTesting
        send(UInt32(kEventHotKeyPressed), signature: signature)
        send(UInt32(kEventHotKeyPressed), signature: signature)
        expect(presses == 1, "key repeat cannot run a destructive command twice")
        send(UInt32(kEventHotKeyReleased), signature: signature)
        send(UInt32(kEventHotKeyPressed), signature: signature)
        expect(presses == 2, "a subsequent physical press dispatches once")
        expect(first.register([shortcut]).isEmpty, "changing settings can re-register the combination")
        send(UInt32(kEventHotKeyPressed), signature: signature)
        expect(presses == 2, "queued events from an old registration are ignored")
        first.invalidate()
        expect(second.register([shortcut]).isEmpty, "unregister releases the combination")
        second.invalidate()
        print("GlobalHotkeyControllerTests: PASS (registration, conflict, repeat, stale event, release)")
    }
}
