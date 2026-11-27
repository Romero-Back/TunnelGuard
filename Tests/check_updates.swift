import Foundation

@main
struct CheckUpdates {
    static func main() async throws {
        let newer = try ReleaseUpdates.parse(release("v0.10.0"), currentVersion: "0.5.2")
        precondition(newer?.version == "0.10.0")
        precondition(newer?.page.absoluteString == "https://github.com/Romero-Back/TunnelGuard/releases/tag/v0.10.0")

        for tag in ["v0.5.2", "v0.4.2"] {
            let update = try ReleaseUpdates.parse(release(tag), currentVersion: "0.5.2")
            precondition(update == nil)
        }
        let prerelease = try ReleaseUpdates.parse(release("v0.6.0", prerelease: true), currentVersion: "0.5.2")
        precondition(prerelease == nil)

        for data in [release("v0.6.0", complete: false), release("v0.6.0-rc.1")] {
            do {
                _ = try ReleaseUpdates.parse(data, currentVersion: "0.5.2")
                preconditionFailure("An invalid or incomplete release was accepted")
            } catch is URLError {}
        }
        print("PASS: release parsing, numeric comparison and asset validation")

        if CommandLine.arguments.contains("--live") {
            let update = try await ReleaseUpdates.check(currentVersion: "0.0.0")
            precondition(update != nil)
            print("PASS: live GitHub feed reports \(update!.version)")
        }
    }

    private static func release(_ tag: String, prerelease: Bool = false, complete: Bool = true) -> Data {
        let image = "TunnelGuard-\(tag)-macOS-arm64.dmg"
        let names = complete ? [image, image + ".sha256"] : [image]
        let assets = names.map { ["name": $0, "state": "uploaded", "size": 100] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "draft": false, "prerelease": prerelease, "assets": assets
        ])
    }
}
