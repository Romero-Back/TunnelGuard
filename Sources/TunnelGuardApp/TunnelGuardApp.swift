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
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var accent: Color { model.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TunnelGuard").font(.system(size: 25, weight: .bold))
                    Text("Сетевая защита Claude Desktop").foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showsSettings = true } label: {
                    Label("Настройки", systemImage: "gearshape")
                }
                .keyboardShortcut(",", modifiers: .command)
                .controlSize(.large)
            }

            statusCard
            connectionCard
            if !model.filterConfigured { setupCard }
            if let error = model.error { errorCard(error) }
            actions
        }
        .padding(26)
        .frame(width: 612)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(model.appearance.colorScheme)
        .tint(accent)
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

    private var statusCard: some View {
        HStack(spacing: 18) {
            Image(systemName: model.session == nil ? "shield" : "checkmark.shield.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color(red: 0.53, green: 0.95, blue: 0.82))
                .frame(width: 64, height: 64)
                .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Сеанс Claude").font(.subheadline).foregroundStyle(.white.opacity(0.75))
                Text(model.status).font(.system(size: 25, weight: .semibold))
                    .accessibilityIdentifier("session-status")
            }
            Spacer(minLength: 0)
            if model.operation != nil {
                ProgressView().controlSize(.small).colorScheme(.dark)
            } else {
                Label("V2Pro", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .foregroundStyle(.white)
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 20).fill(
                LinearGradient(colors: [Color(red: 0.05, green: 0.16, blue: 0.20),
                                        Color(red: 0.08, green: 0.32, blue: 0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: networkIcon).foregroundStyle(networkTint)
                    .frame(width: 22).accessibilityHidden(true)
                Text(networkText).font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("network-status")
                Spacer()
                if let checked = model.lastChecked { Text(checked, style: .time).monospacedDigit() }
            }
            Divider()
            LabeledContent("Правило проверки IPv4") {
                Text(addressSummary).monospacedDigit()
            }
        }
        .font(.subheadline)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }

    private var setupCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(accent)
            Text("Подготовь системный фильтр для запуска Claude.")
            Spacer()
            Button("Настроить защиту", action: model.installFilter).disabled(model.operation != nil)
        }
        .font(.subheadline)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Label(message, systemImage: "exclamationmark.circle").fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Журнал", action: model.revealLog).buttonStyle(.link)
        }
        .font(.footnote)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                if model.hasSession { model.openSession() }
                else if model.addresses.isEmpty { model.showsSettings = true }
                else { model.start() }
            } label: {
                Label(model.hasSession ? "Открыть Claude" : model.addresses.isEmpty ? "Добавить IPv4" : "Запустить Claude",
                      systemImage: model.hasSession ? "arrow.up.right.square" : model.addresses.isEmpty ? "plus" : "play.fill")
                    .frame(minWidth: 138)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.operation != nil || (model.hasSession && model.session == nil))

            Button(action: model.checkNetwork) { Label("Проверить сеть", systemImage: "arrow.clockwise") }
                .disabled(!model.isReady || model.networkState == .checking)

            Spacer()
            if model.hasSession {
                Button("Остановить") { model.confirmStop = true }
                    .disabled(model.operation != nil)
            }
        }
        .controlSize(.large)
    }

    private var addressSummary: String {
        if model.addresses.isEmpty { return "Добавь адрес в настройках" }
        if model.effectiveAddresses.count == 1 { return model.effectiveAddresses[0] }
        return "Авто · \(model.effectiveAddresses.count)"
    }

    private var networkText: String {
        switch model.networkState {
        case .unchecked: "Сеть ещё не проверена"
        case .checking: "Проверяем V2Pro и сетевой фильтр…"
        case let .connected(address): "Подтверждён выход \(address)"
        case .blocked: "Не удалось подтвердить защищённое подключение"
        }
    }

    private var networkIcon: String {
        switch model.networkState {
        case .unchecked: "network"
        case .checking: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
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
                vpnTab.tabItem { Label("VPN", systemImage: "network") }
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
