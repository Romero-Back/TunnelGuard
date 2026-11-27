import AppKit
import Combine

@MainActor
final class TunnelGuardMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = DesktopModel()
    var revealWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?
    private var updateCheck: Task<Void, Never>?
    private var availableUpdate: ReleaseUpdates.Update?
    private let lastCheckKey = "lastAutomaticUpdateCheck"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "TunnelGuardStatusItem"
        item.isVisible = true
        item.button?.toolTip = "TunnelGuard"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        observation = model.$observation.combineLatest(model.$filterStalled).sink { [weak self] state, stalled in
            self?.updateIcon(state, stalled: stalled)
        }
        model.beginMonitoring()
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(lastCheck) > 24 * 60 * 60 {
            checkUpdates(interactive: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateIcon(_ state: NetworkObservation?, stalled: Bool) {
        let ready = state?.paused == false && state?.routeIPv4 == true && state?.filter == .healthy && !stalled
        let icon = ready ? "lock.shield" : "shield.slash"
        statusItem?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "TunnelGuard")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if model.observation == nil { status = "Проверяем состояние защиты…" }
        else if model.observation?.paused == true { status = "Доступ приостановлен" }
        else if model.filterStalled || model.observation?.filter != .healthy { status = "Состояние PF требует внимания" }
        else if model.observation?.routeIPv4 == true { status = "Маршрут V2Pro обнаружен" }
        else { status = "Маршрут V2Pro не подтверждён" }
        add(status, to: menu, enabled: false)
        menu.addItem(.separator())
        add(model.hasSession ? "Открыть Claude" : "Запустить Claude", to: menu,
            action: #selector(openClaude), enabled: model.canOpenDesktop)
        add("Открыть TunnelGuard", to: menu, action: #selector(showWindow))
        let modes = add("Интерфейс", to: menu)
        let submenu = NSMenu()
        add("Простой", to: submenu, action: #selector(useSimple)).state = model.interfaceMode == .simple ? .on : .off
        add("Экспертный", to: submenu, action: #selector(useExpert)).state = model.interfaceMode == .expert ? .on : .off
        modes.submenu = submenu
        menu.addItem(.separator())
        add("Проверить сеть", to: menu, action: #selector(check), enabled: model.canCheckNetwork)
        add("Аварийная остановка", to: menu, action: #selector(pause), enabled: !model.emergencyAction)
        if model.observation?.paused == true {
            add("Разрешить новые запуски", to: menu, action: #selector(resume), enabled: !model.emergencyAction)
        }
        menu.addItem(.separator())
        if let availableUpdate {
            add("Скачать TunnelGuard \(availableUpdate.version)…", to: menu, action: #selector(openUpdatePage))
        }
        add("Проверить обновления…", to: menu, action: #selector(checkForUpdates), enabled: updateCheck == nil)
        add("О нас", to: menu, action: #selector(showAbout))
        add("Выход из TunnelGuard", to: menu, action: #selector(quit))
    }

    func useMode(_ mode: DesktopModel.InterfaceMode) {
        model.interfaceMode = mode
        showWindow()
    }

    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
        menu.autoenablesItems = false
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    @objc private func showWindow() {
        activateApplication()
        revealWindow?()
    }

    @objc func showAbout() {
        let credits = NSAttributedString(string: "Сделано энтузиастами для бесплатного использования.")
        activateApplication()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func activateApplication() {
        if #available(macOS 14, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    @objc func checkForUpdates() { checkUpdates(interactive: true) }

    private func checkUpdates(interactive: Bool) {
        guard updateCheck == nil else {
            if interactive { showUpdateAlert("Проверяем обновления", detail: "Проверка уже выполняется.") }
            return
        }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        updateCheck = Task {
            defer { updateCheck = nil }
            do {
                availableUpdate = try await ReleaseUpdates.check(currentVersion: current)
                UserDefaults.standard.set(Date(), forKey: lastCheckKey)
                guard interactive else { return }
                if let availableUpdate {
                    showUpdateAlert("Доступна версия \(availableUpdate.version)",
                                    detail: "Открой релиз на GitHub, скачай DMG и замени приложение в папке «Программы».",
                                    download: true)
                } else {
                    showUpdateAlert("Установлена актуальная версия", detail: "TunnelGuard \(current)")
                }
            } catch {
                if interactive {
                    showUpdateAlert("Не удалось проверить обновления", detail: "Проверь доступ к GitHub и попробуй ещё раз.")
                }
            }
        }
    }

    @objc private func openUpdatePage() {
        guard let availableUpdate else { return }
        NSWorkspace.shared.open(availableUpdate.page)
    }

    private func showUpdateAlert(_ title: String, detail: String, download: Bool = false) {
        activateApplication()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: download ? "Открыть на GitHub" : "OK")
        if download { alert.addButton(withTitle: "Позже") }
        if alert.runModal() == .alertFirstButtonReturn && download { openUpdatePage() }
    }

    @objc private func useSimple() { useMode(.simple) }
    @objc private func useExpert() { useMode(.expert) }
    @objc private func openClaude() { model.openClaude() }
    @objc private func check() { model.checkNetwork() }
    @objc private func pause() { model.pause() }
    @objc private func resume() { model.resume() }
    @objc private func quit() { NSApp.terminate(nil) }
}
