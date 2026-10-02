import Foundation

private struct CheckFailure: Error {
    let message: String
}

@main
@MainActor
private enum UpdateReleaseTests {
    private static let digest = String(repeating: "a", count: 64)
    private static var checks = 0

    static func main() throws {
        try versionChecks()
        try metadataChecks()
        if CommandLine.arguments.count == 2 {
            let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let release = try UpdateRelease(checksums: text)
            print("Published checksum fixture: \(release.version.text), \(release.downloadURL.lastPathComponent)")
        }
        print("Passed \(checks) Swift update-release checks")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw CheckFailure(message: message) }
    }

    private static func version(_ text: String) throws -> ReleaseVersion {
        guard let value = ReleaseVersion(text) else { throw CheckFailure(message: "Rejected \(text)") }
        return value
    }

    private static func versionChecks() throws {
        let older = try version("0.1.9")
        let newer = try version("0.1.10")
        let same = try version("0.1.10")
        let minorOlder = try version("0.9.99")
        let minorNewer = try version("0.10.0")
        let majorOlder = try version("1.99.99")
        let majorNewer = try version("2.0.0")
        try expect(older < newer, "Patch versions must compare numerically")
        try expect(newer > older, "Downgrade must not be offered")
        try expect(newer == same, "Equal versions must remain equal")
        try expect(minorOlder < minorNewer, "Minor versions must compare numerically")
        try expect(majorOlder < majorNewer, "Major version must take precedence")
        try expect(ReleaseVersion("18446744073709551615.0.0") != nil, "UInt64 maximum is valid")
        let invalid = ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "1.2.3+build",
                       "-1.2.3", "+1.2.3", "01.2.3", "1.02.3", "1.2.03", "1..3", "1.2.",
                       " 1.2.3", "1.2.3 ", "١.2.3", "18446744073709551616.0.0"]
        for text in invalid { try expect(ReleaseVersion(text) == nil, "Accepted malformed version: \(text)") }
    }

    private static func metadataChecks() throws {
        let filename = "less-sheet-0.1.10-macos-arm64.dmg"
        let valid = "\(digest)  less-sheet-0.1.10-linux-x86_64.tar.gz\n\(digest)  \(filename)\n"
        let release = try UpdateRelease(checksums: valid)
        try expect(release.version.text == "0.1.10", "Selected wrong version")
        try expect(release.downloadURL.absoluteString == "https://github.com/te-x/less-sheet/releases/download/"
                   + "v0.1.10/\(filename)", "Download URL must target the exact stable platform asset")
        let uppercase = try UpdateRelease(checksums: "\(digest.uppercased()) *\(filename)\r\n")
        try expect(uppercase.version == release.version, "Uppercase digest or binary marker rejected")
        let invalid = ["", "\(digest)  less-sheet-0.1.10-linux-x86_64.tar.gz\n",
                       "\(digest.dropLast())  \(filename)\n", "\(String(repeating: "g", count: 64))  \(filename)\n",
                       "\(digest)  less-sheet-v0.1.10-macos-arm64.dmg\n",
                       "\(digest)  less-sheet-0.1.10-beta-macos-arm64.dmg\n",
                       "\(digest)  less-sheet-01.1.10-macos-arm64.dmg\n",
                       "\(digest)  less-sheet-0.1.10/../../evil-macos-arm64.dmg\n",
                       "\(digest)  https://example.com/\(filename)\n", valid + valid,
                       valid + "\(digest)  less-sheet-0.1.11-macos-arm64.dmg\n"]
        for text in invalid {
            do {
                _ = try UpdateRelease(checksums: text)
                throw CheckFailure(message: "Accepted malformed or ambiguous release metadata")
            } catch is UpdateCheckError {
                checks += 1
            }
        }
    }
}
