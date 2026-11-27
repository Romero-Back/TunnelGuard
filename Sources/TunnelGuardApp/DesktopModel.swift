import AppKit
import Foundation
import Network
import SwiftUI

@MainActor
final class DesktopModel: ObservableObject {
    enum Operation { case settingUp, opening, checkingNetwork, stopping }
    enum NetworkState: Equatable { case unchecked, checking, connected(String), blocked }

    enum InterfaceMode: String, CaseIterable, Identifiable {
        case simple, expert

        var id: Self { self }
        var title: String { self == .simple ? "Простой" : "Экспертный" }
    }

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark

        var id: Self { self }
        var name: String {
            switch self {
            case .system: "Системная"
            case .light: "Светлая"
            case .dark: "Тёмная"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Accent: String, CaseIterable, Identifiable {
        case mint, blue, violet

        var id: Self { self }
        var name: String {
            switch self {
            case .mint: "Мятный"
            case .blue: "Синий"
            case .violet: "Сиреневый"
            }
        }

        var color: Color {
            switch self {
            case .mint: Color(red: 0.05, green: 0.48, blue: 0.42)
            case .blue: Color(red: 0.16, green: 0.44, blue: 0.82)
            case .violet: Color(red: 0.45, green: 0.32, blue: 0.72)
            }
        }

        var darkForeground: Color {
            switch self {
            case .mint: Color(red: 0.43, green: 0.84, blue: 0.76)
            case .blue: Color(red: 0.56, green: 0.73, blue: 1.00)
            case .violet: Color(red: 0.76, green: 0.65, blue: 0.97)
            }
        }
    }

    private let runtime = DesktopRuntime()
    private let defaults: UserDefaults
    private var refreshing = false
    @Published private(set) var addresses: [String]
    @Published var selectedAddress: String? { didSet { saveAddresses() } }
    @Published var interfaceMode: InterfaceMode {
        didSet { defaults.set(interfaceMode.rawValue, forKey: "interfaceMode") }
    }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var accent: Accent { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    @Published var section: Section? = .overview
    @Published var routeStep: RouteStep = .vpn
    @Published var addressDraft = ""
    @Published private(set) var addressError: String?
    @Published var confirmStop = false
    @Published private(set) var session: DesktopSession?
    @Published private(set) var activePID: Int?
    @Published private(set) var operation: Operation?
    @Published private(set) var networkState: NetworkState = .unchecked
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: String?
    @Published private(set) var filterConfigured = false
    @Published private(set) var desktopGateState: DesktopGateState = .off

    @Published private(set) var observation: NetworkObservation?
    @Published var vpnDraft: String?
    @Published private(set) var observedAt: Date?
    @Published private(set) var filterStalled = false
    private var lastHelperProgress: Date?
    @Published private(set) var events: [GuardEvent] = []
    @Published private(set) var diagnosticResult: String?
    @Published private(set) var diagnosticRunning = false
    @Published private(set) var emergencyAction = false
    @Published private(set) var hotkeyAvailable = false
    private var heartbeat: Task<Void, Never>?
    private var observationRevision = 0
    private var hotkey: EmergencyShortcut?

    var paused: Bool { emergencyAction || observation?.paused != false }

    func beginMonitoring() {
        guard heartbeat == nil else { return }
        hotkey = EmergencyShortcut { [weak self] in self?.pause() }
        hotkeyAvailable = hotkey != nil
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                await self?.observeNetwork()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    private func observeNetwork() async {
        observationRevision += 1
        let revision = observationRevision
        let runtime = self.runtime
        let current = await Task.detached { runtime.observe() }.value
        guard revision == observationRevision else { return }
        let previous = observation
        if previous != current { observation = current }
        let now = Date()
        observedAt = now
        if current.filterRuns != previous?.filterRuns { lastHelperProgress = now }
        let stalled = current.filterRuns != nil && lastHelperProgress.map { now.timeIntervalSince($0) > 35 } == true
        if stalled && !filterStalled { record("Служба PF перестала обновлять правила", warning: true) }
        filterStalled = stalled
        if let previous, previous.vpnName != current.vpnName ||
            previous.interface != current.interface || previous.routeIPv4 != current.routeIPv4 {
            record(current.routeIPv4 == true ? "Маршрут VPN восстановлен" : "Маршрут VPN потерян",
                   warning: current.routeIPv4 != true)
            if operation == nil { networkState = .unchecked; lastChecked = nil }
        }
        if previous?.filter != current.filter && current.filter != .healthy {
            record("Служба PF не подтвердила исправность", warning: true)
        }
        if hasSession && operation == nil &&
            (current.filter != .healthy || filterStalled || current.routeIPv4 != true || current.paused != false) {
            record("Watchdog завершает сеанс Claude Desktop", warning: true)
            stop()
        } else {
            refresh()
        }
    }

    func diagnose(_ diagnostic: Diagnostic) {
        guard !paused, !diagnosticRunning, !effectiveAddresses.isEmpty else { return }
        diagnosticRunning = true
        diagnosticResult = nil
        let runtime = self.runtime
        let addresses = effectiveAddresses
        Task {
            let result = await Task.detached { try? runtime.diagnose(diagnostic, addresses: addresses) }.value
            diagnosticResult = result ?? "Проверка не пройдена. Проверь выбранный VPN, разрешённые IPv4 и службу PF."
            record(result == nil ? "Диагностика не пройдена" : "Диагностика завершена", warning: result == nil)
            diagnosticRunning = false
        }
    }

    func launchCode() {
        guard operation == nil, !paused, !effectiveAddresses.isEmpty, observation?.codeActive != true else { return }
        do {
            let file = try runtime.terminalCommand()
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                throw DesktopError.commandFailed
            }
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: .init()) { [weak self] _, error in
                Task { @MainActor in
                    if error == nil {
                        self?.record("Запрошен защищённый запуск Claude Code")
                    } else {
                        self?.error = "Не удалось открыть Terminal для Claude Code."
                    }
                }
            }
        } catch {
            self.error = "Не удалось подготовить запуск Claude Code."
        }
    }

    func pause() { changeEmergencyState(true) }
    func resume() { changeEmergencyState(false) }

    private func changeEmergencyState(_ paused: Bool) {
        guard !emergencyAction else { return }
        emergencyAction = true
        let runtime = self.runtime
        Task {
            let succeeded = await Task.detached { (try? runtime.setPaused(paused)) != nil }.value
            record(succeeded ? (paused ? "Аварийная остановка" : "Новые запуски разрешены") :
                "Аварийное действие не подтверждено", warning: paused || !succeeded)
            if !succeeded { error = "Проверь состояние защиты. Аварийное действие выполнено не полностью." }
            await observeNetwork()
            emergencyAction = false
        }
    }

    private func record(_ title: String, warning: Bool = false) {
        events.insert(GuardEvent(title: title, warning: warning), at: 0)
        events = Array(events.prefix(100))
        defaults.set(try? JSONEncoder().encode(events), forKey: "guardEvents")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let oldAddress = defaults.string(forKey: "expectedIPv4").flatMap(Self.publicIPv4)
        let stored = defaults.stringArray(forKey: "allowedIPv4") ?? oldAddress.map { [$0] } ?? []
        let allowed = stored.compactMap(Self.publicIPv4)
        addresses = allowed
        selectedAddress = defaults.string(forKey: "selectedIPv4").flatMap { allowed.contains($0) ? $0 : nil }
        interfaceMode = defaults.string(forKey: "interfaceMode").flatMap(InterfaceMode.init(rawValue:)) ?? .expert
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        accent = defaults.string(forKey: "accent").flatMap(Accent.init(rawValue:)) ?? .mint
        if let data = defaults.data(forKey: "guardEvents") {
            events = (try? JSONDecoder().decode([GuardEvent].self, from: data)) ?? []
        }
        filterConfigured = runtime.filterConfigured
        desktopGateState = runtime.desktopGateState
        saveAddresses()
    }

    var lastVerifiedAt: Date? {
        guard case .connected = networkState else { return nil }
        return lastChecked
    }

    var hasSession: Bool { activePID != nil }
    var canCheckNetwork: Bool { !paused && operation == nil && filterConfigured && !effectiveAddresses.isEmpty }
    var canOpenDesktop: Bool {
        desktopGateState == .installed && canCheckNetwork && !filterStalled && observation?.filter == .healthy && observation?.routeIPv4 == true &&
            (!hasSession || session != nil)
    }
    var effectiveAddresses: [String] {
        if let selectedAddress, addresses.contains(selectedAddress) { return [selectedAddress] }
        return addresses
    }

    var status: String {
        switch operation {
        case .settingUp: return "Настройка защиты"
        case .opening, .checkingNetwork: return "Проверяем сеть"
        case .stopping: return "Сеанс закрывается"
        case nil:
            if session != nil { return "Claude запущен" }
            return hasSession ? "Сеанс загружается" : "Claude остановлен"
        }
    }

    func addAddress() {
        guard operation == nil else { return }
        guard let address = Self.publicIPv4(addressDraft) else {
            addressError = "Введи публичный IPv4."
            return
        }
        guard !addresses.contains(address) else {
            addressError = "Этот адрес уже в списке."
            return
        }
        addresses.append(address)
        addressDraft = ""
        addressError = nil
        saveAddresses()
    }

    func removeAddress(_ address: String) {
        guard operation == nil else { return }
        addresses.removeAll { $0 == address }
        if selectedAddress == address { selectedAddress = nil }
        saveAddresses()
    }

    private func saveAddresses() {
        defaults.set(addresses, forKey: "allowedIPv4")
        defaults.set(selectedAddress, forKey: "selectedIPv4")
        defaults.removeObject(forKey: "expectedIPv4")
        networkState = .unchecked
        lastChecked = nil
        error = nil
    }

    private static func publicIPv4(_ input: String) -> String? {
        guard let address = IPv4Address(input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let bytes = Array(address.rawValue)
        let a = bytes[0], b = bytes[1], c = bytes[2]
        guard ![0, 10, 127].contains(a), a < 224,
              !(a == 100 && (64...127).contains(b)), !(a == 169 && b == 254),
              !(a == 172 && (16...31).contains(b)), !(a == 192 && b == 168),
              !(a == 192 && b == 0 && c == 0 && ![9, 10].contains(bytes[3])),
              !(a == 192 && b == 0 && c == 2),
              !(a == 198 && (18...19).contains(b)), !(a == 198 && b == 51 && c == 100),
              !(a == 203 && b == 0 && c == 113) else { return nil }
        return bytes.map(String.init).joined(separator: ".")
    }

    func refresh() {
        guard operation == nil, !refreshing else { return }
        if filterConfigured != runtime.filterConfigured { filterConfigured = runtime.filterConfigured }
        let gate = runtime.desktopGateState
        if desktopGateState != gate { desktopGateState = gate }
        refreshing = true
        let runtime = self.runtime
        Task {
            let snapshot = await Task.detached { try? runtime.snapshot() }.value
            refreshing = false
            guard operation == nil, let snapshot else { return }
            let sessionChanged = session != snapshot.session
            if sessionChanged { session = snapshot.session }
            if activePID != snapshot.pid { activePID = snapshot.pid }
            if sessionChanged {
                networkState = .unchecked
                lastChecked = nil
                if session != nil { checkNetwork() }
            }
        }
    }

    func openClaude() {
        guard canOpenDesktop else { return }
        let addresses = effectiveAddresses
        let runtime = self.runtime
        let currentSession = session
        beginNetworkCheck(.opening)
        Task {
            do {
                if let currentSession {
                    let result = try await Task.detached {
                        let address = try runtime.check(expectedIPv4: addresses, requireGate: true)
                        return (address: address, sessionMatches: try runtime.snapshot().session == currentSession)
                    }.value
                    finishNetworkCheck(address: result.address)
                    if paused || !result.sessionMatches || !activate(currentSession) {
                        error = DesktopError.openFailed.localizedDescription
                    }
                } else {
                    let running = try await Task.detached { try runtime.start(expectedIPv4: addresses) }.value
                    session = running.session
                    activePID = running.session.pid
                    finishNetworkCheck(address: running.address)
                }
            } catch {
                failNetworkCheck(error)
            }
            operation = nil
            refresh()
        }
    }

    func stop() {
        guard hasSession, operation == nil else { return }
        operation = .stopping
        error = nil
        let runtime = self.runtime
        Task {
            do {
                try await Task.detached { try runtime.stop() }.value
                session = nil
                activePID = nil
                networkState = .unchecked
                lastChecked = nil
            } catch {
                self.error = error.localizedDescription
            }
            operation = nil
            refresh()
        }
    }

    func checkNetwork() {
        guard canCheckNetwork else { return }
        let runtime = self.runtime
        let addresses = effectiveAddresses
        beginNetworkCheck(.checkingNetwork)
        Task {
            do {
                let address = try await Task.detached { try runtime.check(expectedIPv4: addresses) }.value
                finishNetworkCheck(address: address)
            } catch {
                failNetworkCheck(error)
            }
            operation = nil
        }
    }

    private func beginNetworkCheck(_ operation: Operation) {
        self.operation = operation
        networkState = .checking
        lastChecked = nil
        error = nil
    }

    private func finishNetworkCheck(address: String) {
        networkState = .connected(address)
        lastChecked = Date()
        record("Сетевой фильтр и IPv4 подтверждены")
    }

    private func failNetworkCheck(_ error: Error) {
        if case DesktopError.networkBlocked = error {
            networkState = .blocked
            lastChecked = Date()
        } else {
            networkState = .unchecked
        }
        self.error = error.localizedDescription
        record("Проверка или запуск не завершились", warning: true)
    }

    func configureDesktopGate() {
        guard !hasSession, operation == nil else { return }
        let enabled = desktopGateState == .off
        guard !enabled || canCheckNetwork else { return }
        let addresses = effectiveAddresses
        let runtime = self.runtime
        operation = .settingUp
        error = nil
        Task {
            do {
                let verified = try await Task.detached {
                    if enabled { _ = try runtime.check(expectedIPv4: addresses) }
                    try runtime.configureDesktopGate(enabled)
                    return enabled ? try runtime.check(expectedIPv4: addresses, requireGate: true) : nil
                }.value
                if let verified {
                    finishNetworkCheck(address: verified)
                    record("Запуск Claude ограничен TunnelGuard")
                } else {
                    networkState = .unchecked
                    lastChecked = nil
                    record("Обычный запуск Claude восстановлен")
                }
            } catch {
                networkState = .unchecked
                lastChecked = nil
                self.error = "Не удалось подтвердить ограничение запуска. Проверь, закрыт ли Claude, и повтори настройку."
            }
            desktopGateState = runtime.desktopGateState
            operation = nil
            refresh()
        }
    }

    func installFilter() {
        applyVPN(nil)
    }

    func applyVPN(_ profile: String?) {
        guard operation == nil, !hasSession, observation?.codeActive != true else { return }
        operation = .settingUp
        networkState = .unchecked
        lastChecked = nil
        diagnosticResult = nil
        error = nil
        let runtime = self.runtime
        Task {
            do {
                try await Task.detached { try runtime.installFilter(vpnName: profile) }.value
                filterConfigured = runtime.filterConfigured
                await observeNetwork()
                if vpnDraft == observation?.vpnName { vpnDraft = nil }
            } catch {
                self.error = "Настройка защиты не завершилась. Закрой Claude Desktop и Claude Code и попробуй ещё раз."
            }
            operation = nil
            if error == nil { checkNetwork() }
        }
    }

    private func activate(_ session: DesktopSession) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: session.appPid) else { return false }
        return application.isActive || application.activate()
    }

}
