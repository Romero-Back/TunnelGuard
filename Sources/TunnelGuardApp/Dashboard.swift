import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case overview, apps, routes, doctor, journal, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Главная"
        case .apps: "Приложения"
        case .routes: "Маршруты"
        case .doctor: "Диагностика"
        case .journal: "Журнал"
        case .settings: "Настройки"
        }
    }

    var icon: String {
        switch self {
        case .overview: "house"
        case .apps: "square.stack"
        case .routes: "point.3.connected.trianglepath.dotted"
        case .doctor: "stethoscope"
        case .journal: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}

enum RouteStep: String, CaseIterable, Identifiable {
    case apps, filter, vpn, internet
    var id: Self { self }
    var title: String {
        switch self {
        case .apps: "Приложения"
        case .filter: "Фильтр"
        case .vpn: "V2Pro"
        case .internet: "Интернет"
        }
    }

    var icon: String {
        switch self {
        case .apps: "app.badge.checkmark"
        case .filter: "lock.shield"
        case .vpn: "point.3.filled.connected.trianglepath.dotted"
        case .internet: "globe.americas"
        }
    }
}

struct Dashboard: View {
    @ObservedObject var model: DesktopModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var section: Section? { model.section }
    private var routeStep: RouteStep { model.routeStep }

    private var accent: Color { scheme == .dark ? model.accent.darkForeground : model.accent.color }
    private var healthy: Bool {
        !model.paused && !model.filterStalled && model.observation?.filter == .healthy && model.observation?.routeIPv4 == true
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TunnelGuard").font(.title3.bold())
                        Text("Сетевая защита macOS").font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

                List(Section.allCases, selection: $model.section) { page in
                    Label(page.title, systemImage: page.icon).tag(page)
                        .padding(.vertical, 4)
                }
                .listStyle(.sidebar)

                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Label(filterTitle, systemImage: healthy ? "checkmark.circle.fill" : "shield")
                        .foregroundStyle(healthy ? accent : .primary)
                    Text(model.hotkeyAvailable ? "Паника · ⌥⇧⌘P" : "Глобальная клавиша недоступна")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            if section == .settings {
                ScrollView { PreferencesView(model: model).frame(maxWidth: .infinity) }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heading
                        switch section ?? .overview {
                        case .overview: overview
                        case .apps: apps
                        case .routes: routeMap; routeFacts
                        case .doctor: doctor
                        case .journal: eventList(limit: 100)
                        case .settings: EmptyView()
                        }
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: 1150)
                    .tint(model.accent.color)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .toolbar {
            Button(action: model.checkNetwork) {
                Label("Проверить сеть", systemImage: "arrow.clockwise")
            }
            .disabled(!model.canCheckNetwork)
            Button(action: model.pause) {
                Label("Аварийная остановка", systemImage: "hand.raised")
            }
            .disabled(model.emergencyAction || model.observation?.paused == true)
        }
        .alert("Остановить Claude Desktop?", isPresented: $model.confirmStop) {
            Button("Остановить", role: .destructive, action: model.stop)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Окно защищённого сеанса закроется.")
        }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            Text((section ?? .overview).title).font(.system(size: 32, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let observedAt = model.observedAt {
                Label { Text(observedAt, style: .time).monospacedDigit() } icon: {
                    Image(systemName: "clock").accessibilityHidden(true)
                }
                .font(.caption).foregroundStyle(.secondary)
                .help("Время последнего наблюдения за маршрутом и службой")
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            hero
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { routeMap; apps }.frame(minWidth: 410)
                    VStack(spacing: 16) { routeFacts; recentEvents }.frame(minWidth: 245, idealWidth: 270, maxWidth: 320)
                }
                VStack(spacing: 16) { routeMap; routeFacts; apps; recentEvents }
            }
        }
    }

    private var hero: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(accent.opacity(0.11)).frame(width: 100, height: 100)
                Circle().strokeBorder(accent.opacity(0.30)).frame(width: 84, height: 84)
                Circle().fill(accent.opacity(0.13)).frame(width: 66, height: 66)
                Image(systemName: healthy ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 36, weight: .medium)).foregroundStyle(healthy ? accent : .secondary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(heroTitle)
                    .font(.system(size: 28, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(heroDetail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.observation?.paused == true {
                    Button("Разрешить новые запуски", action: model.resume)
                        .disabled(model.emergencyAction)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [accent.opacity(healthy ? 0.18 : 0.07), accent.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accent.opacity(0.20)))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: healthy)
    }

    private var heroTitle: String {
        if model.observation?.paused == true { return "Доступ приостановлен" }
        if model.observation == nil { return "Проверяем защиту" }
        if healthy, case .connected = model.networkState { return "Защищённый выход подтверждён" }
        return healthy ? "V2Pro под наблюдением" : "Защита требует внимания"
    }

    private var heroDetail: String {
        if model.emergencyAction { return "Выполняется аварийное действие." }
        if model.observation?.paused == true { return "Новые защищённые запуски заблокированы, пока доступ не восстановлен." }
        if model.observation == nil { return "Проверяем маршрут V2Pro и состояние службы PF." }
        if model.observation?.paused == nil { return "Состояние аварийной блокировки недоступно. Запуск приостановлен." }
        return healthy ? "Система видит маршрут V2Pro. TunnelGuard проверит выход и фильтр перед открытием Claude." :
            "Открой диагностику, чтобы проверить маршрут, настройки VPN и службу PF."
    }

    private var routeMap: some View {
        panel("Путь подключения", icon: "arrow.triangle.branch") {
            HStack(spacing: 5) {
                ForEach(RouteStep.allCases) { step in
                    if step != .apps {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .foregroundStyle(healthy ? accent : .secondary).accessibilityHidden(true)
                    }
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { model.routeStep = step }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: step.icon).font(.system(size: 19))
                            Text(step.title).font(.caption.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .foregroundStyle(routeStep == step ? accent : .primary)
                        .background((routeStep == step ? accent.opacity(0.13) : Color.primary.opacity(0.04)),
                                    in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(routeStep == step ? .isSelected : [])
                }
            }
            Text(stepDetail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "app").accessibilityHidden(true)
                Capsule().strokeBorder(.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 30, height: 2).accessibilityHidden(true)
                Image(systemName: healthy ? "nosign" : "questionmark.circle").accessibilityHidden(true)
                Text(healthy ? "Прямой путь запрещён политикой" : "Статус прямого пути требует проверки")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stepDetail: String {
        switch routeStep {
        case .apps: "Claude Desktop использует выделенную группу PF, Claude Code — локальный HTTPS-прокси в песочнице."
        case .filter: "PF ограничивает IPv4 интерфейсом V2Pro и блокирует IPv6 для Desktop. Песочница Code разрешает только порт прокси."
        case .vpn: "Контрольный маршрут IPv4: \(routeDescription(model.observation?.routeIPv4)). Интерфейс: \(model.observation?.interface ?? "недоступен")."
        case .internet: "Проверка сверяет разрешённый IPv4 по двум источникам. Маршруты внутри VPN-клиента системному фильтру не видны."
        }
    }

    private var routeFacts: some View {
        panel("VPN и системный фильтр", icon: "network") {
            fact("VPN-клиент", "V2Pro")
            fact("Интерфейс", model.observation?.interface ?? "Недоступен")
            fact("Контрольный IPv4", routeDescription(model.observation?.routeIPv4))
            fact("Контрольный IPv6", routeDescription(model.observation?.routeIPv6))
            fact("Служба PF", filterTitle)
            if case let .connected(address) = model.networkState {
                fact("Проверенный выход", address)
            } else if model.networkState == .checking {
                ProgressView().controlSize(.small)
            } else {
                fact("Внешний IPv4", model.networkState == .blocked ? "Не подтверждён" : "Требуется проверка")
            }
            if let date = model.lastChecked {
                HStack { Text("Последняя проверка"); Spacer(); Text(date, style: .time).monospacedDigit() }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var apps: some View {
        panel("Защищаемые приложения", icon: "square.stack") {
            appRow("Claude Desktop", icon: "macwindow", status: model.status, active: model.session != nil) {
                if !model.filterConfigured {
                    Button("Настроить PF", action: model.installFilter).disabled(model.operation != nil)
                } else if model.addresses.isEmpty {
                    Button("Добавить IPv4") { model.section = .settings }
                } else {
                    Button(model.hasSession ? "Открыть" : "Запустить", action: model.openClaude)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canOpenDesktop)
                    if model.hasSession {
                        Button { model.confirmStop = true } label: {
                            Image(systemName: "stop.fill")
                        }
                        .help("Остановить Claude Desktop")
                        .accessibilityLabel("Остановить Claude Desktop")
                        .disabled(model.operation != nil)
                    }
                }
            }
            Divider()
            appRow("Claude Code", icon: "terminal", status: codeStatus, active: model.observation?.codeActive == true) {
                Button("Запустить", action: model.launchCode)
                    .disabled(model.paused || model.addresses.isEmpty || model.observation?.codeActive == true)
            }
        }
    }

    private var codeStatus: String {
        if model.observation?.codeActive == true {
            return model.observation?.codeAuthorized == true ? "Управляемый сеанс в Terminal" : "Сеанс в Terminal · доступ отозван"
        }
        return model.observation?.codeActive == false ? "Управляемого сеанса нет" : "Состояние недоступно"
    }

    private var filterTitle: String {
        if model.filterStalled { return "Обновление правил задержалось" }
        return switch model.observation?.filter {
        case .healthy: "Последний запуск успешен"
        case .failed: "Ошибка службы"
        case .missing: "Служба не загружена"
        default: "Статус недоступен"
        }
    }

    private func routeDescription(_ route: Bool?) -> String {
        switch route {
        case true?: "Через V2Pro"
        case false?: "Не подтверждён"
        case nil: "Недоступен"
        }
    }

    private var doctor: some View {
        VStack(alignment: .leading, spacing: 16) {
            routeFacts
            panel("Connection Doctor", icon: "stethoscope") {
                Text("Совместимость проверяется для V2Pro. Отпечаток состоит из клиента, интерфейса и подтверждённого разрешённого IPv4.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Проверить совместимость", action: { model.diagnose(.fingerprint) })
                    Button("Проверить утечки TCP", action: { model.diagnose(.leak) })
                        .disabled(!model.filterConfigured)
                    if model.diagnosticRunning { ProgressView().controlSize(.small) }
                }
                .disabled(model.paused || model.diagnosticRunning || model.addresses.isEmpty)
                if let result = model.diagnosticResult { Text(result).textSelection(.enabled) }
                Text("Тест проверяет прямой TCP на контрольных локальных портах. Системный DNS, запросы сторонних служб и фактический обрыв VPN здесь не измеряются.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentEvents: some View {
        panel("Последние события", icon: "clock") {
            eventList(limit: 4)
            if !model.events.isEmpty { Button("Весь журнал") { model.section = .journal } }
        }
    }

    private func eventList(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.events.isEmpty { Text("Событий пока нет").foregroundStyle(.secondary) }
            ForEach(model.events.prefix(limit)) { event in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: event.warning ? "exclamationmark.circle.fill" : "circle.fill")
                        .font(.caption2).foregroundStyle(event.warning ? .orange : accent)
                        .accessibilityHidden(true)
                    Text(limit > 4 ? event.date.formatted(.dateTime.day().month().hour().minute()) :
                         event.date.formatted(.dateTime.hour().minute()))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(event.title).font(.subheadline)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func panel<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.quaternary))
    }

    private func fact(_ name: String, _ detail: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(detail).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func appRow<Actions: View>(_ name: String, icon: String, status: String, active: Bool,
                                      @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.subheadline.weight(.semibold))
                Text(status).font(.caption).foregroundStyle(active && healthy ? accent : .secondary)
            }
            Spacer(minLength: 4)
            actions()
        }
    }
}
