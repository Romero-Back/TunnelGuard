import SwiftUI

@main
struct TunnelGuardApp: App {
    @NSApplicationDelegateAdaptor(TunnelGuardMenu.self) private var menu
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("TunnelGuard", id: "main") {
            MainWindow(model: menu.model)
                .onAppear {
                    let open = openWindow
                    menu.revealWindow = { open(id: "main") }
                }
        }
        .defaultSize(width: 1110, height: 770)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("О нас", action: menu.showAbout)
                Button("Проверить обновления…", action: menu.checkForUpdates)
            }
            CommandMenu("Интерфейс") {
                ForEach(DesktopModel.InterfaceMode.allCases) { mode in
                    Button("\(mode.title) режим") { menu.useMode(mode) }
                }
            }
        }
    }
}

private struct MainWindow: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        Group {
            switch model.interfaceMode {
            case .simple:
                SimpleLauncher(model: model)
                    .frame(width: 400, height: 238)
            case .expert:
                Dashboard(model: model)
                    .frame(minWidth: 680, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
    }
}

private struct SimpleLauncher: View {
    @ObservedObject var model: DesktopModel

    private var hint: String {
        if let error = model.error { return error }
        if model.desktopGateState != .installed {
            return "Ограничение прямого запуска не подтверждено. Открой «Настройки → Claude Desktop» в экспертном режиме."
        }
        if model.observation == nil { return "Проверяем состояние защиты…" }
        if model.addresses.isEmpty || !model.filterConfigured {
            return "Для первого запуска настрой защиту в экспертном режиме."
        }
        if model.paused { return "Доступ приостановлен. Его можно восстановить через значок в строке меню." }
        if model.observation?.routeIPv4 != true { return "Подключи выбранный VPN и дождись подтверждения маршрута." }
        if model.filterStalled || model.observation?.filter != .healthy {
            return "Состояние фильтра PF не подтверждено. Открой экспертный режим для диагностики."
        }
        if model.operation == .opening || model.operation == .checkingNetwork { return "Проверяем сеть…" }
        return "TunnelGuard проверит сеть перед открытием Claude."
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .overlay {
                    VerificationPulse(
                        checkedAt: model.desktopGateState == .installed && !model.paused ? model.lastVerifiedAt : nil,
                        tint: model.accent.color
                    )
                        .frame(width: 70, height: 70)
                }
                .accessibilityHidden(true)
            Text("Claude Desktop").font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Button(model.hasSession ? "Открыть Claude" : "Запустить Claude", action: model.openClaude)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .tint(model.accent.color)
                .disabled(!model.canOpenDesktop)
            Text(hint)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
