import Dispatch
import Foundation
import NetworkExtension
import OSLog
import Security

@objc(FilterProbeProvider)
final class FilterProbeProvider: NEFilterDataProvider {
    private let log = Logger(subsystem: "app.tunnelguard.lab", category: "FilterProbe")
    private let probeIdentifier = "app.tunnelguard.lab.networkprobe"

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        apply(NEFilterSettings(rules: [], defaultAction: .filterData), completionHandler: completionHandler)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // Laboratory control: only the designated probe is covered by this filter.
        if signingIdentifier(for: flow.sourceProcessAuditToken) == probeIdentifier ||
            signingIdentifier(for: flow.sourceAppAuditToken) == probeIdentifier {
            log.notice("Blocked a connection from the test probe")
            return .drop()
        }
        return .allow()
    }

    private func signingIdentifier(for auditToken: Data?) -> String? {
        guard let auditToken else { return nil }
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let fields = info as? [String: Any] else {
            return nil
        }
        return fields[kSecCodeInfoIdentifier as String] as? String
    }
}

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
