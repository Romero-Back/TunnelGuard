import Foundation

struct NetworkObservation: Decodable, Equatable, Sendable {
    enum Filter: String, Decodable, Sendable { case healthy, failed, missing, unknown }

    let interface: String?
    let vpnName: String?
    let vpnChoices: [String: String]?
    let routeIPv4: Bool?
    let routeIPv6: Bool?
    let filter: Filter
    let filterRuns: Int?
    let paused: Bool?
    let codeActive: Bool?
    let codeAuthorized: Bool?

    static let unavailable = Self(interface: nil, vpnName: nil, vpnChoices: nil, routeIPv4: nil, routeIPv6: nil,
                                  filter: .unknown, filterRuns: nil, paused: nil, codeActive: nil, codeAuthorized: nil)
}

struct VPNFingerprint: Decodable {
    let interface: String
    let egress: String
    let vpnName: String
}

enum Diagnostic: String, Sendable {
    case fingerprint, leak = "leak-test"
}

struct GuardEvent: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    let title: String
    let warning: Bool
}
