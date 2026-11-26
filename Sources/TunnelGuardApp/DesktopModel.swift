import AppKit
import Foundation
import Network
import SwiftUI

@MainActor
final class DesktopModel: ObservableObject {
    enum Operation { case starting, stopping }
    enum NetworkState: Equatable { case unchecked, checking, connected, blocked }

    private let runtime = DesktopRuntime()
    private var refreshing = false
    @Published var expectedIPv4: String = UserDefaults.standard.string(forKey: "expectedIPv4") ?? ""
    @Published var confirmStop = false
    @Published private(set) var session: DesktopSession?
    @Published private(set) var activePID: Int?
    @Published private(set) var operation: Operation?
    @Published private(set) var networkState: NetworkState = .unchecked
    @Published private(set) var error: String?

    var hasSession: Bool { activePID != nil }
    var isReady: Bool { operation == nil && IPv4Address(ipv4) != nil }
    var ipv4: String { expectedIPv4.trimmingCharacters(in: .whitespacesAndNewlines) }

    var status: String {
        switch operation {
        case .starting: return "Claude запускается"
        case .stopping: return "Сеанс закрывается"
        case nil:
            if session != nil { return "Claude запущен" }
            return hasSession ? "Сеанс загружается" : "Claude остановлен"
        }
    }

    func refresh() {
        guard operation == nil, !refreshing else { return }
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
                if session != nil { checkNetwork() }
            }
        }
    }

    func start() {
        guard isReady, !hasSession else { return }
        let address = ipv4
        expectedIPv4 = address
        UserDefaults.standard.set(address, forKey: "expectedIPv4")
        let runtime = self.runtime
        operation = .starting
        error = nil
        networkState = .unchecked
        Task {
            do {
                let running = try await Task.detached { try runtime.start(expectedIPv4: address) }.value
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
        let address = ipv4
        let currentSession = session
        networkState = .checking
        Task {
            let result = await Task.detached { runtime.check(expectedIPv4: address) }.value
            guard operation == nil, currentSession == session, address == ipv4 else {
                if networkState == .checking { networkState = .unchecked }
                return
            }
            networkState = result ? .connected : .blocked
        }
    }

    func addressChanged() {
        if !hasSession && networkState != .checking { networkState = .unchecked }
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
