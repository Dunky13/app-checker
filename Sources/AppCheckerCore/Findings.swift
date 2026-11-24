import CryptoKit
import Foundation

/// A version as people read it, tolerant of what installers put in that field: "v2.0.12", "1.10" after "1.9",
/// "3.0.0_1", "7.1.2-5", and pre-releases such as "0.1.12-nightly.20261124.5191", which sort after 0.1.11 and before 0.1.12.
/// shortcut: any word after the numbers marks a pre-release, so OpenSSL-style "1.1.1w" sorts before "1.1.1"; give such an app its own rule if one ever needs version files.
public struct Version: Comparable, Hashable, Sendable {
    var release: [Int] = []
    var pre: [String] = []
    static let zero = Version(release: [], pre: [])

    private init(release: [Int], pre: [String]) { (self.release, self.pre) = (release, pre) }

    /// nil when the text holds no number at all.
    public init?(_ text: String) {
        // Only the first word counts ("1.2 (345)"), and build metadata after "+" says nothing about order.
        let word = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "+" || $0 == "," }).first ?? ""
        // Runs of digits and runs of letters; anything else only separates them.
        var runs: [String] = [], joined = false
        for character in word {
            guard character.isASCII, character.isLetter || character.isNumber else { joined = false; continue }
            if joined, runs.last?.last?.isNumber == character.isNumber { runs[runs.count - 1].append(character) } else { runs.append(String(character)) }
            joined = true
        }
        // A leading word is a prefix such as "v" or "release-".
        for run in runs.drop(while: { $0.first?.isNumber != true }) {
            if pre.isEmpty, run.first?.isNumber == true { release.append(Int(run) ?? .max) } else { pre.append(run) }
        }
        guard !release.isEmpty else { return nil }
        while release.last == 0 { release.removeLast() }  // 1.0 and 1.0.0 are the same version
    }

    public static func < (a: Version, b: Version) -> Bool {
        for index in 0..<max(a.release.count, b.release.count) {
            let (x, y) = (index < a.release.count ? a.release[index] : 0, index < b.release.count ? b.release[index] : 0)
            if x != y { return x < y }
        }
        // A pre-release comes before its release. Among pre-releases: numbers by value and before words, a shorter one first.
        if a.pre.isEmpty || b.pre.isEmpty { return !a.pre.isEmpty && b.pre.isEmpty }
        for (x, y) in zip(a.pre, b.pre) where x != y {
            if let nx = Int(x), let ny = Int(y) { return nx < ny }
            return Int(x) != nil ? true : Int(y) != nil ? false : x < y
        }
        return a.pre.count < b.pre.count
    }
}

/// The curated findings: one folder per app, one file per version from which a finding holds.
///   findings/t3-code/0.json                                  from the first version
///   findings/t3-code/0.1.11-nightly.20261117.4814.json       from that build onward
/// A file stays valid until one with a higher version exists, so a range needs no end.
/// `index.json` lists every file with its SHA-256 and is signed, so downloaded findings are exactly what the maintainer published.
public enum Findings {
    public static let supportedVersion = 1

    public struct Index: Codable, Sendable {
        public var version: Int
        /// Grows with every signing. The app never moves to a lower one, so an old index cannot be played back.
        public var serial: Int
        /// "app/version.json" -> SHA-256 in hex.
        public var files: [String: String]
    }

    static func failure(_ message: String) -> CocoaError {
        CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: message])
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// "app/version.json" with plain characters only: paths end up in URLs and on disk.
    static func isPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let plain = { (text: Substring, extra: String) in !text.isEmpty && text.first != "." && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) } }
        return parts.count == 2 && plain(parts[0], "-") && parts[1].hasSuffix(".json") && plain(parts[1], ".-_")
    }

    /// Every "<app>/<version>.json" below `folder`. Anything else, such as an app's NOTES.md, is left alone.
    public static func read(folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        for app in Scanner.children(folder) {
            for file in Scanner.children(app) where file.pathExtension == "json" {
                files["\(app.lastPathComponent)/\(file.lastPathComponent)"] = try? Data(contentsOf: file)
            }
        }
        return files
    }

    /// Decodes and validates findings. One invalid file rejects them all.
    public static func rules(from files: [String: Data]) throws -> [Rule] {
        var seen: [String: Set<Version>] = [:]
        return try files.keys.sorted().map { path in
            let since = String(path.split(separator: "/").last?.dropLast(5) ?? "")
            guard isPath(path), let version = Version(since) else {
                throw failure("\(path): name the file <app>/<first version it applies to>.json")
            }
            guard var rule = try? JSONDecoder().decode(Rule.self, from: files[path] ?? Data()) else { throw failure("\(path): not a finding") }
            rule.since = since
            if let problem = rule.problems(curated: true).first { throw failure("\(path): \(problem)") }
            for id in rule.match where !seen[id, default: []].insert(version).inserted { throw failure("\(path): \(id) has two findings for the same version") }
            return rule
        }
    }

    /// The signed list of files. The signature is the maintainer's Ed25519 one, made with the Sparkle update key.
    public static func index(_ data: Data, signature: String, publicKey: String) throws -> Index {
        guard let signature = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
              key.isValidSignature(signature, for: data) else { throw failure("The findings are not signed by App Checker.") }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.version <= supportedVersion else { throw failure("Findings version \(index.version) needs a newer App Checker.") }
        guard index.files.keys.allSatisfy(isPath) else { throw failure("The findings index lists an unexpected file name.") }
        return index
    }

    /// The findings, provided `files` are exactly the files the signed index lists.
    public static func rules(from files: [String: Data], matching index: Index) throws -> [Rule] {
        guard files.mapValues(sha256) == index.files else { throw failure("The findings do not match their signed index.") }
        return try rules(from: files)
    }

    /// A folder that carries its own index and signature, such as the app's cache of the last download.
    public static func verified(folder: URL, publicKey: String) throws -> (index: Index, rules: [Rule]) {
        let signature = try String(contentsOf: folder.appendingPathComponent("index.json.sig"), encoding: .utf8)
        let index = try index(Data(contentsOf: folder.appendingPathComponent("index.json")), signature: signature, publicKey: publicKey)
        return (index, try rules(from: read(folder: folder), matching: index))
    }
}
