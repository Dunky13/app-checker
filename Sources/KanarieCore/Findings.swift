import CryptoKit
import Foundation

/// A version as people read it, tolerant of what installers put in that field: "v2.0.12", "1.10" after "1.9",
/// "3.0.0_1", and pre-releases such as "0.1.12-nightly.20261124.5191", which sort after 0.1.11 and before 0.1.12.
/// shortcut: any word after the numbers marks a pre-release, so OpenSSL-style "1.1.1w" sorts before "1.1.1"; give such an app its own rule if one ever needs version files.
public struct Version: Comparable, Hashable, Sendable {
    var release: [Int] = []
    var pre: [String] = []
    /// The release numbers in front of a "-number" part, when there is one: "1.2.0-1" is a pre-release of 1.2.0 for npm
    /// and a later build of it elsewhere, so against a plain 1.2.0 it has no known order.
    var dashed: [Int]?
    static let zero = Version(release: [], pre: [])

    private init(release: [Int], pre: [String]) { (self.release, self.pre) = (release, pre) }

    /// nil when the text holds no number at all.
    public init?(_ text: String) {
        // Only the first word counts ("1.2 (345)"), and build metadata after "+" says nothing about order.
        let word = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "+" || $0 == "," }).first ?? ""
        // Runs of digits and runs of letters; anything else only separates them.
        var runs: [(text: String, afterDash: Bool)] = [], joined = false, dash = false
        for character in word {
            guard character.isASCII, character.isLetter || character.isNumber else { (joined, dash) = (false, character == "-"); continue }
            if joined, runs.last?.text.last?.isNumber == character.isNumber { runs[runs.count - 1].text.append(character) } else { runs.append((String(character), dash)) }
            joined = true
        }
        // A leading word is a prefix such as "v" or "release-".
        for run in runs.drop(while: { $0.text.first?.isNumber != true }) {
            guard pre.isEmpty, run.text.first?.isNumber == true else { pre.append(Int(run.text).map(String.init) ?? run.text); continue }  // beta.01 is beta.1
            if run.afterDash, dashed == nil, !release.isEmpty { dashed = Self.trimmed(release) }
            release.append(Int(run.text) ?? .max)
        }
        guard !release.isEmpty else { return nil }
        release = Self.trimmed(release)
    }

    /// 1.0 and 1.0.0 are the same version.
    private static func trimmed(_ numbers: [Int]) -> [Int] { Array(numbers[..<(numbers.lastIndex { $0 != 0 }.map { $0 + 1 } ?? 0)]) }

    // Order and equality both look at the numbers and the pre-release only.
    public static func == (a: Version, b: Version) -> Bool { a.release == b.release && a.pre == b.pre }
    public func hash(into hasher: inout Hasher) { hasher.combine(release); hasher.combine(pre) }

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

    /// The lowest place a dash-number version may have: "1.2.0-1" read as a pre-release sits just below 1.2.0, read as a build at 1.2.0.1.
    private var floor: Version { dashed.map { Version(release: $0, pre: []) } ?? self }

    /// Whether nothing says which of the two came first.
    func hasNoOrder(with other: Version) -> Bool {
        // A dash number may sit anywhere from its base up to itself, so whatever lies in that range has no order with it.
        // Two dash numbers on one base follow the same scheme, whichever it is.
        if dashed != other.dashed {
            let mayReach = { (a: Version, b: Version) in a.floor <= b || a.floor.release == b.release }
            if mayReach(self, other), mayReach(other, self) { return true }
        }
        // Pre-releases of one release on different channels ("nightly", "preview", "rc"): rc.1 may be older or newer than nightly.20261117.
        return release == other.release && !pre.isEmpty && !other.pre.isEmpty && pre.first != other.pre.first
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
        let parts = path.split(separator: "/", omittingEmptySubsequences: false), lower = "abcdefghijklmnopqrstuvwxyz0123456789"
        let plain = { (text: Substring, allowed: String) in !text.isEmpty && text.first != "." && text.allSatisfy(allowed.contains) }
        // Folders in lower case only, so two of them cannot collide on a file system that ignores case.
        return parts.count == 2 && plain(parts[0], lower + "-") && parts[1].hasSuffix(".json") && plain(parts[1], lower + lower.uppercased() + ".-_")
    }

    /// Every "<app>/<version>.json" below `folder`. Anything else, such as an app's NOTES.md or a hidden file the Finder left, is left alone.
    public static func read(folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        for app in Scanner.children(folder) {
            for file in Scanner.children(app) where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix(".") {
                files["\(app.lastPathComponent)/\(file.lastPathComponent)"] = try? Data(contentsOf: file)
            }
        }
        return files
    }

    /// Decodes and validates findings. One invalid file rejects them all.
    public static func rules(from files: [String: Data]) throws -> [Rule] {
        var seen: [String: (app: Substring, versions: Set<Version>)] = [:]
        let rules = try files.keys.sorted().map { path in
            let since = String(path.split(separator: "/").last?.dropLast(5) ?? "")
            guard isPath(path), let version = Version(since) else {
                throw failure("\(path): name the file <app>/<first version it applies to>.json")
            }
            guard var rule = try? JSONDecoder().decode(Rule.self, from: files[path] ?? Data()) else { throw failure("\(path): not a finding") }
            rule.since = since
            if let problem = rule.problems(curated: true).first { throw failure("\(path): \(problem)") }
            let app = path.prefix { $0 != "/" }
            for id in rule.match {
                // One timeline per item: a file in another folder would silently override the right one.
                if let other = seen[id]?.app, other != app { throw failure("\(path): \(id) already has findings in \(other)/") }
                if !seen[id, default: (app, [])].versions.insert(version).inserted { throw failure("\(path): \(id) has two findings for the same version") }
            }
            return rule
        }
        // Without a first file an older install would have no curated finding and could be judged by an unverified AI answer.
        if let id = seen.keys.sorted().first(where: { seen[$0]?.versions.contains(.zero) == false }) {
            throw failure("\(seen[id]?.app ?? "")/: no 0.json lists \(id), so versions before its first file would have no finding")
        }
        return rules
    }

    /// The signed list of files. The signature is the maintainer's Ed25519 one, made with the Sparkle update key.
    public static func index(_ data: Data, signature: String, publicKey: String) throws -> Index {
        guard let signature = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = Data(base64Encoded: publicKey).flatMap({ try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }),
              key.isValidSignature(signature, for: data) else { throw failure("The findings are not signed by Kanarie.") }
        let index = try JSONDecoder().decode(Index.self, from: data)
        guard index.version <= supportedVersion else { throw failure("Findings version \(index.version) needs a newer Kanarie.") }
        guard index.files.keys.allSatisfy(isPath) else { throw failure("The findings index lists an unexpected file name.") }
        return index
    }

    /// The findings, provided `files` are exactly the files the signed index lists.
    public static func rules(from files: [String: Data], matching index: Index) throws -> [Rule] {
        guard files.mapValues(sha256) == index.files else { throw failure("The findings do not match their signed index.") }
        return try rules(from: files)
    }

    /// Replaces `folder` with a download, keeping the index and its signature so `verified(folder:)` can check it at the next launch.
    public static func store(_ files: [String: Data], index: Data, signature: Data, in folder: URL) throws {
        let fm = FileManager.default, fresh = folder.appendingPathExtension("new")
        try? fm.removeItem(at: fresh)
        for (path, data) in files.merging(["index.json": index, "index.json.sig": signature], uniquingKeysWith: { $1 }) {
            let file = fresh.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        // In one step, so a crash leaves the old folder or the new one, never neither.
        if fm.fileExists(atPath: folder.path) { _ = try fm.replaceItemAt(folder, withItemAt: fresh) } else { try fm.moveItem(at: fresh, to: folder) }
    }

    /// A folder that carries its own index and signature, such as the app's cache of the last download.
    public static func verified(folder: URL, publicKey: String) throws -> (index: Index, rules: [Rule]) {
        let signature = try String(contentsOf: folder.appendingPathComponent("index.json.sig"), encoding: .utf8)
        let index = try index(Data(contentsOf: folder.appendingPathComponent("index.json")), signature: signature, publicKey: publicKey)
        return (index, try rules(from: read(folder: folder), matching: index))
    }
}
