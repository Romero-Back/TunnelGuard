import AppKit
import Combine
import SwiftUI

@main
struct TunnelGuardApp: App {
    var body: some Scene {
        Window("TunnelGuard", id: "main") {
            DesktopView()
        }
        .windowResizability(.contentSize)
    }
}

private struct DesktopView: View {
    @StateObject private var model = DesktopModel()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.05, green: 0.47, blue: 0.43)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            routePanel
            if let error = model.error { errorPanel(error) }
            actions
        }
        .padding(26)
        .frame(width: 468)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .onAppear(perform: model.refresh)
        .onReceive(timer) { _ in model.refresh() }
        .onChange(of: model.expectedIPv4) { _ in model.addressChanged() }
        .alert("Остановить Claude Desktop?", isPresented: $model.confirmStop) {
            Button("Остановить сеанс", role: .destructive, action: model.stop)
            Button("Продолжить работу", role: .cancel) {}
        } message: {
            Text("Окно Claude закроется.")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(LinearGradient(colors: [accent, Color(red: 0.10, green: 0.28, blue: 0.38)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("TunnelGuard").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Claude Desktop на Mac").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var routePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                if model.operation != nil {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                } else {
                    Image(systemName: model.session != nil ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(model.session != nil ? accent : .secondary)
                        .accessibilityHidden(true)
                }
                Text(model.status).font(.headline).accessibilityIdentifier("session-status")
                Spacer()
                Label("V2Pro", systemImage: "network")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
            Divider()
            HStack {
                Text("Ожидаемый IPv4")
                    .font(.subheadline)
                Spacer()
                TextField("IPv4 выхода VPN", text: $model.expectedIPv4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 173)
                    .disabled(model.hasSession || model.operation != nil)
                    .accessibilityLabel("Ожидаемый IPv4 выхода VPN")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: networkIcon).foregroundStyle(networkTint).accessibilityHidden(true)
                Text(networkText).foregroundStyle(.secondary)
                    .accessibilityIdentifier("network-status")
            }
            .font(.footnote)
        }
        .padding(16)
        .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(accent.opacity(0.15)))
    }

    private func errorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error, systemImage: "exclamationmark.circle").fixedSize(horizontal: false, vertical: true)
            Button("Показать журнал", action: model.revealLog).buttonStyle(.link)
        }
        .font(.footnote)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: model.hasSession ? model.openSession : model.start) {
                Label(model.hasSession ? "Открыть Claude" : "Запустить Claude",
                      systemImage: model.hasSession ? "arrow.up.right.square" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.operation != nil || (model.hasSession ? model.session == nil : !model.isReady))
            HStack {
                Button("Проверить сеть", action: model.checkNetwork)
                    .disabled(!model.isReady || model.networkState == .checking || (model.hasSession && model.session == nil))
                Spacer()
                if model.hasSession {
                    Button("Остановить сеанс") { model.confirmStop = true }
                        .disabled(model.operation != nil)
                }
            }
            .font(.subheadline)
        }
    }

    private var networkText: String {
        switch model.networkState {
        case .unchecked: "Сеть ещё не проверена"
        case .checking: "Проверяем HTTPS через V2Pro…"
        case .connected: "Проверка прошла. Соединение через V2Pro работает."
        case .blocked: "Связь не подтверждена. Проверь V2Pro и сетевой фильтр."
        }
    }

    private var networkIcon: String {
        switch model.networkState {
        case .unchecked: "network"
        case .checking: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle"
        }
    }

    private var networkTint: Color {
        switch model.networkState {
        case .connected: accent
        case .blocked: .orange
        default: .secondary
        }
    }
}
