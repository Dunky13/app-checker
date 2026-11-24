import Foundation
import Synchronization

public enum Status: String, Codable, Sendable, CaseIterable {
    case bad, warn, ok, unknown
}

public enum Telemetry: String, Codable, Sendable {
    case none, optIn = "opt-in", optOut = "opt-out", forced, unknown
}

/// A read-only test of local state. Exactly one of `env`, `defaults`, `json`, `file` is set.
/// There is deliberately no command form: rules are refreshed from the network and must never execute anything.
public struct Check: Codable, Sendable, Hashable {
    public var env, defaults, json, file, key, equals, contains: String?

    public var isWellFormed: Bool {
        switch (env, defaults, json, file) {
        case (.some, nil, nil, nil): key == nil && contains == nil
        case (nil, .some, nil, nil), (nil, nil, .some, nil): key != nil && contains == nil
        case (nil, nil, nil, .some): contains != nil && key == nil && equals == nil
        default: false
        }
    }

    /// true or false when the setting could be read, nil when macOS privacy protection blocked the read.
    public func result(_ probe: Probe) -> Bool? {
        func matches(_ value: String?) -> Bool {
            guard let value else { return false }
            return equals.map { $0 == value } ?? !value.isEmpty
        }
        if let env { return matches(probe.env[env]) }
        if let defaults, let key { return matches(probe.defaults(defaults, key)) }
        guard let path = json ?? file else { return false }
        switch probe.file(path) {
        case .blocked: return nil
        case .missing: return false
        case let .data(data):
            if let key { return matches(jsonValue(in: data, key: key)) }
            return contains.map { String(decoding: data, as: UTF8.self).contains($0) } ?? false
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

    /// Maps the rule plus this Mac's current settings to a status and a one-line explanation.
    public func evaluate(_ probe: Probe) -> (status: Status, state: String) {
        switch telemetry {
        case .none: return (.ok, "No telemetry.")
        case .forced: return (.bad, "Telemetry is on and cannot be switched off.")
        case .unknown: return (.unknown, "Telemetry behaviour could not be determined.")
        case .optOut:
            let results = (disabledWhen ?? []).map { $0.result(probe) }
            if results.contains(true) { return (.ok, "Telemetry is switched off on this Mac.") }
            if results.contains(nil) { return (.warn, "Telemetry is on by default. \(Self.blockedNote)") }
            return (.warn, results.isEmpty
                ? "Telemetry is on by default. The current setting cannot be read from this Mac."
                : "Telemetry is on. You can switch it off.")
        case .optIn:
            let results = (enabledWhen ?? []).map { $0.result(probe) }
            if results.contains(true) { return (.warn, "Telemetry has been switched on. You can switch it off.") }
            return (.ok, "Telemetry stays off unless you enable it." + (results.contains(nil) ? " \(Self.blockedNote)" : ""))
        }
    }

    static let blockedNote = "macOS did not let App Checker read this app's setting. To allow it, open System Settings > Privacy & Security > Files & Folders, then rescan."
}

public struct RuleSet: Codable, Sendable {
    public static let supportedVersion = 1
    public var version: Int
    public var rules: [Rule]

    public static func decode(_ data: Data) throws -> RuleSet {
        let set = try JSONDecoder().decode(RuleSet.self, from: data)
        guard set.version <= supportedVersion else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Rules version \(set.version) needs a newer App Checker."])
        }
        return set
    }
}

/// Local state the checks read. Injected so the rule engine is testable.
public struct Probe: Sendable {
    public var env: [String: String]
    public var defaults: @Sendable (_ domain: String, _ key: String) -> String?
    public var file: @Sendable (_ path: String) -> FileRead

    public enum FileRead: Sendable { case data(Data), missing, blocked }

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
                let path = NSString(string: path).expandingTildeInPath, url = URL(fileURLWithPath: path)
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
        if let rule = rules.first(where: { $0.match.contains(item.id) }) {
            (status, state) = rule.evaluate(probe)
            (self.rule, source) = (rule, .rules)
        } else if let rule = aiRules[item.id] {
            (status, state) = rule.evaluate(probe)
            (self.rule, source) = (rule, .ai)
        } else if !sdks.isEmpty {
            // A string match is a lead, not evidence: bundled dependencies and domain lists contain these names too. So it stays grey.
            (status, state, rule, source) = (.unknown, "Not in the rules database. Its files mention \(sdks.joined(separator: ", ")). That is a hint worth looking up, not proof of telemetry.", nil, .sdk)
        } else {
            (status, state, rule, source) = (.unknown, "Nothing is known about this item yet.", nil, .none)
        }
    }
}
