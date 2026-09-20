import AppKit
import Carbon.HIToolbox

final class ShortcutRecorderView: NSView {
    var onRecord: ((HotKey) -> Void)?

    var hotKey: HotKey? {
        didSet { needsDisplay = true }
    }

    private var isRecording = false

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text: String
        if isRecording {
            text = "请输入快捷键…"
        } else if let hotKey {
            text = hotKey.displayString
        } else {
            text = "点击后按下快捷键"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 { // Esc cancels
            isRecording = false
            needsDisplay = true
            return
        }
        guard let hotKey = ShortcutRecorderView.makeHotKey(from: event) else {
            NSSound.beep()
            return
        }
        self.hotKey = hotKey
        isRecording = false
        needsDisplay = true
        onRecord?(hotKey)
    }

    static func makeHotKey(from event: NSEvent) -> HotKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0 else { return nil }
        return HotKey(keyCode: UInt32(event.keyCode),
                      modifiers: modifiers,
                      name: keyName(for: event))
    }

    private static func keyName(for event: NSEvent) -> String {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty {
            return characters.uppercased()
        }
        return "Key \(event.keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
        115: "Home", 116: "PageUp", 119: "End", 121: "PageDown",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

final class ShortcutRecorderWindowController: NSWindowController {
    let recorderView = ShortcutRecorderView()
    var onRecord: ((HotKey) -> Void)?

    init(initial: HotKey?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "自定义快捷键"
        panel.isReleasedWhenClosed = false
        panel.center()
        super.init(window: panel)

        recorderView.hotKey = initial
        recorderView.frame = NSRect(x: 20, y: 52, width: 260, height: 42)
        recorderView.autoresizingMask = [.width, .minYMargin]
        recorderView.onRecord = { [weak self] hotKey in
            self?.onRecord?(hotKey)
            self?.close()
        }
        panel.contentView?.addSubview(recorderView)

        let hint = NSTextField(wrappingLabelWithString: "点击方框后按下新的组合键，需包含 ⌃⌥⇧⌘ 之一。按 Esc 取消。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 16, width: 260, height: 30)
        panel.contentView?.addSubview(hint)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        activate()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(recorderView)
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
