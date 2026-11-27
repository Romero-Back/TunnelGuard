import AppKit
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: DesktopModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки").font(.system(size: 32, weight: .bold))

            TabView {
                vpnTab.disabled(model.operation != nil)
                    .tabItem { Label("VPN", systemImage: "network") }
                desktopGateTab.tabItem { Label("Claude Desktop", systemImage: "lock.shield") }
                appearanceTab.tabItem { Label("Оформление", systemImage: "paintbrush") }
            }
            .frame(height: 380)
        }
        .padding(22)
        .frame(maxWidth: 620)
    }

    private var vpnTab: some View {
        ScrollView {
            vpnSettings
                .padding(16)
        }
    }

    private var vpnSettings: some View {
        let current = model.observation?.vpnName
        let detected = model.observation?.vpnChoices ?? [:]
        let selected = model.vpnDraft ?? current
        let profiles = Set(detected.keys).union([current, model.vpnDraft].compactMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let canApply = selected.map { detected[$0] != nil } == true &&
            (selected != current || !model.filterConfigured) &&
            !model.hasSession && model.observation?.codeActive != true
        return VStack(alignment: .leading, spacing: 12) {
            Text("Интерфейс VPN").font(.headline)
            HStack {
                Picker("VPN", selection: Binding(get: { selected }, set: { model.vpnDraft = $0 })) {
                    if selected == nil { Text("Выбери VPN").tag(String?.none) }
                    ForEach(profiles, id: \.self) { profile in
                        Text("\(profile) · \(detected[profile] ?? "Недоступен")").tag(Optional(profile))
                    }
                }
                .disabled(profiles.isEmpty)
                Button("Применить") { model.applyVPN(selected) }
                    .disabled(!canApply)
            }
            Text("Текущий выбор · \(current ?? "Недоступен")")
                .font(.caption).foregroundStyle(.secondary)
            if model.hasSession || model.observation?.codeActive == true {
                Text("Закрой Claude Desktop и Claude Code, чтобы сменить VPN.").foregroundStyle(.secondary)
            } else if detected.isEmpty {
                Text("Подключи VPN в режиме TUN. В списке появляются активные интерфейсы, которые macOS связывает с VPN-клиентом.")
                    .foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            Divider()
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var desktopGateTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Запуск только через TunnelGuard").font(.headline)
            switch model.desktopGateState {
            case .off:
                Label("Прямой запуск Claude сейчас доступен", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            case .invalid:
                Label("Ограничение запуска повреждено или не закончено", systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            case .installed:
                Label("Прямой запуск установленной копии ограничен", systemImage: "lock.shield")
            }
            Text("Перед изменением закрой Claude. macOS запросит права администратора. Для обновления Claude сначала восстанови обычный запуск.")
                .foregroundStyle(.secondary)
            Button(model.desktopGateState == .off ? "Ограничить прямой запуск" : "Восстановить обычный запуск",
                   action: model.configureDesktopGate)
                .disabled(model.hasSession || model.operation != nil || (model.desktopGateState == .off && !model.canCheckNetwork))
            if let error = model.error {
                Text(error).foregroundStyle(.orange)
            }
            Divider()
            Button("Настроить на другом Mac", action: showOtherMacSetup)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
    }

    private func showOtherMacSetup() {
        let release = "https://github.com/Romero-Back/TunnelGuard/releases/latest"
        let instructions = """
            1. На другом Mac с Apple Silicon скачай и установи TunnelGuard.
            2. Подключи VPN в режиме TUN и добавь разрешённый IPv4 выхода во вкладке «VPN».
            3. Закрой Claude и нажми «Применить» рядом с нужным VPN. macOS запросит права администратора.
            4. В экспертном режиме выбери «Настройки → Claude Desktop → Ограничить прямой запуск» и подтверди права администратора.
            """
        let alert = NSAlert()
        alert.messageText = "Настроить на другом Mac"
        alert.informativeText = instructions
        alert.addButton(withTitle: "Скопировать инструкцию")
        alert.addButton(withTitle: "Открыть релиз")
        alert.addButton(withTitle: "Закрыть")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("TunnelGuard\n" + release + "\n\n" + instructions, forType: .string)
        case .alertSecondButtonReturn:
            if let url = URL(string: release) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private var appearanceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Режим интерфейса", selection: $model.interfaceMode) {
                ForEach(DesktopModel.InterfaceMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Divider()
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
