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
            .frame(height: 322)
        }
        .padding(22)
        .frame(maxWidth: 620)
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

    private var desktopGateTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Запуск только через TunnelGuard").font(.headline)
            Text(model.desktopGateConfigured ? "Прямой запуск установленной копии ограничен." :
                "Прямой запуск установленной копии Claude из Finder и Dock будет заблокирован.")
                .foregroundStyle(.secondary)
            Text("Перед изменением закрой Claude. macOS запросит права администратора. Для обновления Claude сначала восстанови обычный запуск.")
                .foregroundStyle(.secondary)
            Button(model.desktopGateConfigured ? "Восстановить обычный запуск" : "Ограничить прямой запуск",
                   action: model.configureDesktopGate)
                .disabled(model.hasSession || model.operation != nil || (!model.desktopGateConfigured && !model.canCheckNetwork))
            if let error = model.error {
                Text(error).foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
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
