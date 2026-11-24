import Foundation
import Synchronization

public enum Status: String, Codable, Sendable {
    case bad, warn, ok, unknown
}

public enum Telemetry: String, Codable, Sendable {
    case none, optIn = "opt-in", optOut = "opt-out", forced, unknown
}

/// A read-only test of local state. Exactly one of `env`, `defaults`, `json`, `file` is set.
/// There is deliberately no command form: rules are refreshed from the network and must never execute anything.
public struct Check: Codable, Sendable, Hashable {
    public var env, defaults, json, file, key, equals, contains: String?
    /// For `env` only: matches when the variable is set to anything but these values, compared trimmed and in lower case.
    /// For tools that read every other value as "on", whatever its spelling.
    public var notIn: [String]?

    public var isWellFormed: Bool {
        switch (env, defaults, json, file) {
        case (.some, nil, nil, nil): key == nil && contains == nil && (equals == nil || notIn == nil)
        // A stored false reads as "0" or "false", so "any value" would mistake it for a switch that is on.
        case (nil, .some, nil, nil): key != nil && equals != nil && contains == nil && notIn == nil
        case let (nil, nil, .some(path), nil): key != nil && equals != nil && contains == nil && notIn == nil && Self.isReadable(path)
        case let (nil, nil, nil, .some(path)): contains != nil && key == nil && equals == nil && notIn == nil && Self.isReadable(path)
        default: false
        }
    }

    /// Rules may only read settings below the home folder or a Homebrew prefix, never other volumes or other users.
    static func isReadable(_ path: String) -> Bool {
        ["~/", "/opt/homebrew/", "/usr/local/"].contains { path.hasPrefix($0) } && !path.split(separator: "/").contains("..")
    }

    /// true or false when the setting could be read, nil when macOS privacy protection blocked the read.
    public func result(_ probe: Probe) -> Bool? {
        func matches(_ value: String?) -> Bool {
            guard let value else { return false }
            return equals.map { $0 == value } ?? !value.isEmpty
        }
        if let env, let notIn {
            return probe.env[env].map { !notIn.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) } ?? false
        }
        if let env { return matches(probe.env[env]) }
        if let defaults, let key { return matches(probe.defaults(defaults, key)) }
        guard let path = json ?? file else { return false }
        switch probe.file(path) {
        case .blocked: return nil
        case .missing: return false
        case let .data(data):
            if let key { return matches(jsonValue(in: data, key: key)) }
            // Commented-out lines are dropped first, so "# disable_checkpoint = true" does not count as set.
            let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                .filter { line in !["#", "//", ";"].contains { line.drop(while: \.isWhitespace).hasPrefix($0) } }
            return contains.map { lines.joined(separator: "\n").contains($0) } ?? false
        }
    }
}

public struct OptOut: Codable, Sendable, Hashable {
    public var instructions: String
    public var command: String?
    public var url: String?
}

public struct Rule: Codable, Sendable, Hashable {
    public var match: [String]
    public var name: String?
    public var telemetry: Telemetry
    public var summary: String
    public var policyURL: String?
    public var optOut: OptOut?
    public var disabledWhen: [Check]?
    public var enabledWhen: [Check]?
    public var sources: [String]?
    /// The first version this finding applies to. Comes from the file name, not from the file.
    public var since: String?

    static let unsureNote = "The installed version does not say which finding applies, so the strictest one is shown."

    /// The findings that may hold for `version` among those for one item, oldest first. Normally that is one:
    /// the newest that starts at or below it. When the version cannot say, every finding that might hold comes back
    /// and the caller shows the worst: all of them for a version that cannot be read, and any that starts on another
    /// pre-release channel of the same release.
    public static func pick(_ candidates: [Rule], version: String) -> [Rule] {
        let start = { (rule: Rule) in rule.since.flatMap(Version.init) ?? .zero }
        let sorted = candidates.sorted { start($0) < start($1) }
        guard let version = Version(version) else { return sorted }
        let unsure = { (rule: Rule) in version.hasNoOrder(with: start(rule)) }
        // The first file also covers what sorts below it, such as "0.0.0-dev": no version may be left without a finding.
        let certain = sorted.lastIndex { !unsure($0) && (start($0) <= version || start($0) == .zero) }
        return sorted.enumerated().filter { $0.offset == certain || unsure($0.element) }.map(\.element)
    }

    /// What is wrong with this rule, first problem first. Every rule passes through here before it is used:
    /// bundled and downloaded ones as `curated`, AI answers with the safety checks only.
    public func problems(curated: Bool) -> [String] {
        var found: [String] = []
        if match.isEmpty || !match.allSatisfy({ id in ["app", "brew", "cask", "bin", "npm", "ext"].contains { id.hasPrefix("\($0):") } }) {
            found.append("match needs ids starting with app:, brew:, cask:, bin:, npm: or ext:")
        }
        if !((disabledWhen ?? []) + (enabledWhen ?? [])).allSatisfy(\.isWellFormed) { found.append("malformed check") }
        // The command is offered for copying, so nothing invisible (control or formatting characters, line breaks) may ride along.
        if optOut?.command?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == true {
            found.append("the command contains hidden characters or line breaks")
        }
        // Yellow promises a way out, so an opt-out verdict without one is not usable.
        if [.optOut, .optIn].contains(telemetry), (optOut?.instructions ?? "").isEmpty { found.append("an opt-out needs instructions") }
        guard curated else { return found }
        if telemetry == .unknown { found.append("unknown telemetry does not belong in the curated rules") }
        if summary.isEmpty { found.append("no summary") }
        if (sources ?? []).isEmpty { found.append("no sources") }
        if [.optOut, .optIn].contains(telemetry), safeURL(optOut?.url) == nil { found.append("needs optOut with a url") }
        for link in [policyURL, optOut?.url].compactMap(\.self) + (sources ?? []) where safeURL(link) == nil {
            found.append("not an http(s) link: \(link)")
        }
        return found
    }

    /// Maps the rule plus this Mac's current settings to a status and a one-line explanation.
    public func evaluate(_ probe: Probe) -> (status: Status, state: String) {
        switch telemetry {
        case .none: return (.ok, "No telemetry.")
        case .forced: return (.bad, "Telemetry is on and cannot be switched off.")
        case .unknown: return (.unknown, "Telemetry behaviour could not be determined.")
        case .optOut:
            // An explicit "on" switch beats every "off" switch, as with gh: GH_TELEMETRY=enabled overrides DO_NOT_TRACK.
            let forced = (enabledWhen ?? []).map { $0.result(probe) }
            if forced.contains(true) { return (.warn, "A setting on this Mac switches telemetry on. You can switch it off.") }
            // An "on" switch that could not be read may still be set, so it must not end in green.
            if forced.contains(nil) { return (.warn, "Telemetry is on by default. \(Self.blockedNote)") }
            let results = (disabledWhen ?? []).map { $0.result(probe) }
            if results.contains(true) { return (.ok, "Telemetry is switched off on this Mac.") }
            if results.contains(nil) { return (.warn, "Telemetry is on by default. \(Self.blockedNote)") }
            return (.warn, results.isEmpty
                ? "Telemetry is on by default. The current setting cannot be read from this Mac."
                : "No opt-out setting was found on this Mac, so telemetry is on by default. You can switch it off.")
        case .optIn:
            let results = (enabledWhen ?? []).map { $0.result(probe) }
            if results.contains(true) { return (.warn, "Telemetry has been switched on. You can switch it off.") }
            if results.contains(nil) { return (.ok, "Telemetry stays off unless you enable it. \(Self.blockedNote)") }
            return (.ok, results.isEmpty
                ? "Telemetry is off unless you agreed to it. App Checker cannot read that choice on this Mac."
                : "Telemetry stays off unless you enable it.")
        }
    }

    static let blockedNote = "macOS did not let App Checker read this app's setting. To allow it, open System Settings > Privacy & Security > Files & Folders, then rescan."
}

/// Local state the checks read. Injected so the rule engine is testable.
public struct Probe: Sendable {
    public var env: [String: String]
    public var defaults: @Sendable (_ domain: String, _ key: String) -> String?
    public var file: @Sendable (_ path: String) -> FileRead

    public enum FileRead: Sendable, Equatable { case data(Data), missing, blocked }

    public init(
        env: [String: String],
        defaults: @escaping @Sendable (String, String) -> String?,
        file: @escaping @Sendable (String) -> FileRead
    ) {
        self.env = env
        self.defaults = defaults
        self.file = file
    }

    public static func live(env: [String: String]) -> Probe {
        Probe(
            env: env,
            defaults: { domain, key in
                // shortcut: sandboxed apps keep preferences in their container, which this does not read; add a container lookup when a rule needs it.
                CFPreferencesAppSynchronize(domain as CFString)
                return CFPreferencesCopyAppValue(key as CFString, domain as CFString).map { "\($0)" }
            },
            file: { path in
                // Dotfile managers symlink config files into place, so judge the target, not the link.
                let path = NSString(string: path).expandingTildeInPath, url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                // macOS shows a "Data Access Blocked" notification for every refused read, so ask only once until the user rescans.
                if blockedPaths.withLock({ $0.contains(path) }) { return .blocked }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                    guard values.isRegularFile == true, (values.fileSize ?? .max) <= 5_000_000 else { return .missing }
                    return .data(try Data(contentsOf: url))
                } catch CocoaError.fileReadNoPermission {
                    blockedPaths.withLock { _ = $0.insert(path) }
                    return .blocked
                } catch {
                    return .missing
                }
            }
        )
    }

    /// Extension rules name VS Code's settings file. In another editor the same extension follows that editor's own file.
    func forEditor(_ folder: String) -> Probe {
        var copy = self
        let code = "~/Library/Application Support/Code/"
        copy.file = { [file] path in file(path.hasPrefix(code) ? "~/Library/Application Support/\(folder)/\(path.dropFirst(code.count))" : path) }
        return copy
    }

    /// Files macOS refused to let the app read. Persisted by the app so the refusal, and the system
    /// notification that comes with it, happens once rather than at every launch. Clear it to try again.
    public static var blockedFiles: Set<String> {
        get { blockedPaths.withLock { $0 } }
        set { blockedPaths.withLock { $0 = newValue } }
    }
}

private let blockedPaths = Mutex<Set<String>>([])

/// Looks up `key` first as a literal top-level key (VS Code style "a.b.c"), then as a dot path. Booleans read as "true"/"false".
func jsonValue(in data: Data, key: String) -> String? {
    // json5Allowed accepts the comments and trailing commas editors allow in settings files.
    guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else { return nil }
    var value: Any? = root[key]
    if value == nil {
        value = key.split(separator: ".").reduce(root as Any?) { node, part in (node as? [String: Any])?[String(part)] }
    }
    switch value {
    case let string as String: return string
    case let number as NSNumber: return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
    default: return nil
    }
}

/// Only http(s) links from rules and AI lookups are ever made clickable.
public func safeURL(_ string: String?) -> URL? {
    guard let string, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    return url
}

/// What the list shows for one item, and where that judgement came from.
public struct Verdict: Sendable, Equatable {
    public enum Source: String, Sendable { case rules, ai, sdk, none }
    public var status: Status
    public var state: String
    public var rule: Rule?
    public var source: Source

    /// Curated rules win over AI lookups. Without either the item is unknown; SDK scan hits only add a hint.
    public init(item: Item, rules: [Rule], aiRules: [String: Rule], sdks: [String], probe: Probe) {
        func judge(_ rule: Rule) -> (Status, String) {
            guard !item.editors.isEmpty else { return rule.evaluate(probe) }
            // Green only when every editor that has the extension is off: show the first one that is not.
            let results = item.editors.map { (editor: $0, result: rule.evaluate(probe.forEditor($0))) }
            // Failing that, one whose setting macOS would not let the app read, so that note is not lost.
            let shown = results.first { $0.result.status != .ok } ?? results.first { $0.result.state.contains(Rule.blockedNote) } ?? results[0]
            let editor = shown.editor == "Code" ? "VS Code" : shown.editor
            let notable = shown.result.status != .ok || shown.result.state.contains(Rule.blockedNote)
            return (shown.result.status, results.count > 1 && notable ? "In \(editor): \(shown.result.state)" : shown.result.state)
        }
        // shortcut: an extension with a different version per editor is judged by the first editor's version; pick per editor if an extension ever gets version files.
        let found = Rule.pick(rules.filter({ $0.match.contains(item.id) }), version: item.version).map { (rule: $0, result: judge($0)) }
        let severity = { (status: Status) in [Status.ok, .unknown, .warn, .bad].firstIndex(of: status) ?? 0 }
        // Several findings may hold: show the worst, and the newest of equally bad ones.
        if let worst = found.map({ severity($0.result.0) }).max(), let shown = found.last(where: { severity($0.result.0) == worst }) {
            (status, state) = shown.result
            if found.count > 1 { state += " " + Rule.unsureNote }
            (rule, source) = (shown.rule, .rules)
        } else if let rule = aiRules[item.id] {
            (status, state) = judge(rule)
            (self.rule, source) = (rule, .ai)
        } else if !sdks.isEmpty {
            // A string match is a lead, not evidence: bundled dependencies and domain lists contain these names too. So it stays grey.
            (status, state, rule, source) = (.unknown, "Not in the App Checker findings. Its files mention \(sdks.joined(separator: ", ")). That is a hint worth looking up, not proof of telemetry.", nil, .sdk)
        } else {
            (status, state, rule, source) = (.unknown, "Nothing is known about this item yet.", nil, .none)
        }
    }
}
