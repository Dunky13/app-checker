import Foundation

/// A finding someone proposes from the app. It leaves the Mac only as a prefilled GitHub issue that the person
/// reads and submits in their own browser: the app has no server of its own and no GitHub login.
public enum Submission {
    static let issues = "https://github.com/Dunky13/kanarie/issues/new"

    /// The fields of the form.
    /// shortcut: checks that came with an AI lookup or a curated finding are kept as they are, and by hand only one variable can be added; give checks their own editor if submissions need more.
    public struct Draft: Hashable, Sendable {
        public var telemetry = Telemetry.optOut
        public var name = "", summary = "", policyURL = "", instructions = "", command = "", optOutURL = "", sources = ""
        /// A variable that switches telemetry off, for a finding that has no checks yet.
        public var variable = "", value = ""
        var base: Rule?

        public init(from rule: Rule?, item: Item) {
            (base, name) = (rule, rule?.name ?? item.name)
            guard let rule else { return }
            telemetry = rule.telemetry == .unknown ? .optOut : rule.telemetry
            (summary, policyURL, sources) = (rule.summary, rule.policyURL ?? "", (rule.sources ?? []).joined(separator: "\n"))
            (instructions, command, optOutURL) = (rule.optOut?.instructions ?? "", rule.optOut?.command ?? "", rule.optOut?.url ?? "")
        }

        /// The checks of the finding this draft started from. They were written for its telemetry class, so another class drops them.
        var kept: (off: [Check], on: [Check]) {
            guard let base, base.telemetry == telemetry, [.optOut, .optIn].contains(telemetry) else { return ([], []) }
            return (base.disabledWhen ?? [], base.enabledWhen ?? [])
        }

        public var checks: [String] { kept.off.map { describe($0) + " switches it off" } + kept.on.map { describe($0) + " switches it on" } }

        public func rule(for item: Item) -> Rule {
            let text = { (field: String) in field.trimmingCharacters(in: .whitespacesAndNewlines) }
            let optional = { (field: String) in text(field).isEmpty ? nil : text(field) }
            // A correction keeps every item the curated finding covers.
            var rule = Rule(match: base?.since == nil ? [item.id] : base?.match ?? [item.id], telemetry: telemetry, summary: text(summary))
            (rule.name, rule.policyURL) = (optional(name), optional(policyURL))
            rule.sources = sources.split(whereSeparator: \.isNewline).map { text(String($0)) }.filter { !$0.isEmpty }
            guard [.optOut, .optIn].contains(telemetry) else { return rule }
            rule.optOut = OptOut(instructions: text(instructions), command: optional(command), url: optional(optOutURL))
            var off = kept.off
            if off.isEmpty, kept.on.isEmpty, telemetry == .optOut, let variable = optional(variable) { off = [Check(env: variable, equals: optional(value))] }
            (rule.disabledWhen, rule.enabledWhen) = (off.isEmpty ? nil : off, kept.on.isEmpty ? nil : kept.on)
            return rule
        }

        /// What keeps this draft from being a usable finding: the checks every curated finding passes, on the submitter's Mac already.
        public func problems(for item: Item) -> [String] {
            // Only where the field is in use: with another telemetry class or with kept checks it is not shown.
            let name = telemetry == .optOut && kept.off.isEmpty && kept.on.isEmpty ? variable.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let isName = name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") } && name.first?.isNumber != true
            return rule(for: item).problems(curated: true) + (isName ? [] : ["the variable is a name only, such as EXAMPLE_TELEMETRY; its value goes in the other field"])
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
        let local = item.editors.first.map(probe.forEditor) ?? probe
        let line = { (check: Check, role: String) in
            "\(describe(check)) (\(role)): " + (check.result(local).map { $0 ? "matches" : "does not match" } ?? "could not be read")
        }
        var alone = rule
        alone.since = nil
        let verdict = Verdict(item: item, rules: [alone], aiRules: [:], sdks: [], probe: probe)
        let colour = [Status.ok: "green", .warn: "yellow", .bad: "red", .unknown: "grey"][verdict.status] ?? ""
        return (rule.disabledWhen ?? []).map { line($0, "switches it off") } + (rule.enabledWhen ?? []).map { line($0, "switches it on") }
            + ["Verdict with this finding: \(colour). \(verdict.state)"]
    }

    /// Whether the names a finding relies on appear literally on the pages it cites.
    /// An invented variable or settings key is the main risk of an AI lookup, and this catches it without trusting anyone.
    public struct SourceCheck: Hashable, Sendable {
        public var found: [String], missing: [String], fetched: Int, cited: Int

        public var lines: [String] {
            ["Fetched \(fetched) of \(cited) cited pages."]
                + (found.isEmpty && missing.isEmpty ? ["The finding names no variable or setting, so there was nothing to look for."] : [])
                + (found.isEmpty ? [] : ["Found on a cited page: \(found.map { "`\($0)`" }.joined(separator: ", "))."])
                + (missing.isEmpty ? [] : ["Not found on any cited page: \(missing.map { "`\($0)`" }.joined(separator: ", "))."])
        }
    }

    public static func sourceCheck(_ rule: Rule, pages: [String], cited: Int) -> SourceCheck {
        var names = ((rule.disabledWhen ?? []) + (rule.enabledWhen ?? [])).compactMap { $0.env ?? $0.key ?? $0.contains }
        // Variables in the command count too: that line is copied straight into a shell profile.
        names += (rule.optOut?.command ?? "").matches(of: /[A-Z][A-Z0-9]*_[A-Z0-9_]+/).map { String($0.output) }
        names = names.enumerated().filter { names.firstIndex(of: $0.element) == $0.offset }.map(\.element)
        let found = names.filter { name in pages.contains { $0.contains(name) } }
        return SourceCheck(found: found, missing: names.filter { !found.contains($0) }, fetched: pages.count, cited: cited)
    }

    /// The text of the pages a finding cites. A page that cannot be fetched, or is not served over HTTPS on the public internet, is left out, and `cited` says how many were asked for.
    public static func pages(for rule: Rule) async -> (texts: [String], cited: Int) {
        let links = ((rule.sources ?? []) + [rule.optOut?.url].compactMap(\.self)).compactMap { safeURL($0) }
        let urls = links.enumerated().filter { links.firstIndex(of: $0.element) == $0.offset }.map(\.element).prefix(8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: PublicOnly(), delegateQueue: nil)
        var texts: [String] = []
        for url in urls where mayFetch(url) {
            if let data = try? await session.data(from: url, limit: 3_000_000) { texts.append(String(decoding: data, as: UTF8.self)) }
        }
        return (texts, urls.count)
    }

    /// Whether a cited page may be fetched. The links come from an AI lookup or a form, so they must not make this Mac
    /// ask itself or its own network: a router or a local service answers a request too.
    /// HTTPS covers the time between this lookup and the fetch: a host that answers with a local address by then has no certificate for its name there, so no request is sent.
    static func mayFetch(_ url: URL?) -> Bool { url?.scheme?.lowercased() == "https" && isPublic(url?.host) }

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
            // An IPv4 address inside an IPv6 one (::ffff:a.b.c.d, ::a.b.c.d and the NAT64 prefix 64:ff9b::) is judged as IPv4.
            let embedded = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == bytes[11] && [0, 0xff].contains(bytes[10])
                || Array(bytes.prefix(12)) == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]
            // Everything else must be a global address (2000::/3), which leaves out loopback, link-local, private and multicast.
            return embedded ? isPublic(address: Array(bytes[12...])) : bytes[0] & 0xe0 == 0x20
        }
        switch (bytes[0], bytes[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168), (100, 64...127), (172, 16...31), (198, 18...19), (224..., _): return false
        default: return true
        }
    }

    /// Keeps a cited page from redirecting to a link that `mayFetch` refuses.
    private final class PublicOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
            mayFetch(request.url) ? request : nil
        }
    }

    /// The prefilled GitHub issue. A body too long for a link comes back as `clipboard`, and the issue then asks to paste it.
    public static func issue(item: Item, rule: Rule, origin: String, readings: [String], sourceCheck: SourceCheck, appVersion: String) -> (url: URL, clipboard: String?) {
        // Names and versions come from files on disk: one short line each, and nothing that ends the code formatting.
        let plain = { (text: String) in
            String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "`" }.prefix(100)))
        }
        var clean = rule
        clean.since = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = (try? encoder.encode(clean)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let folder = (rule.name ?? item.name).lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.joined(separator: "-")
        let file = rule.since.map { "a new file after `\(plain($0)).json`" } ?? "`findings/\(folder.isEmpty ? "app" : folder)/0.json`"
        let body = """
        **Item:** `\(plain(item.id))` (\(plain(item.name)), version `\(plain(item.version))`)
        **Origin:** \(origin)
        **Proposed as:** \(file)

        ````json
        \(json)
        ````

        **Read on the submitter's Mac**
        \(readings.map { "- \($0)" }.joined(separator: "\n"))

        **Source check**
        \(sourceCheck.lines.map { "- \($0)" }.joined(separator: "\n"))

        Sent from Kanarie \(plain(appVersion)). The finding passed the app's format and safety checks. Whether it is true is for review.
        """
        let title = "Finding: \(plain(rule.name ?? item.name))"
        func url(_ body: String) -> URL {
            var components = URLComponents(string: issues) ?? URLComponents()
            components.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
            // URLComponents leaves "+" as it is, and GitHub would read it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            return components.url ?? URL(fileURLWithPath: "/")
        }
        let link = url(body)
        // GitHub answers a longer address with an error page.
        guard link.absoluteString.utf8.count > 7000 else { return (link, nil) }
        return (url("Paste the finding here: Kanarie put it on your clipboard."), body)
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
