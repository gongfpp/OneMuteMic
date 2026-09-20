import AppKit
import UserNotifications

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let mic = MicController()
    private let hotKeys = HotKeyManager()
    private let defaults = UserDefaults.standard

    private let soundKey = "soundEnabled"
    private let notificationKey = "notificationEnabled"
    private let hotKeyCodeKey = "hotKeyCode"
    private let hotKeyModifiersKey = "hotKeyModifiers"
    private let hotKeyNameKey = "hotKeyName"

    private let statusItemTag = 100
    private let toggleItemTag = 101

    private var soundEnabled: Bool
    private var notificationEnabled: Bool
    private var activeHotKey: HotKey
    private var recorderWindow: ShortcutRecorderWindowController?

    private lazy var muteSound = NSSound(named: "Pop")
    private lazy var unmuteSound = NSSound(named: "Tink")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defaults.register(defaults: [
            soundKey: true,
            notificationKey: false,
        ])
        soundEnabled = defaults.bool(forKey: soundKey)
        notificationEnabled = defaults.bool(forKey: notificationKey)
        activeHotKey = HotKey.presets[0]
        super.init()

        activeHotKey = storedHotKey()
        configureStatusItem()
        mic.onChange = { [weak self] in self?.updateAppearance() }
        hotKeys.onPressed = { [weak self] in self?.toggleMute() }
        applyHotKey(activeHotKey, reportConflict: false)
        updateAppearance()

        if notificationEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - Hot key persistence

    private func storedHotKey() -> HotKey {
        guard defaults.object(forKey: hotKeyCodeKey) != nil else { return HotKey.presets[0] }
        return HotKey(keyCode: UInt32(defaults.integer(forKey: hotKeyCodeKey)),
                      modifiers: UInt32(defaults.integer(forKey: hotKeyModifiersKey)),
                      name: defaults.string(forKey: hotKeyNameKey) ?? "?")
    }

    private func persist(_ hotKey: HotKey) {
        defaults.set(Int(hotKey.keyCode), forKey: hotKeyCodeKey)
        defaults.set(Int(hotKey.modifiers), forKey: hotKeyModifiersKey)
        defaults.set(hotKey.name, forKey: hotKeyNameKey)
    }

    private func applyHotKey(_ hotKey: HotKey, reportConflict: Bool = true) {
        if hotKeys.register(hotKey) {
            activeHotKey = hotKey
            persist(hotKey)
            return
        }
        NSSound.beep()
        hotKeys.register(activeHotKey)
        if reportConflict {
            presentAlert(title: "快捷键不可用",
                         message: "\(hotKey.displayString) 已被其他应用占用，请换一个组合键。")
        }
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func updateAppearance() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let tint: NSColor
        let description: String
        switch mic.status {
        case .muted:
            symbolName = "mic.slash.fill"
            tint = .systemRed
            description = "麦克风已静音"
        case .live:
            symbolName = "mic.fill"
            tint = .systemGreen
            description = "麦克风使用中"
        case .unsupported:
            symbolName = "mic.fill"
            tint = .secondaryLabelColor
            description = "麦克风状态未知"
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false

        button.image = image
        button.toolTip = "OneMuteMic — \(description)"
    }

    private var statusDescription: String {
        switch mic.status {
        case .muted: return "麦克风：已静音"
        case .live: return "麦克风：使用中"
        case .unsupported: return "麦克风：不支持静音控制"
        }
    }

    // MARK: - Actions

    @objc private func statusButtonClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggleMute()
        }
    }

    @objc private func toggleMute() {
        let wasMuted = mic.status == .muted
        guard mic.toggle() else {
            NSSound.beep()
            return
        }
        let nowMuted = mic.status == .muted
        guard nowMuted != wasMuted else { return }
        playFeedback(muted: nowMuted)
        if notificationEnabled {
            postNotification(title: nowMuted ? "麦克风已静音" : "麦克风已开启", body: "")
        }
    }

    @objc private func toggleSound() {
        soundEnabled.toggle()
        defaults.set(soundEnabled, forKey: soundKey)
    }

    @objc private func toggleNotification() {
        if notificationEnabled {
            notificationEnabled = false
            defaults.set(false, forKey: notificationKey)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.notificationEnabled = false
                    self.defaults.set(false, forKey: self.notificationKey)
                    self.presentNotificationSettingsAlert()
                    return
                }
                self.notificationEnabled = true
                self.defaults.set(true, forKey: self.notificationKey)
                self.postNotification(title: "通知已开启", body: "静音或取消静音时会收到提醒")
            }
        }
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let hotKey = sender.representedObject as? HotKey else { return }
        applyHotKey(hotKey)
    }

    @objc private func openRecorder() {
        let controller = recorderWindow ?? ShortcutRecorderWindowController(initial: activeHotKey)
        controller.onRecord = { [weak self] hotKey in self?.applyHotKey(hotKey) }
        controller.recorderView.hotKey = activeHotKey
        recorderWindow = controller
        controller.showWindow(nil)
    }

    // MARK: - Feedback

    private func playFeedback(muted: Bool) {
        guard soundEnabled else { return }
        (muted ? muteSound : unmuteSound)?.play()
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func presentAlert(title: String, message: String) {
        activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentNotificationSettingsAlert() {
        activate()
        let alert = NSAlert()
        alert.messageText = "通知权限未开启"
        alert.informativeText = "如果列表里找不到 OneMuteMic，请先把 App 拖入「应用程序」文件夹再运行一次，系统才会登记它。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开通知设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            openNotificationSettings()
        }
    }

    @objc private func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mass.onemutemic"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Menu

    private func showMenu() {
        buildMenu()
        guard let button = statusItem.button, let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func buildMenu() {
        menu.removeAllItems()

        let statusMenuItem = NSMenuItem(title: statusDescription, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        statusMenuItem.tag = statusItemTag
        menu.addItem(statusMenuItem)

        let toggleItem = NSMenuItem(title: "切换静音\t\(activeHotKey.displayString)",
                                    action: #selector(toggleMute),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.tag = toggleItemTag
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let soundItem = NSMenuItem(title: "提示音",
                                   action: #selector(toggleSound),
                                   keyEquivalent: "")
        soundItem.target = self
        soundItem.state = soundEnabled ? .on : .off
        menu.addItem(soundItem)

        let notificationItem = NSMenuItem(title: "通知提醒",
                                          action: #selector(toggleNotification),
                                          keyEquivalent: "")
        notificationItem.target = self
        notificationItem.state = notificationEnabled ? .on : .off
        menu.addItem(notificationItem)

        let notificationSettingsItem = NSMenuItem(title: "打开通知设置…",
                                                  action: #selector(openNotificationSettings),
                                                  keyEquivalent: "")
        notificationSettingsItem.target = self
        menu.addItem(notificationSettingsItem)

        let hotKeyItem = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        hotKeyItem.submenu = buildHotKeyMenu()
        menu.addItem(hotKeyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    private func buildHotKeyMenu() -> NSMenu {
        let submenu = NSMenu()
        for preset in HotKey.presets {
            let item = NSMenuItem(title: preset.displayString,
                                  action: #selector(selectPreset(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            item.state = preset.matches(activeHotKey) ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let customItem = NSMenuItem(title: "自定义快捷键…",
                                    action: #selector(openRecorder),
                                    keyEquivalent: "")
        customItem.target = self
        customItem.state = HotKey.presets.contains { $0.matches(activeHotKey) } ? .off : .on
        submenu.addItem(customItem)
        return submenu
    }
}
