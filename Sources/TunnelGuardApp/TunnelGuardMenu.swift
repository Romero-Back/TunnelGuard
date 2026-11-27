import AppKit
import Combine
import Sparkle

@MainActor
final class TunnelGuardMenu: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = DesktopModel()
    var revealWindow: (() -> Void)?

    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?
    private var updater: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "TunnelGuardStatusItem"
        item.isVisible = true
        item.button?.toolTip = "TunnelGuard"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        observation = model.$observation.combineLatest(model.$filterStalled, model.$desktopGateState)
            .sink { [weak self] state, stalled, gate in self?.updateIcon(state, stalled: stalled, gate: gate) }
        model.beginMonitoring()
        if Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil {
            updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func updateIcon(_ state: NetworkObservation?, stalled: Bool, gate: DesktopGateState) {
        let ready = gate == .installed && state?.paused == false && state?.routeIPv4 == true && state?.filter == .healthy && !stalled
        let icon = ready ? "lock.shield" : "shield.slash"
        statusItem?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: "TunnelGuard")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        if model.observation == nil { status = "Проверяем состояние защиты…" }
        else if model.observation?.paused == true { status = "Доступ приостановлен" }
        else if model.desktopGateState != .installed { status = "Запуск Claude требует настройки" }
        else if model.filterStalled || model.observation?.filter != .healthy { status = "Состояние PF требует внимания" }
        else if model.observation?.routeIPv4 == true { status = "Маршрут VPN обнаружен" }
        else { status = "Маршрут VPN не подтверждён" }
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
        add("Проверить обновления…", to: menu, action: #selector(checkForUpdates),
            enabled: updater?.updater.canCheckForUpdates == true)
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

    @objc func checkForUpdates() {
        guard let updater else { return }
        activateApplication()
        updater.checkForUpdates(nil)
    }

    @objc private func useSimple() { useMode(.simple) }
    @objc private func useExpert() { useMode(.expert) }
    @objc private func openClaude() { model.openClaude() }
    @objc private func check() { model.checkNetwork() }
    @objc private func pause() { model.pause() }
    @objc private func resume() { model.resume() }
    @objc private func quit() { NSApp.terminate(nil) }
}
