import NetworkExtension
import SwiftUI

@main
struct TunnelGuardLab: App {
    private let configuration: NEFilterProviderConfiguration = {
        let configuration = NEFilterProviderConfiguration()
        configuration.filterDataProviderBundleIdentifier = "app.tunnelguard.lab.filter"
        configuration.filterSockets = true
        configuration.filterPackets = false
        return configuration
    }()

    var body: some Scene {
        WindowGroup("TunnelGuard Lab") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Активация фильтра недоступна в этой сборке.")
                LabeledContent("Системное расширение",
                               value: configuration.filterDataProviderBundleIdentifier ?? "—")
                LabeledContent("Фильтруемые соединения", value: "Сокеты")
            }
            .padding(24)
        }
        .windowResizability(.contentSize)
    }
}
