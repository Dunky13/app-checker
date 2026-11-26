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

    /// Control and formatting characters and every kind of line break, including the Unicode separators.
    static func hasHiddenCharacters(_ text: String) -> Bool { text.unicodeScalars.contains(where: CharacterSet.controlCharacters.union(.newlines).contains) }

    public var isWellFormed: Bool {
        // Every field is shown to people and can end up in a public issue, so nothing invisible and no line breaks.
        // Only `contains` may span lines: a setting below its section header in a config file.
        let fields = [env, defaults, json, file, key, equals, contains?.replacingOccurrences(of: "\n", with: "")].compactMap(\.self) + (notIn ?? [])
        guard !fields.contains(where: Self.hasHiddenCharacters) else { return false }
        return switch (env, defaults, json, file) {
        case let (.some(name), nil, nil, nil): Self.isName(name) && key == nil && contains == nil && (equals == nil || notIn == nil)
        // A stored false reads as "0" or "false", so "any value" would mistake it for a switch that is on.
        case (nil, .some, nil, nil): key != nil && equals != nil && contains == nil && notIn == nil
        case let (nil, nil, .some(path), nil): key != nil && equals != nil && contains == nil && notIn == nil && Self.isReadable(path)
        case let (nil, nil, nil, .some(path)): contains != nil && key == nil && equals == nil && notIn == nil && Self.isReadable(path)
        default: false
        }
    }

    /// What a shell accepts as the name of a variable.
    static func isName(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && text.first?.isNumber != true
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
    /// Off only when every group holds, each by any one of its checks: for products with several switches that all have to be off.
    public var disabledWhenAll: [[Check]]?
    public var enabledWhen: [Check]?
    public var sources: [String]?
    /// The first version this finding applies to. Comes from the file name only: it is not read from a file or an AI answer.
    public var since: String?
    private enum CodingKeys: String, CodingKey { case match, name, telemetry, summary, policyURL, optOut, disabledWhen, disabledWhenAll, enabledWhen, sources }

    static let unsureNote = "The installed version does not say which finding applies, so the strictest one is shown."

    /// The findings that may hold for `version` among those for one item, oldest first. Normally that is one:
    /// the newest that starts at or below it. When the version cannot say, every finding that might hold comes back
    /// and the caller shows the worst: all of them for a version that cannot be read, and any whose start has no known
    /// order with it: another pre-release channel of the same release, or a number after a dash on either side.
    public static func pick(_ candidates: [Rule], version: String) -> [Rule] {
        let start = { (rule: Rule) in rule.since.flatMap(Version.init) ?? .zero }
        let sorted = candidates.sorted { start($0) < start($1) }
        guard let version = Version(version) else { return sorted }
        let unsure = { (rule: Rule) in version.isOnAnotherChannel(than: start(rule)) }
        let known = sorted.indices.filter { !unsure(sorted[$0]) }
        // A number after a dash is a pre-release for npm and a later build elsewhere, and nothing says which an item uses.
        // So the version and the files are read both ways, and each reading adds the file it picks.
        let certain = [\Version.self, \Version.asPreRelease].map { reading in
            let place = { (index: Int) in start(sorted[index])[keyPath: reading] }
            // A version below every file, such as "0.0.0-dev", gets the first file: no version may be left without a finding.
            return known.filter { place($0) <= version[keyPath: reading] }.max { place($0) < place($1) } ?? known.first { start(sorted[$0]) == .zero }
        }
        // What follows the numbers is not always a pre-release: "5.4.0-0ubuntu1" is a packager's build of 5.4.0, and "9.9p2"
        // and "1.1.1w" are patch levels. Only a known pre-release word says "before", so otherwise the file for exactly
        // that release may hold as well.
        let labelled = { (rule: Rule) in
            let file = start(rule)
            let patched = version.release == file.release && version.pre.first.map { !Version.preReleaseWords.contains($0) } == true
            return file.pre.isEmpty && (version.base == file.release || patched)
        }
        return sorted.enumerated().filter { certain.contains($0.offset) || unsure($0.element) || labelled($0.element) }.map(\.element)
    }

    /// What is wrong with this rule, first problem first. Every rule passes through here before it is used:
    /// bundled and downloaded ones as `curated`, AI answers with the safety checks only.
    public func problems(curated: Bool) -> [String] {
        var found: [String] = []
        if match.isEmpty || !match.allSatisfy({ id in ["app", "brew", "cask", "bin", "npm", "ext"].contains { id.hasPrefix("\($0):") } }) {
            found.append("match needs ids starting with app:, brew:, cask:, bin:, npm: or ext:")
        }
        if !((disabledWhen ?? []) + (disabledWhenAll ?? []).flatMap(\.self) + (enabledWhen ?? [])).allSatisfy(\.isWellFormed) { found.append("malformed check") }
        // An empty combination would hold without reading anything.
        if let all = disabledWhenAll, all.isEmpty || all.contains(where: \.isEmpty) { found.append("disabledWhenAll has an empty list") }
        // The command is offered for copying and, after a confirmation that shows it, for running, so nothing invisible (control or formatting characters, line breaks) may ride along.
        if optOut?.command.map(Check.hasHiddenCharacters) == true {
            found.append("the command contains hidden characters or line breaks")
        }
        // Yellow promises a way out, so an opt-out verdict without one is not usable.
        if [.optOut, .optIn].contains(telemetry), (optOut?.instructions ?? "").isEmpty { found.append("the steps to switch it off are missing") }
        guard curated else { return found }
        if telemetry == .unknown { found.append(Self.unknownProblem) }
        if summary.isEmpty { found.append("the summary of what is collected is missing") }
        if (sources ?? []).isEmpty { found.append("Sources has no link") }
        if [.optOut, .optIn].contains(telemetry), (optOut?.url ?? "").isEmpty { found.append("Documentation has no link") }
        // The command: plain ASCII, so its end cannot sit behind a screen of blanks or stacked marks.
        if let command = optOut?.command,
           !command.allSatisfy(\.isASCII) || command.unicodeScalars.count > 300 || command.contains("  ") || command.contains("\t") {
            found.append("the command is not plain ASCII, is longer than 300 characters, or is padded with spaces")
        }
        // Links last: there can be many, and the form shows only the first few problems.
        // A curated link is read once, by whoever reviews the finding. After that it is a label to click.
        // So its host is written in plain letters, digits, dots and hyphens: no user name before it, no escape, no look-alike letter.
        // Named as the submit form labels the field, so a person knows where to look.
        let links = [("Privacy policy", policyURL), ("Documentation", optOut?.url)].compactMap { field, link in link.map { (field, $0) } }
            + (sources ?? []).map { ("Sources", $0) }
        // An empty link is reported as missing above, not again here.
        for (field, link) in links where !link.isEmpty && !Self.isPlainLink(link) {
            found.append("not a plain https link in \(field): \(link.prefix(200))")
        }
        return found
    }

    /// Maps the rule plus this Mac's current settings to a status and a one-line explanation, and whether a setting
    /// read on this Mac decided it: not when the finding has nothing to read, when macOS refused the read, or when an
    /// opt-out finding read only an unset "on" switch.
    public func evaluate(_ probe: Probe) -> (status: Status, state: String, read: Bool) {
        switch telemetry {
        case .none: return (.ok, "No telemetry.", false)
        case .forced: return (.bad, "Telemetry is on and cannot be switched off.", false)
        case .unknown: return (.unknown, "Telemetry behaviour could not be determined.", false)
        case .optOut:
            // An explicit "on" switch beats every "off" switch, as with gh: GH_TELEMETRY=enabled overrides DO_NOT_TRACK.
            let forced = (enabledWhen ?? []).map { $0.result(probe) }
            if forced.contains(true) { return (.warn, "A setting on this Mac switches telemetry on. You can switch it off.", true) }
            // An "on" switch that could not be read may still be set, so it must not end in green.
            if forced.contains(nil) { return (.warn, "Telemetry is on by default. \(Self.blockedNote)", false) }
            // A combination counts as one more "off" switch: a group with no match rules it out, one that could not be read leaves it open.
            let groups = (disabledWhenAll ?? []).map { group in
                let found = group.map { $0.result(probe) }
                return found.contains(true) ? true : found.contains(nil) ? nil : false
            }
            let all: [Bool?] = groups.isEmpty ? [] : [groups.contains(false) ? false : groups.contains(nil) ? nil : true]
            let results = (disabledWhen ?? []).map { $0.result(probe) } + all
            if results.contains(true) { return (.ok, "Telemetry is switched off on this Mac.", true) }
            if results.contains(nil) { return (.warn, "Telemetry is on by default. \(Self.blockedNote)", false) }
            // Only an "on" switch that is not set: the state is the default, not a reading of the "off" switch.
            return results.isEmpty
                ? (.warn, "Telemetry is on by default. The current setting cannot be read from this Mac.", false)
                : (.warn, "No opt-out setting was found on this Mac, so telemetry is on by default. You can switch it off.", true)
        case .optIn:
            let results = (enabledWhen ?? []).map { $0.result(probe) }
            if results.contains(true) { return (.warn, "Telemetry has been switched on. You can switch it off.", true) }
            if results.contains(nil) { return (.ok, "Telemetry stays off unless you enable it. \(Self.blockedNote)", false) }
            return results.isEmpty
                ? (.ok, "Telemetry is off unless you agreed to it. Kanarie cannot read that choice on this Mac.", false)
                : (.ok, "Telemetry stays off unless you enable it.", true)
        }
    }

    static let unknownProblem = "unknown telemetry does not belong in the curated rules"

    static func isPlainLink(_ link: String) -> Bool {
        let host = link.dropFirst("https://".count).prefix { !"/?#".contains($0) }
        return safeURL(link) != nil && link.hasPrefix("https://") && link.allSatisfy(\.isASCII) && !host.isEmpty
            && host.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) })
    }

    /// The link with its scheme written as plain https, when that alone makes it plain: "http://" and "HTTPS://" are the
    /// common slips. The host is never changed, since its rule keeps look-alike links out, and a link with a port is
    /// left alone: http on port 80 is not https on port 80.
    public static func plainLink(_ link: String) -> String? {
        guard let colon = link.firstIndex(of: ":"), ["http", "https"].contains(link[..<colon].lowercased()) else { return nil }
        let fixed = "https" + link[colon...]
        return fixed != link && isPlainLink(fixed) && URL(string: fixed)?.port == nil ? fixed : nil
    }

    /// This rule with every link that `plainLink` can fix fixed, and nothing else changed.
    public func withPlainLinks() -> Rule {
        let fix = { (link: String) in Self.plainLink(link.trimmingCharacters(in: .whitespaces)) ?? link }
        var rule = self
        (rule.policyURL, rule.sources) = (policyURL.map(fix), sources?.map(fix))
        rule.optOut?.url = optOut?.url.map(fix)
        return rule
    }

    static let blockedNote = "macOS did not let Kanarie read this app's setting. To allow it, open System Settings > Privacy & Security > Files & Folders, then rescan."
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

    /// Whether the state was read from this Mac: a setting that decided it, or a search of its files.
    /// Not when macOS refused the read, nor when an opt-out finding read only an unset "on" switch: then the state is the finding's default.
    public var readsThisMac: Bool

    /// Curated rules win over AI lookups. Without either the item is unknown; SDK scan hits only add a hint.
    public init(item: Item, rules: [Rule], aiRules: [String: Rule], sdks: [String], probe: Probe) {
        func judge(_ rule: Rule) -> (status: Status, state: String, read: Bool) {
            guard !item.editors.isEmpty else { return rule.evaluate(probe) }
            // Green only when every editor that has the extension is off: show the first one that is not.
            let results = item.editors.map { (editor: $0, result: rule.evaluate(probe.forEditor($0))) }
            // Failing that, one whose setting macOS would not let the app read, so that note is not lost.
            let shown = results.first { $0.result.status != .ok } ?? results.first { $0.result.state.contains(Rule.blockedNote) } ?? results[0]
            let editor = shown.editor == "Code" ? "VS Code" : shown.editor
            let notable = shown.result.status != .ok || shown.result.state.contains(Rule.blockedNote)
            return (shown.result.status, results.count > 1 && notable ? "In \(editor): \(shown.result.state)" : shown.result.state, shown.result.read)
        }
        // shortcut: an extension with a different version per editor is judged by the first editor's version; pick per editor if an extension ever gets version files.
        let found = Rule.pick(rules.filter({ $0.match.contains(item.id) }), version: item.version).map { (rule: $0, result: judge($0)) }
        let severity = { (status: Status) in [Status.ok, .unknown, .warn, .bad].firstIndex(of: status) ?? 0 }
        // Several findings may hold: show the worst, and the newest of equally bad ones.
        if let worst = found.map({ severity($0.result.status) }).max(), let shown = found.last(where: { severity($0.result.status) == worst }) {
            (status, state, readsThisMac) = shown.result
            if found.count > 1 { state += " " + Rule.unsureNote }
            (rule, source) = (shown.rule, .rules)
        } else if let rule = aiRules[item.id] {
            (status, state, readsThisMac) = judge(rule)
            (self.rule, source) = (rule, .ai)
        } else if !sdks.isEmpty {
            // A string match is a lead, not evidence: bundled dependencies and domain lists contain these names too. So it stays grey.
            readsThisMac = true
            (status, state, rule, source) = (.unknown, "Not in the Kanarie findings. A search of its files found \(sdks.joined(separator: ", ")). That is a hint worth looking up, not proof of telemetry.", nil, .sdk)
        } else {
            readsThisMac = false
            (status, state, rule, source) = (.unknown, "Nothing is known about this item yet.", nil, .none)
        }
    }
}
