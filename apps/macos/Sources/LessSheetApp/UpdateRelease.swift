import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Release versions are strictly numeric; string ordering would put 0.1.10 before 0.1.9.
struct ReleaseVersion: Comparable, Sendable {
    let text: String
    private let components: [UInt64]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let value = UInt64(part) else { return nil }
            values.append(value)
        }
        self.text = text
        components = values
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

enum UpdateCheckError: LocalizedError {
    case invalidVersion
    case invalidMetadata
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidVersion:
            return "The installed app's version could not be read. Use an assembled less-sheet app bundle."
        case .invalidMetadata:
            return "The latest release does not contain valid download information for this Mac."
        case .unavailable:
            return "The release server could not be reached. Check your internet connection and try again."
        }
    }
}

/// The existing checksum asset follows GitHub's latest stable release redirect.
/// Selecting a known filename also keeps release metadata from supplying arbitrary download URLs.
struct UpdateRelease: Sendable {
    let version: ReleaseVersion
    let downloadURL: URL

    init(checksums: String) throws {
        let prefix = "less-sheet-"
        let suffix = "-macos-arm64.dmg"
        var candidate: ReleaseVersion?
        for line in checksums.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { continue }
            let filename = fields[1].hasPrefix("*") ? fields[1].dropFirst() : fields[1]
            guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { continue }
            let checksum = fields[0]
            guard checksum.count == 64,
                  checksum.utf8.allSatisfy({
                      (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                  }),
                  candidate == nil,
                  let version = ReleaseVersion(String(filename.dropFirst(prefix.count).dropLast(suffix.count)))
            else { throw UpdateCheckError.invalidMetadata }
            candidate = version
        }
        guard let version = candidate,
              let url = URL(string: "https://github.com/te-x/less-sheet/releases/download/"
                            + "v\(version.text)/\(prefix)\(version.text)\(suffix)")
        else { throw UpdateCheckError.invalidMetadata }
        self.version = version
        downloadURL = url
    }

    static func latest() async throws -> UpdateRelease {
        guard let url = URL(string: "https://github.com/te-x/less-sheet/releases/latest/download/SHA256SUMS")
        else { throw UpdateCheckError.invalidMetadata }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("less-sheet update check", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateCheckError.unavailable
        }
        guard data.count <= 65_536, let checksums = String(data: data, encoding: .utf8) else {
            throw UpdateCheckError.invalidMetadata
        }
        return try UpdateRelease(checksums: checksums)
    }
}
