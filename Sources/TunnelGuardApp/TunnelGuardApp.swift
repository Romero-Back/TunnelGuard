import AppKit
import Combine
import SwiftUI

@main
struct TunnelGuardApp: App {
    var body: some Scene {
        Window("TunnelGuard", id: "main") { DesktopView() }
            .windowResizability(.contentSize)
    }
}

private struct DesktopView: View {
    @StateObject private var model = DesktopModel()
    @Environment(\.colorScheme) private var colorScheme
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var accent: Color { model.accent.color }
    private var accentForeground: Color { colorScheme == .dark ? model.accent.darkForeground : accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sessionCard
            connectionCard
            if let error = model.error { errorCard(error) }
            actions
        }
        .padding(24)
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.appearance.colorScheme)
        .tint(.primary)
        .onAppear(perform: model.refresh)
        .onReceive(timer) { _ in model.refresh() }
        .sheet(isPresented: $model.showsSettings) {
            PreferencesView(model: model)
                .tint(accent)
                .preferredColorScheme(model.appearance.colorScheme)
        }
        .alert("Остановить Claude Desktop?", isPresented: $model.confirmStop) {
            Button("Остановить сеанс", role: .destructive, action: model.stop)
            Button("Продолжить работу", role: .cancel) {}
        } message: {
            Text("Окно Claude закроется.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(accentForeground)
                .frame(width: 34, height: 34)
                .background(accentForeground.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("TunnelGuard").font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { model.showsSettings = true } label: {
                Label("Настройки", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private var sessionCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.10))
                if model.operation != nil {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: sessionIcon)
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(Color(red: 0.68, green: 0.90, blue: 0.86))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text(model.status).font(.system(size: 26, weight: .semibold))
                    .accessibilityIdentifier("session-status")
                    .accessibilityAddTraits(.isHeader)
                Text(sessionDetail).font(.subheadline).foregroundStyle(.white.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(minHeight: 106, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16).fill(
                LinearGradient(colors: [Color(red: 0.09, green: 0.14, blue: 0.21),
                                        Color(red: 0.13, green: 0.24, blue: 0.30)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Подключение", systemImage: "network").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("V2Pro").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.primary.opacity(0.07), in: Capsule())
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: networkIcon).foregroundStyle(networkTint)
                    .frame(width: 18).accessibilityHidden(true)
                Text(networkText).fontWeight(.medium)
                    .accessibilityIdentifier("network-status")
                Spacer()
                if let checked = model.lastChecked {
                    Text(checked, style: .time).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("Время проверки")
                        .accessibilityValue(Text(checked, style: .time))
                }
            }
            HStack {
                Text("Разрешённый выход IPv4")
                Spacer()
                Text(addressSummary).monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if model.networkState != .blocked && model.hasLog {
                Button("Журнал", action: model.revealLog).buttonStyle(.link)
            }
        }
        .font(.footnote)
        .padding(12)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if model.hasSession {
                Button { model.confirmStop = true } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .disabled(model.operation != nil)
            }
            Spacer()
            Button(action: model.checkNetwork) { Label("Проверить сеть", systemImage: "arrow.clockwise") }
                .disabled(!model.canCheckNetwork)
            Button(action: primaryAction) {
                Label(primaryTitle, systemImage: primaryIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.operation != nil || (model.hasSession && model.session == nil))
        }
        .controlSize(.large)
    }

    private var sessionIcon: String {
        if !model.filterConfigured { return "shield" }
        return model.hasSession ? "lock.shield.fill" : "lock.shield"
    }

    private var sessionDetail: String {
        switch model.operation {
        case .opening: return "Claude откроется после проверки V2Pro и сетевого фильтра."
        case .checkingNetwork: return "Проверяем сетевой фильтр и разрешённый IPv4."
        case .settingUp: return "Подготавливаем сетевые правила для Claude."
        case .stopping: return "Завершаем защищённый сеанс Claude Desktop."
        case nil: break
        }
        if !model.filterConfigured { return "Настрой сетевой фильтр TunnelGuard для Claude Desktop." }
        if model.addresses.isEmpty { return "Добавь публичный IPv4 своего VPN в настройках." }
        if model.hasSession { return "TunnelGuard проверит сеть при открытии окна Claude." }
        return "TunnelGuard проверит сеть перед запуском Claude Desktop."
    }

    private var primaryTitle: String {
        if model.operation == .opening { return "Проверяем сеть…" }
        if !model.filterConfigured { return "Настроить защиту" }
        if model.addresses.isEmpty { return "Добавить IPv4" }
        return model.hasSession ? "Открыть Claude" : "Запустить Claude"
    }

    private var primaryIcon: String {
        if model.operation == .opening { return "hourglass" }
        if !model.filterConfigured { return "lock.shield" }
        if model.addresses.isEmpty { return "plus" }
        return model.hasSession ? "arrow.up.right.square" : "play.fill"
    }

    private func primaryAction() {
        if !model.filterConfigured { model.installFilter() }
        else if model.addresses.isEmpty { model.showsSettings = true }
        else { model.openClaude() }
    }

    private var addressSummary: String {
        if model.addresses.isEmpty { return "Адрес не задан" }
        if model.effectiveAddresses.count == 1 { return model.effectiveAddresses[0] }
        return "Авто · \(model.effectiveAddresses.count)"
    }

    private var networkText: String {
        switch model.networkState {
        case .unchecked: "Ожидает проверки"
        case .checking: "Проверка V2Pro и фильтра…"
        case let .connected(address): "Подтверждён IPv4 \(address)"
        case .blocked: "Сеть не подтверждена"
        }
    }

    private var networkIcon: String {
        switch model.networkState {
        case .unchecked: "circle.dotted"
        case .checking: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        }
    }

    private var networkTint: Color {
        switch model.networkState {
        case .connected: accentForeground
        case .blocked: .orange
        default: .secondary
        }
    }
}

private struct PreferencesView: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Настройки").font(.title2.bold())
                Spacer()
                Button("Готово") { model.showsSettings = false }.keyboardShortcut(.cancelAction)
            }

            TabView {
                vpnTab.disabled(model.operation != nil)
                    .tabItem { Label("VPN", systemImage: "network") }
                appearanceTab.tabItem { Label("Оформление", systemImage: "paintbrush") }
            }
            .frame(height: 322)
        }
        .padding(22)
        .frame(width: 508)
    }

    private var vpnTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Разрешённые адреса выхода").font(.headline)
            Text("IPv4 сохраняются на этом Mac.").foregroundStyle(.secondary)
            HStack {
                TextField("Публичный IPv4", text: $model.addressDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.addAddress)
                Button("Добавить", action: model.addAddress)
                    .disabled(model.addressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.addressError { Text(error).foregroundStyle(.red) }
            if !model.addresses.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.addresses, id: \.self) { address in
                            HStack {
                                Text(address).monospacedDigit()
                                Spacer()
                                Button { model.removeAddress(address) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Убрать \(address)")
                            }
                            .padding(.vertical, 5).padding(.horizontal, 8)
                        }
                    }
                }
                .frame(maxHeight: 122)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            Picker("Режим проверки", selection: $model.selectedAddress) {
                Text("Авто · любой из списка").tag(String?.none)
                ForEach(model.addresses, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .disabled(model.addresses.isEmpty)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Тема TunnelGuard").font(.headline)
            Picker("Тема", selection: $model.appearance) {
                ForEach(DesktopModel.Appearance.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider().padding(.vertical, 6)
            Text("Акцентный цвет").font(.headline)
            HStack(spacing: 10) {
                ForEach(DesktopModel.Accent.allCases) { accent in
                    Button { model.accent = accent } label: {
                        VStack(spacing: 8) {
                            Circle().fill(accent.color).frame(width: 28, height: 28)
                                .overlay {
                                    if model.accent == accent {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                            Text(accent.name).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(accent.color.opacity(model.accent == accent ? 0.14 : 0.05),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(accent.color.opacity(model.accent == accent ? 0.55 : 0.16)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.accent == accent ? .isSelected : [])
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }
}
