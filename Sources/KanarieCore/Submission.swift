import Foundation

/// A finding someone proposes from the app. It leaves the Mac only as a prefilled GitHub issue that the person
/// reads and submits in their own browser: the app has no server of its own and no GitHub login.
public enum Submission {
    static let issues = "https://github.com/Dunky13/kanarie/issues/new"

    /// The fields of the form.
    /// shortcut: checks that came with an AI lookup or a curated finding are kept or dropped as a whole, and by hand only one variable can be added; give checks their own editor if submissions need more.
    public struct Draft: Hashable, Sendable {
        public var telemetry = Telemetry.optOut
        public var name = "", summary = "", policyURL = "", instructions = "", command = "", optOutURL = "", sources = ""
        /// A variable that switches telemetry off, for a finding that has no checks yet.
        public var variable = "", value = ""
        /// Drops the checks of the finding this draft started from, so the person can name the variable instead.
        public var replaceChecks = false
        var base: Rule?

        public init(from rule: Rule?, item: Item) {
            (base, name) = (rule, rule?.name ?? item.name)
            guard let rule else { return }
            // An AI lookup that could not tell stays so: any class here would be a claim the lookup did not make.
            telemetry = rule.telemetry
            (summary, policyURL, sources) = (rule.summary, rule.policyURL ?? "", (rule.sources ?? []).joined(separator: "\n"))
            (instructions, command, optOutURL) = (rule.optOut?.instructions ?? "", rule.optOut?.command ?? "", rule.optOut?.url ?? "")
        }

        /// The checks of the finding this draft started from. They were written for its telemetry class, so another class drops them.
        var kept: (off: [Check], on: [Check]) {
            guard let base, !replaceChecks, base.telemetry == telemetry, [.optOut, .optIn].contains(telemetry) else { return ([], []) }
            return (base.disabledWhen ?? [], base.enabledWhen ?? [])
        }

        public var checks: [String] { kept.off.map { describe($0) + " switches it off" } + kept.on.map { describe($0) + " switches it on" } }

        public func rule(for item: Item) -> Rule {
            let text = { (field: String) in field.trimmingCharacters(in: .whitespacesAndNewlines) }
            let optional = { (field: String) in text(field).isEmpty ? nil : text(field) }
            // A correction keeps every item the curated finding covers.
            var rule = Rule(match: base?.since == nil ? [item.id] : base?.match ?? [item.id], telemetry: telemetry, summary: text(summary))
            // A correction also says which of the item's findings it corrects.
            (rule.name, rule.policyURL, rule.since) = (optional(name), optional(policyURL), base?.since)
            rule.sources = sources.split(whereSeparator: \.isNewline).map { text(String($0)) }.filter { !$0.isEmpty }
            // Still "could not tell": keep the lookup's steps, which the form does not show for this class.
            if telemetry == .unknown, base?.telemetry == .unknown { rule.optOut = base?.optOut }
            guard [.optOut, .optIn].contains(telemetry) else { return rule }
            rule.optOut = OptOut(instructions: text(instructions), command: optional(command), url: optional(optOutURL))
            var off = kept.off
            if off.isEmpty, kept.on.isEmpty, telemetry == .optOut, let variable = optional(variable) { off = [Check(env: variable, equals: optional(value))] }
            (rule.disabledWhen, rule.enabledWhen) = (off.isEmpty ? nil : off, kept.on.isEmpty ? nil : kept.on)
            return rule
        }

        /// The draft with each link that `Rule.plainLink` can fix fixed. Every other field stays as typed.
        public var withPlainLinks: Draft {
            let fix = { (field: String) in
                field.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { Rule.plainLink($0.trimmingCharacters(in: .whitespaces)) ?? String($0) }.joined(separator: "\n")
            }
            var draft = self
            (draft.policyURL, draft.optOutURL, draft.sources) = (fix(policyURL), fix(optOutURL), fix(sources))
            return draft
        }

        /// What keeps this draft from being a usable finding: the checks every curated finding passes, on the submitter's Mac already.
        public func problems(for item: Item) -> [String] {
            // Only where the field is in use: with another telemetry class or with kept checks it is not shown.
            let name = telemetry == .optOut && kept.off.isEmpty && kept.on.isEmpty ? variable.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            // Before the finding's own problems, which end with the links: the form shows only the first few.
            // Named as the form shows it: the finding's own message names the JSON value.
            let own = rule(for: item).problems(curated: true).map { $0 == Rule.unknownProblem ? "choose what Telemetry is: a finding cannot say Could not tell" : $0 }
            return (name.isEmpty || Check.isName(name) ? [] : ["the variable is a name only, such as EXAMPLE_TELEMETRY; its value goes in the other field"]) + own
        }
    }

    static func describe(_ check: Check) -> String {
        if let name = check.env {
            return "variable \(name)" + (check.equals.map { " = \($0)" } ?? check.notIn.map { " set to anything but \($0.joined(separator: ", "))" } ?? " set")
        }
        if let domain = check.defaults { return "preference \(domain) \(check.key ?? "") = \(check.equals ?? "")" }
        if let path = check.json { return "\(path): \(check.key ?? "") = \(check.equals ?? "")" }
        return "\(check.file ?? "") contains \(check.contains ?? "")"
    }

    /// What the finding's checks read on this Mac: evidence that the switch can be read at all.
    /// Only whether a check matched is reported, never the value it read.
    public static func readings(_ rule: Rule, item: Item, probe: Probe) -> [String] {
        // An extension is read in every editor that has it, as the verdict does.
        let places = item.editors.isEmpty ? [("", probe)] : item.editors.map {
            (item.editors.count > 1 ? "In \($0 == "Code" ? "VS Code" : $0): " : "", probe.forEditor($0))
        }
        let lines = { (checks: [Check]?, role: String) in
            places.flatMap { place, local in
                (checks ?? []).map { "\(place)\(describe($0)) (\(role)): " + ($0.result(local).map { $0 ? "matches" : "does not match" } ?? "could not be read") }
            }
        }
        var alone = rule
        alone.since = nil
        let verdict = Verdict(item: item, rules: [alone], aiRules: [:], sdks: [], probe: probe)
        let colour = [Status.ok: "green", .warn: "yellow", .bad: "red", .unknown: "grey"][verdict.status] ?? ""
        return lines(rule.disabledWhen, "switches it off") + lines(rule.enabledWhen, "switches it on") + ["Verdict with this finding: \(colour). \(verdict.state)"]
    }

    /// A lookup as a bulk submission sends it: for this item, written as the form writes it, and only when the form
    /// changes nothing more than that, so that "not edited" holds. The form trims text, leaves empty fields out and fills
    /// in a missing name, all of which keep the finding; it also drops steps and checks the telemetry class does not use,
    /// and adds empty steps to an opt-out without any, which change it.
    public static func unedited(_ found: Rule, item: Item) -> Rule? {
        let text = { (field: String) in field.trimmingCharacters(in: .whitespacesAndNewlines) }
        let optional = { (field: String?) in field.map(text).flatMap { $0.isEmpty ? nil : $0 } }
        var sent = found
        (sent.match, sent.name, sent.summary, sent.policyURL) = ([item.id], optional(found.name) ?? item.name, text(found.summary), optional(found.policyURL))
        sent.sources = (found.sources ?? []).joined(separator: "\n").split(whereSeparator: \.isNewline).map { text(String($0)) }.filter { !$0.isEmpty }
        sent.optOut = found.optOut.map { OptOut(instructions: text($0.instructions), command: optional($0.command), url: optional($0.url)) }
        // A lookup writes "no checks" as an empty list, the form leaves the field out: the same finding.
        (sent.disabledWhen, sent.enabledWhen) = (found.disabledWhen?.isEmpty == false ? found.disabledWhen : nil, found.enabledWhen?.isEmpty == false ? found.enabledWhen : nil)
        return Draft(from: found, item: item).rule(for: item) == sent ? sent : nil
    }

    /// Whether the names a finding relies on appear literally on the pages it cites.
    /// An invented variable or settings key is the main risk of an AI lookup, and this catches it without trusting anyone.
    public struct SourceCheck: Hashable, Sendable {
        public var found: [String], missing: [String], fetched: Int, cited: Int

        public var lines: [String] {
            let list = { (names: [String]) in names.map { "`\(plain($0))`" }.joined(separator: ", ") }
            return ["Fetched \(fetched) of \(cited) cited pages." + (cited > pageLimit ? " Only the first \(pageLimit) are fetched." : "")]
                + (found.isEmpty && missing.isEmpty ? ["The finding names no variable or setting, so there was nothing to look for."] : [])
                + (found.isEmpty ? [] : ["Found on a cited page: \(list(found))."])
                + (missing.isEmpty ? [] : ["Not found on any cited page: \(list(missing))."])
        }
    }

    public static func sourceCheck(_ rule: Rule, pages: [String], cited: Int) -> SourceCheck {
        var names = ((rule.disabledWhen ?? []) + (rule.enabledWhen ?? [])).compactMap { $0.env ?? $0.key ?? $0.contains }
        // Variables and preference keys in the command count too: that line is copied straight into a shell.
        let command = rule.optOut?.command ?? ""
        // The simple kind of word boundary: the default one does not see a boundary at "." or ":" between letters ("$env:NAME").
        names += command.matches(of: /\b[A-Z][A-Z0-9]*_[A-Z0-9_]+/.wordBoundaryKind(.simple)).map { String($0.output) }
        names += command.matches(of: /(?:^|[\s'";])([A-Za-z_]\w*)=/).map { String($0.output.1) }
        names += command.matches(of: /defaults\s+write\s+\S+\s+["']?([\w.-]+)/).map { String($0.output.1) }
        names = names.enumerated().filter { !$0.element.isEmpty && names.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        let found = names.filter { name in pages.contains { mentions($0, name) } }
        return SourceCheck(found: found, missing: names.filter { !found.contains($0) }, fetched: pages.count, cited: cited)
    }

    /// Whether a page has the name as a whole, not as part of a longer one: TELEMETRY is not in EXAMPLE_TELEMETRY_OFF.
    static func mentions(_ page: String, _ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let inWord = { (character: Character?) in character.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false }
        let pattern = (inWord(name.first) ? "(?<![\\p{L}\\p{N}_])" : "") + NSRegularExpression.escapedPattern(for: name) + (inWord(name.last) ? "(?![\\p{L}\\p{N}_])" : "")
        return page.range(of: pattern, options: .regularExpression) != nil
    }

    static let pageLimit = 8

    /// The text of the pages a finding cites. A page that cannot be fetched, or is not served over HTTPS from a public address, is left out, and `cited` says how many there were.
    public static func pages(for rule: Rule) async -> (texts: [String], cited: Int) {
        let links = ((rule.sources ?? []) + [rule.optOut?.url].compactMap(\.self)).compactMap { safeURL($0) }
        let urls = links.enumerated().filter { links.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        let configuration = URLSessionConfiguration.ephemeral
        // The first stops a server that goes quiet, the second one that keeps sending a byte now and then.
        (configuration.timeoutIntervalForRequest, configuration.timeoutIntervalForResource) = (20, 20)
        let session = URLSession(configuration: configuration, delegate: PublicOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }   // a session keeps its delegate until it is told to let go
        // No page is started after a minute, so eight slow pages cannot keep the form waiting for eight times the limit.
        let deadline = Date.now.addingTimeInterval(60)
        var texts: [String] = []
        for url in urls.prefix(pageLimit) where !Task.isCancelled && Date.now < deadline && mayFetch(url) {
            if let data = try? await session.data(from: url, limit: 3_000_000) { texts.append(String(decoding: data, as: UTF8.self)) }
        }
        return (texts, urls.count)
    }

    /// Whether a cited page may be fetched. The links come from an AI lookup or a form, so they must not make this Mac
    /// ask itself or its own network: a router or a local service answers a request too.
    /// HTTPS covers the time between this lookup and the fetch: a host that answers with a local address by then has no
    /// certificate for its name there, so the request itself is never sent. A connection attempt can still reach that
    /// address, which is why only the standard port is allowed: other ports are where printers and admin pages listen.
    static func mayFetch(_ url: URL?) -> Bool { url?.scheme?.lowercased() == "https" && (url?.port ?? 443) == 443 && isPublic(url?.host) }

    /// Whether every address of a host is on the public internet.
    static func isPublic(_ host: String?) -> Bool {
        var hints = addrinfo(), list: UnsafeMutablePointer<addrinfo>?
        hints.ai_socktype = SOCK_STREAM
        guard let host, getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return false }
        defer { freeaddrinfo(list) }
        return sequence(first: first, next: { $0.pointee.ai_next }).allSatisfy { info in
            switch info.pointee.ai_family {
            case AF_INET: isPublic(address: info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } })
            case AF_INET6: isPublic(address: info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } })
            default: false
            }
        }
    }

    static func isPublic(address bytes: [UInt8]) -> Bool {
        if bytes.count == 16 {
            // An IPv4 address inside an IPv6 one is judged as IPv4: ::ffff:a.b.c.d, ::a.b.c.d, the NAT64 prefix 64:ff9b:: and 6to4 (2002:).
            let embedded = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == bytes[11] && [0, 0xff].contains(bytes[10])
                || Array(bytes.prefix(12)) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
            if embedded { return isPublic(address: Array(bytes[12...])) }
            if bytes[0] == 0x20, bytes[1] == 0x02 { return isPublic(address: Array(bytes[2..<6])) }
            // Everything else must be a global address (2000::/3), which leaves out loopback, link-local, private and multicast,
            // and not a range set aside for protocols (2001::/23, which holds Teredo, a tunnel to an IPv4 address)
            // or for documentation (2001:db8::/32 and 3fff::/20).
            let reserved = bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8))
                || bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] < 0x10
            return bytes[0] & 0xe0 == 0x20 && !reserved
        }
        switch (bytes[0], bytes[1], bytes[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _), (100, 64...127, _), (172, 16...31, _), (198, 18...19, _), (224..., _, _): return false
        case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113): return false   // protocol assignments and documentation
        default: return true
        }
    }

    /// Keeps a cited page from redirecting to a link that `mayFetch` refuses.
    final class PublicOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            mayFetch(request.url) ? request : nil
        }
    }

    /// One finding of an issue, with what was read and checked for it.
    public struct Entry: Sendable {
        public var item: Item, rule: Rule, origin: String, readings: [String]?, sourceCheck: SourceCheck, removed: Bool
        public init(item: Item, rule: Rule, origin: String, readings: [String]?, sourceCheck: SourceCheck, removed: Bool = false) {
            (self.item, self.rule, self.origin, self.readings, self.sourceCheck, self.removed) = (item, rule, origin, readings, sourceCheck, removed)
        }
    }

    struct TooMany: LocalizedError {
        var errorDescription: String? { "One issue holds from 1 to \(bulkLimit) findings." }
    }

    /// The most findings one issue holds. Each can fetch up to `pageLimit` pages, and the maintainer reads them all.
    public static let bulkLimit = 10

    /// The folder a new finding is proposed for, below findings/. A name without ASCII letters gives no folder name, so
    /// the id without its prefix stands in; nil when neither has any.
    public static func folder(for item: Item, rule: Rule) -> String? {
        let slug = { (text: String) in text.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.joined(separator: "-") }
        return [rule.name ?? item.name, String(item.id.drop { $0 != ":" })].map(slug).first { !$0.isEmpty }
    }

    /// The prefilled GitHub issue. A body too long for a link comes back as `clipboard`, and the issue then asks to paste it.
    /// `readings` is nil when they must stay on the Mac: see `SubmitView`. `removed`: the item is no longer installed.
    public static func issue(item: Item, rule: Rule, origin: String, readings: [String]?, sourceCheck: SourceCheck, appVersion: String, removed: Bool = false) throws -> (url: URL, clipboard: String?) {
        try issue([Entry(item: item, rule: rule, origin: origin, readings: readings, sourceCheck: sourceCheck, removed: removed)], appVersion: appVersion)
    }

    /// One issue for several findings, each in a section headed "### Finding <n>", which is how scripts/accept-finding.py
    /// tells them apart. One finding gets no heading.
    public static func issue(_ entries: [Entry], appVersion: String) throws -> (url: URL, clipboard: String?) {
        guard let first = entries.first, entries.count <= bulkLimit else { throw TooMany() }
        let sections = try entries.map(section)
        let several = entries.count > 1
        let body = (several ? "\(entries.count) findings, each in a section of its own.\n\n" : "")
            + (several ? sections.enumerated().map { "### Finding \($0.offset + 1)\n\n\($0.element)" } : sections).joined(separator: "\n\n")
            + "\n\nSent from Kanarie \(plain(appVersion)). "
            + (several ? "The findings passed the app's format and safety checks. Whether they are true is for review." : "The finding passed the app's format and safety checks. Whether it is true is for review.")
        let names = entries.map { plain($0.rule.name ?? $0.item.name) }
        // GitHub cuts a title at 256 characters: the names that fit, and how many more there are.
        let fit = (1...names.count).last { names.prefix($0).joined(separator: ", ").count <= 180 } ?? 1
        let title = several
            ? "Findings: " + names.prefix(fit).joined(separator: ", ") + (fit < names.count ? " and \(names.count - fit) more" : "")
            : "Finding: \(plain(first.rule.name ?? first.item.name))"
        func url(_ body: String) throws -> URL {
            guard var components = URLComponents(string: issues) else { throw URLError(.badURL) }
            components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            // URLComponents leaves "+" as it is, and GitHub would read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else { throw URLError(.badURL) }
            return url
        }
        let link = try url(body)
        // GitHub answers a longer address with an error page.
        guard link.absoluteString.utf8.count > 7000 else { return (link, nil) }
        return (try url(several ? "Paste the findings here: Kanarie put them on your clipboard." : "Paste the finding here: Kanarie put it on your clipboard."), body)
    }

    /// The part of an issue about one finding: the item, where the finding goes, the finding, what was read and checked.
    static func section(_ entry: Entry) throws -> String {
        let (item, rule, readings) = (entry.item, entry.rule, entry.readings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(rule), as: UTF8.self)
        let file = rule.since.map { "a correction of the finding for \(rule.match.map { "`\(plain($0))`" }.joined(separator: ", ")) that starts at version `\(plain($0))`" }
            ?? folder(for: item, rule: rule).map { "`findings/\($0)/0.json`" } ?? "a new finding, in a folder the maintainer names"
        let read = readings.map { $0.map { "- `\(plain($0, limit: 300))`" } }
            ?? ["- Not included: the checks came from an AI lookup, so what they read stays on the submitter's Mac."]
        return """
        **Item:** `\(plain(item.id))` (`\(plain(item.name))`, \(item.version.isEmpty ? "version unknown" : "version `\(plain(item.version))`"))\(entry.removed ? "\n**Not found on this Mac when sent:** Kanarie no longer finds it installed\(readings == nil ? "" : ", so the readings below are of this Mac without it")." : "")
        **Origin:** \(entry.origin)
        **Proposed as:** \(file)

        ````json
        \(json)
        ````

        **Read on the submitter's Mac**
        \(read.joined(separator: "\n"))

        **Source check**
        \(entry.sourceCheck.lines.map { "- \($0)" }.joined(separator: "\n"))
        """
    }

    /// Text from a file on disk or from an AI lookup, for a code span on one line of the issue: no line breaks, nothing
    /// invisible (a line break becomes a space), and no backtick that would end the span. Inside the span Markdown does nothing: no links, mentions or headings.
    static func plain(_ text: String, limit: Int = 100) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(String.UnicodeScalarView(line.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "`" }.prefix(limit)))
    }
}

extension URLSession {
    /// A download that stops at `limit` bytes, for content that is read before it can be trusted.
    public func data(from url: URL, limit: Int) async throws -> Data {
        let (bytes, response) = try await bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}
