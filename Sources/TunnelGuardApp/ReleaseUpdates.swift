import Foundation

enum ReleaseUpdates {
    struct Update: Equatable {
        let version: String
        let page: URL
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let state: String
            let size: Int
        }

        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static let repository = "Romero-Back/TunnelGuard"

    static func check(currentVersion: String) async throws -> Update? {
        let endpoint = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url == endpoint, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try parse(data, currentVersion: currentVersion)
    }

    static func parse(_ data: Data, currentVersion: String) throws -> Update? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        guard release.tag_name.hasPrefix("v"),
              let latest = versionParts(String(release.tag_name.dropFirst())),
              let current = versionParts(currentVersion) else { throw URLError(.cannotDecodeContentData) }
        guard current.lexicographicallyPrecedes(latest) else { return nil }
        let image = "TunnelGuard-\(release.tag_name)-macOS-arm64.dmg"
        let available = Set(release.assets.filter { $0.state == "uploaded" && $0.size > 0 }.map(\.name))
        guard available.contains(image), available.contains(image + ".sha256"),
              let page = URL(string: "https://github.com/\(repository)/releases/tag/\(release.tag_name)") else {
            throw URLError(.resourceUnavailable)
        }
        return Update(version: String(release.tag_name.dropFirst()), page: page)
    }

    private static func versionParts(_ value: String) -> [Int]? {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { field -> Int? in
            guard let number = Int(field), number >= 0, String(number) == field else { return nil }
            return number
        }
        return fields.count == 3 && numbers.count == 3 ? numbers : nil
    }
}
