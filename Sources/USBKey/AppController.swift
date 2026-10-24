import AppKit
import SwiftUI
import Combine
import KeyCore

private final class SocketReply: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data([5])
    func set(_ value: Data) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor private final class StatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = Model()
    let background: Bool
    private var status: NSStatusItem?
    private var iconConnected: Bool?
    private var panel: StatusPanel?
    private var panelHost: NSHostingView<AnyView>?
    private var modelChanges: AnyCancellable?
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var menuTarget: TypingTarget?
    private var previousApplication: NSRunningApplication?
    private var inputTask: Task<Void, Never>?
    private var hotKey: GlobalHotKey?
    private var hotKeyConfiguration: Shortcut?
    private var hotKeyInitialized = false
    private var restartAlertVisible = false
    private var restarting = false
    private var window: NSWindow?
    private var server: AgentServer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    init(background: Bool) { self.background = background }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        model.refresh()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.target = self; status?.button?.action = #selector(togglePopover)
        updateIcon()
        configureStatusPanel()
        let hotKey = GlobalHotKey()
        hotKey.action = { [weak self] in self?.beginTyping(fromMenu: false) }
        self.hotKey = hotKey
        synchronizeHotKey()
        startAgent()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh(); self?.updateIcon(); self?.positionStatusPanel(); self?.offerPermissionRestart() }
        }
        let center = NSWorkspace.shared.notificationCenter
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSWorkspace.didActivateApplicationNotification {
                        self?.model.noteActivatedApplication((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
                        self?.offerPermissionRestart()
                    }
                    let front = NSWorkspace.shared.frontmostApplication
                    if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        self?.rememberExternalApplication(front)
                    } else {
                        self?.rememberExternalApplication(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
                    }
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.lockSession() } })
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.lockSession() } })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.sessionLocked = false; self?.model.refresh() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.sessionLocked = false; self?.model.refresh() } })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.lockSession() } })
        observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.model.sessionLocked = false; self?.model.refresh() } })
        if !background { showMain() }
    }
    private func installMainMenu() {
        let bar = NSMenu()
        let appMenu = NSMenu()
        let manage = NSMenuItem(title: "Управление USBKey…", action: #selector(openManagement), keyEquivalent: ",")
        manage.target = self; appMenu.addItem(manage); appMenu.addItem(.separator())
        let menu = NSMenuItem(title: "Открыть меню в строке состояния", action: #selector(togglePopover), keyEquivalent: "")
        menu.target = self; appMenu.addItem(menu)
        appMenu.addItem(withTitle: "Завершить USBKey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; bar.addItem(appItem)
        let edit = NSMenu(title: "Правка")
        for (title, action, shortcut) in [("Отменить", "undo:", "z"), ("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"), ("Вставить", "paste:", "v"), ("Выделить всё", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: shortcut)
        }
        let item = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); item.submenu = edit; bar.addItem(item)
        NSApp.mainMenu = bar
    }
    @objc private func openManagement() { showMain() }
    private func startAgent() {
        do {
            try model.store.prepare()
            let model = self.model
            let agent = AgentServer(path: model.socketPath) { packet in
                let semaphore = DispatchSemaphore(value: 0), box = SocketReply()
                Task { @MainActor in box.set(await model.agentReply(packet)); semaphore.signal() }
                semaphore.wait()
                return box.get()
            }
            try agent.start(); server = agent; model.agentStatus = "SSH-агент работает"
        } catch { model.agentStatus = "SSH-агент: " + error.localizedDescription }
    }
    private func updateIcon() {
        guard iconConnected != model.connected else { return }
        iconConnected = model.connected
        let image = NSImage(systemSymbolName: model.connected ? "key.horizontal.fill" : "key.horizontal", accessibilityDescription: "USBKey")
        image?.isTemplate = true; status?.button?.image = image
        status?.button?.toolTip = model.connected ? "USBKey — флешка подключена" : "USBKey — нет доступного ключа"
    }
    private func configureStatusPanel() {
        let panel = StatusPanel(contentRect: NSRect(x: 0, y: 0, width: 350, height: 250),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "USBKey — меню"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = StatusView(model: model, typeValue: { [weak self] in self?.beginTyping(fromMenu: true) }, openMain: { [weak self] in self?.showMain() })
            .fixedSize(horizontal: false, vertical: true)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        let host = NSHostingView(rootView: AnyView(content))
        panel.contentView = host
        self.panel = panel; panelHost = host
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.positionStatusPanel(); self?.synchronizeHotKey(); self?.offerPermissionRestart() }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.orderOut(nil) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.panel?.isVisible == true else { return false }
                if event.type == .keyDown && event.keyCode == 53 { self.panel?.orderOut(nil); return true }
                // Let controls and their picker menus handle their own mouse events.
                if event.type != .keyDown, event.window === self.window { self.panel?.orderOut(nil) }
                return false
            }
            return consumed ? nil : event
        }
    }
    private func positionStatusPanel(force: Bool = false) {
        guard let panel, force || panel.isVisible, let host = panelHost,
              let button = status?.button, let anchorWindow = button.window else { return }
        host.layoutSubtreeIfNeeded()
        let fitting = host.fittingSize
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? anchorWindow.screen else { return }
        // Screen coordinates are in points with a bottom-left origin. Anchor to the
        // actual status-item window on its screen, never the management window.
        let visible = screen.visibleFrame
        let width: CGFloat = 350
        let height = min(max(fitting.height, 180), visible.height - 16)
        let x = max(visible.minX + 8, min(anchor.midX - width / 2, visible.maxX - width - 8))
        let top = min(anchor.minY - 6, visible.maxY - 6)
        let y = max(visible.minY + 8, top - height)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }
    private func synchronizeHotKey() {
        let desired = model.shortcutEnabled && !model.shortcutRecording ? model.shortcut : nil
        guard !hotKeyInitialized || desired != hotKeyConfiguration else { return }
        hotKeyInitialized = true; hotKeyConfiguration = desired
        do {
            try hotKey?.register(desired)
            model.shortcutStatus = desired == nil ? (model.shortcutRecording ? "Ожидание новой комбинации" : "Глобальная комбинация выключена") : "Комбинация активна во всех приложениях"
        } catch { model.shortcutStatus = error.localizedDescription }
    }
    private func rememberExternalApplication(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated, app.activationPolicy == .regular else { return }
        previousApplication = app
    }
    private func beginTyping(fromMenu: Bool) {
        guard inputTask == nil, !model.busy else { return }
        let target = fromMenu ? (menuTarget ?? TypingTarget.capture(fallback: previousApplication)) : TypingTarget.capture()
        panel?.orderOut(nil)
        inputTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await self.model.typeDefault(into: target)
            self.inputTask = nil
            if !success { self.showStatusPanel(captureTarget: false) }
        }
    }
    private func offerPermissionRestart() {
        guard model.permissionRestartSuggested, !restartAlertVisible, !restarting,
              !model.busy, NSApp.modalWindow == nil else { return }
        let parent: NSWindow?
        if panel?.isVisible == true { parent = panel }
        else if NSApp.isActive && window?.isVisible == true { parent = window }
        else { parent = nil }
        guard let parent, parent.attachedSheet == nil else { return }
        restartAlertVisible = true
        let alert = NSAlert()
        alert.messageText = "Перезапустить USBKey?"
        alert.informativeText = "После изменения разрешений macOS может потребоваться перезапуск. USBKey откроется заново; настройки и привязки флешек сохранятся."
        alert.addButton(withTitle: "Перезапустить")
        alert.addButton(withTitle: "Позже")
        alert.beginSheetModal(for: parent) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartAlertVisible = false
                self.model.dismissPermissionRestart()
                if response == .alertFirstButtonReturn { self.restartApplication() }
            }
        }
    }
    private func restartApplication() {
        guard !restarting else { return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/USBKeyLifecycle")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { model.error = "Не найден помощник перезапуска. Переустановите USBKey."; return }
        do {
            UserDefaults.standard.synchronize()
            try DetachedProcess.launch(executable: helper, arguments: ["--relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path, window?.isVisible == true ? "foreground" : "background"])
            restarting = true
            NSApp.terminate(nil)
        } catch { model.error = "Не удалось перезапустить USBKey: " + error.localizedDescription }
    }
    private func showStatusPanel(captureTarget: Bool) {
        guard let panel else { return }
        if captureTarget { menuTarget = TypingTarget.capture(fallback: previousApplication) }
        model.returnedFromKeyboardPermissions()
        model.refresh()
        positionStatusPanel(force: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.offerPermissionRestart() }
    }
    @objc func togglePopover() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) }
        else { showStatusPanel(captureTarget: true) }
    }
    func showMain() {
        panel?.orderOut(nil)
        NSApp.setActivationPolicy(.regular)
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "USBKey"; w.isReleasedWhenClosed = false; w.delegate = self
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.backgroundColor = NSColor(red: 16/255, green: 17/255, blue: 20/255, alpha: 1)
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            w.contentViewController = NSHostingController(rootView: MainView(model: model, restartApp: { [weak self] in self?.restartApplication() }))
            if let screen = NSScreen.main {
                w.setContentSize(NSSize(width: min(1160, screen.visibleFrame.width - 48), height: max(680, min(820, screen.visibleFrame.height - 64))))
            }
            w.center(); window = w
        }
        model.returnedFromKeyboardPermissions()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in self?.offerPermissionRestart() }
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && panel?.isVisible != true { showMain() }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); modelChanges?.cancel(); inputTask?.cancel(); hotKey?.stop(); server?.stop()
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localEventMonitor { NSEvent.removeMonitor(monitor) }
        panel?.orderOut(nil)
        if let status { NSStatusBar.system.removeStatusItem(status) }
    }
}
