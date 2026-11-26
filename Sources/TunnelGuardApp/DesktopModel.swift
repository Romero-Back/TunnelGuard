import AppKit
import Foundation
import Network
import SwiftUI

@MainActor
final class DesktopModel: ObservableObject {
    enum Operation { case settingUp, starting, stopping }
    enum NetworkState: Equatable { case unchecked, checking, connected(String), blocked }

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

    private let runtime = DesktopRuntime()
    private let defaults: UserDefaults
    private var refreshing = false
    @Published private(set) var addresses: [String]
    @Published var selectedAddress: String? { didSet { saveAddresses() } }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var showsSettings = false
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let oldAddress = defaults.string(forKey: "expectedIPv4").flatMap(Self.publicIPv4)
        let stored = defaults.stringArray(forKey: "allowedIPv4") ?? oldAddress.map { [$0] } ?? []
        let allowed = stored.compactMap(Self.publicIPv4)
        addresses = allowed
        selectedAddress = defaults.string(forKey: "selectedIPv4").flatMap { allowed.contains($0) ? $0 : nil }
        appearance = defaults.string(forKey: "appearance").flatMap(Appearance.init(rawValue:)) ?? .system
        filterConfigured = runtime.filterConfigured
        saveAddresses()
    }

    var hasSession: Bool { activePID != nil }
    var isReady: Bool { operation == nil && !effectiveAddresses.isEmpty }
    var effectiveAddresses: [String] {
        if let selectedAddress, addresses.contains(selectedAddress) { return [selectedAddress] }
        return addresses
    }

    var status: String {
        switch operation {
        case .settingUp: return "Настройка защиты"
        case .starting: return "Claude запускается"
        case .stopping: return "Сеанс закрывается"
        case nil:
            if session != nil { return "Claude запущен" }
            return hasSession ? "Сеанс загружается" : "Claude остановлен"
        }
    }

    func addAddress() {
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

    func start() {
        guard isReady, !hasSession else { return }
        let addresses = effectiveAddresses
        let runtime = self.runtime
        operation = .starting
        error = nil
        networkState = .unchecked
        Task {
            do {
                let running = try await Task.detached { try runtime.start(expectedIPv4: addresses) }.value
                session = running
                activePID = running.pid
                operation = nil
                checkNetwork()
            } catch {
                self.error = error.localizedDescription
                operation = nil
                refresh()
            }
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
        guard isReady, networkState != .checking else { return }
        let runtime = self.runtime
        let addresses = effectiveAddresses
        let currentSession = session
        networkState = .checking
        Task {
            let result = await Task.detached { runtime.check(expectedIPv4: addresses) }.value
            guard operation == nil, currentSession == session, addresses == effectiveAddresses else {
                if networkState == .checking { networkState = .unchecked }
                return
            }
            networkState = result.map(NetworkState.connected) ?? .blocked
            lastChecked = Date()
        }
    }

    func installFilter() {
        guard operation == nil else { return }
        operation = .settingUp
        error = nil
        let runtime = self.runtime
        Task {
            do {
                try await Task.detached { try runtime.installFilter() }.value
                filterConfigured = runtime.filterConfigured
            } catch {
                self.error = "Настройка защиты не завершилась. Можно повторить её из настроек."
            }
            operation = nil
            if error == nil { checkNetwork() }
        }
    }

    func openSession() {
        guard let session else { return }
        _ = NSRunningApplication(processIdentifier: session.appPid)?.activate()
    }

    func revealLog() {
        guard FileManager.default.fileExists(atPath: runtime.logFile.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([runtime.logFile])
    }
}
