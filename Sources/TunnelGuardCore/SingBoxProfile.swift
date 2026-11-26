import CoreFoundation
import Darwin
import Foundation

public struct SingBoxProfileError: Error, CustomStringConvertible {
    public let description: String

    fileprivate init(_ description: String) {
        self.description = description
    }
}

public enum SingBoxProfile {
    private typealias Fields = [String: Any]

    public static func validate(_ data: Data) throws {
        guard let profile = try? JSONSerialization.jsonObject(with: data) as? Fields else {
            throw SingBoxProfileError("Ожидался локальный профиль sing-box в формате JSON.")
        }
        try checkKeys(profile, allowed: ["log", "dns", "inbounds", "outbounds", "route"], at: "профиль")

        let tunnel = try singleEntry(profile["inbounds"], at: "inbounds")
        try checkKeys(tunnel, allowed: ["type", "tag", "auto_route", "address", "mtu", "stack"], at: "inbounds")
        guard tunnel["type"] as? String == "tun", isJSONTrue(tunnel["auto_route"]) else {
            throw SingBoxProfileError("Для испытаний нужен TUN с включённым auto_route.")
        }

        let outbound = try singleEntry(profile["outbounds"], at: "outbounds")
        try checkKeys(outbound, allowed: ["type", "tag", "server", "server_port", "uuid", "flow", "tls", "transport", "packet_encoding", "multiplex"], at: "outbounds")
        guard outbound["type"] as? String == "vless", let tag = outbound["tag"] as? String, !tag.isEmpty,
              let server = outbound["server"] as? String, isIPAddress(server) else {
            throw SingBoxProfileError("Для этого испытательного профиля выбери один VLESS-выход с IP-адресом сервера.")
        }

        guard let route = profile["route"] as? Fields, route["final"] as? String == tag else {
            throw SingBoxProfileError("Маршрут по умолчанию должен указывать на VLESS-выход.")
        }
        try checkKeys(route, allowed: ["final", "rules", "auto_detect_interface"], at: "route")
        let dnsRules = [["action": "sniff"], ["protocol": "dns", "action": "hijack-dns"]]
        guard route["rules"] as? [[String: String]] == dnsRules else {
            throw SingBoxProfileError("Испытательный профиль допускает только правила распознавания и перехвата DNS.")
        }

        guard let dns = profile["dns"] as? Fields else {
            throw SingBoxProfileError("Добавь DNS через VLESS в испытательный профиль.")
        }
        try checkKeys(dns, allowed: ["servers", "final", "strategy"], at: "dns")
        let resolver = try singleEntry(dns["servers"], at: "dns.servers")
        try checkKeys(resolver, allowed: ["tag", "type", "server", "server_port", "detour", "path", "tls"], at: "dns.servers")
        guard resolver["type"] as? String == "https", resolver["detour"] as? String == tag,
              let resolverTag = resolver["tag"] as? String, !resolverTag.isEmpty,
              dns["final"] as? String == resolverTag,
              let resolverIP = resolver["server"] as? String, isIPAddress(resolverIP) else {
            throw SingBoxProfileError("Требуется один DNS-over-HTTPS сервер с IP-адресом и detour через VLESS.")
        }
    }

    private static func singleEntry(_ value: Any?, at section: String) throws -> Fields {
        guard let entries = value as? [Fields], entries.count == 1, let entry = entries.first else {
            throw SingBoxProfileError("В разделе \(section) должна быть ровно одна запись.")
        }
        return entry
    }

    private static func checkKeys(_ fields: Fields, allowed: Set<String>, at section: String) throws {
        guard Set(fields.keys).isSubset(of: allowed) else {
            throw SingBoxProfileError("В разделе \(section) есть параметры за пределами испытательного профиля.")
        }
    }

    private static func isJSONTrue(_ value: Any?) -> Bool {
        guard let value = value as? NSNumber else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID() && value.boolValue
    }

    private static func isIPAddress(_ text: String) -> Bool {
        guard !text.utf8.contains(0) else { return false }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, text, &ipv4) == 1 || inet_pton(AF_INET6, text, &ipv6) == 1
    }
}
