import Carbon.HIToolbox
import Foundation

struct HotKey: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let name: String

    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + name
    }

    func matches(_ other: HotKey) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    static let presets: [HotKey] = [
        HotKey(keyCode: 46, modifiers: UInt32(controlKey | optionKey), name: "M"),
        HotKey(keyCode: 46, modifiers: UInt32(cmdKey | shiftKey), name: "M"),
        HotKey(keyCode: 49, modifiers: UInt32(controlKey | optionKey), name: "Space"),
        HotKey(keyCode: 49, modifiers: UInt32(cmdKey | shiftKey), name: "Space"),
        HotKey(keyCode: 2, modifiers: UInt32(controlKey | optionKey), name: "D"),
    ]
}

final class HotKeyManager {
    private static let signature: OSType = 0x4F4D4D31 // 'OMM1'

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var onPressed: (() -> Void)?

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue().onPressed?()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        unregister()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(hotKey.keyCode,
                                         hotKey.modifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr else { return false }
        hotKeyRef = ref
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
