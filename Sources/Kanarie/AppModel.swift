import KanarieCore
import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class AppModel {
    nonisolated static let findingsURL = URL(string: "https://raw.githubusercontent.com/Dunky13/kanarie/main/findings/")!
    nonisolated static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kanarie")
    nonisolated static let stateFile = supportDir.appendingPathComponent("state.json"), cachedFindings = supportDir.appendingPathComponent("findings")
    /// One file per item: a log holds pages of web results, too much for the state file that is rewritten on every save.
    nonisolated static let lookupLogs = LookupLogs(folder: supportDir.appendingPathComponent("lookups"))
    /// Same key as the app's own updates: only findings the maintainer signed are accepted.
    nonisolated static var publicKey: String { Bundle.main.infoDictionary?["SUPublicEDKey"] as? String ?? "" }
    nonisolated static var bundledFindings: URL? { Bundle.main.url(forResource: "findings", withExtension: nil) }

    /// Everything that survives a restart.
    struct Saved: Codable {
        var known: [String: String] = [:]      // item id -> last seen version, to spot installs and updates
        var aiRules: [String: Rule] = [:]      // item id -> AI lookup result
        var sdks: [String: [String]] = [:]     // "id@version" -> SDK scan result
        var blocked: [String]?                 // files macOS would not let the app read; optional so older state files still load
        var serial: Int?                       // highest findings index accepted so far, which also holds when the cache is lost
        var names: [String: String]?           // item id -> last seen name, to list an item after it is removed
        var editors: [String: [String]]?       // extension id -> editors it was last seen in, for its verdict after it is removed
        var submitted: [String: Rule]?         // item id -> AI lookup last sent from this Mac, so a bulk submission sends only new ones
    }

    /// Installed items, followed by the ones that were removed since an earlier scan.
    private(set) var items: [Item] = []
    private(set) var removed: Set<String> = []
    private(set) var verdicts: [String: Verdict] = [:]
    private(set) var analysing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var scanning = false
    private(set) var batch: Task<Void, Never>?
    /// True when the login shell could not be asked for its variables, so variable-based settings may wrongly read as "on".
    private(set) var shellFailed = false

    private var rules: [Rule] = []
    private var serial = 0
    private var saved = Saved()
    private(set) var env: [String: String] = [:]
    private var watcher: Watcher?
    private var rescanQueued = false
    private var shell: ShellInfo?
    private var refreshShell = false
    /// Stop was asked, and the running request has not ended yet.
    private(set) var stopping = false

    nonisolated static func loadSaved() -> Saved {
        guard let data = try? Data(contentsOf: stateFile) else { return Saved() }
        do { return try JSONDecoder().decode(Saved.self, from: data) } catch {
            // Set the unreadable file aside instead of overwriting it: it may hold AI lookups a later version can still read.
            let aside = stateFile.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: stateFile, to: aside)
            NSLog("Kanarie: could not read saved state, kept it as \(aside.lastPathComponent): \(error)")
            return Saved()
        }
    }

    /// The findings shipped in the app, or the last verified download when that one is newer.
    nonisolated static func loadFindings() -> (serial: Int, rules: [Rule]) {
        var best: (serial: Int, rules: [Rule]) = (0, [])
        if let folder = bundledFindings {
            // The app's own code signature covers the bundled copy, so its index is only read for the serial.
            let index = try? JSONDecoder().decode(Findings.Index.self, from: Data(contentsOf: folder.appendingPathComponent("index.json")))
            do { best = (index?.serial ?? 0, try Findings.rules(from: Findings.read(folder: folder))) } catch {
                NSLog("Kanarie: the bundled findings are invalid: \(error.localizedDescription)")
            }
        }
        if let cached = try? Findings.verified(folder: cachedFindings, publicKey: publicKey), cached.index.serial > best.serial {
            best = (cached.index.serial, cached.rules)
        }
        return best
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        saved = Self.loadSaved()
        // Answers saved by an older version must pass today's checks too.
        for (id, rule) in saved.aiRules where !rule.problems(curated: false).isEmpty {
            saved.aiRules[id] = nil
            // Its log would show a lookup that looks fine next to an item nothing is known about.
            Self.lookupLogs.removeVerdictLog(for: id)
        }
        Probe.blockedFiles = Set(saved.blocked ?? [])
        (serial, rules) = Self.loadFindings()
        saved.serial = max(saved.serial ?? 0, serial)
        UserDefaults.standard.register(defaults: [
            "refreshRules": true, "backend": "claude", "claudeModel": "sonnet",
            "apiBaseURL": "https://openrouter.ai/api/v1", "apiModel": "~anthropic/claude-sonnet-latest",
        ])
        if !UserDefaults.standard.bool(forKey: "didSetUp") {
            UserDefaults.standard.set(true, forKey: "didSetUp")
            // Not fatal: Settings shows the real state and lets the user try again.
            do { try SMAppService.mainApp.register() } catch { NSLog("Kanarie: could not register the login item: \(error)") }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        Task {
            await rescan()
            while true {
                await refreshFindings()
                try? await Task.sleep(for: .seconds(86400))
            }
        }
    }

    /// Whether this lookup was sent from this Mac before. A lookup done again with another result is new.
    func wasSubmitted(_ id: String, _ rule: Rule) -> Bool { saved.submitted?[id] == rule }

    /// Remembers lookups whose issue was opened. Whether it was submitted on GitHub cannot be seen from here.
    func markSubmitted(_ sent: [(id: String, rule: Rule)]) {
        for entry in sent { saved.submitted = (saved.submitted ?? [:]).merging([entry.id: entry.rule]) { $1 } }
        save()
    }

    func count(_ status: Status) -> Int { verdicts.count { !removed.contains($0.key) && $0.value.status == status } }

    // MARK: Scanning

    /// What the login shell reports. Asked at launch and on Rescan only, not on every file system change:
    /// starting the shell runs the user's startup files, and npm and pnpm are real programs too.
    struct ShellInfo: Sendable {
        var env: [String: String]
        var failed: Bool
        var npmRoots: [URL]
        /// False when the shell or a package manager did not answer: such a result is asked for again at the next scan.
        var complete: Bool
        var asked = Date()

        static func current() -> ShellInfo {
            let shellEnv = Shell.loginEnvironment()
            let env = shellEnv ?? ProcessInfo.processInfo.environment
            // Without this npm uses the occasion to ask the registry for a newer npm.
            let quiet = env.merging(["npm_config_update_notifier": "false", "pnpm_config_update_notifier": "false"]) { $1 }
            var complete = shellEnv != nil
            let npmRoots = ["npm", "pnpm"].compactMap { tool -> URL? in
                guard let path = Shell.which(tool, env: env) else { return nil }
                guard let out = try? Shell.run(path, ["root", "-g"], env: quiet, timeout: 20) else { complete = false; return nil }
                // Node version managers hand every shell its own symlink: list and watch the folder behind it.
                return URL(fileURLWithPath: String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath()
            }
            return ShellInfo(env: env, failed: shellEnv == nil, npmRoots: npmRoots, complete: complete)
        }
    }

    struct Snapshot: Sendable {
        var shell: ShellInfo
        var items: [Item]
        var watch: [String]
        /// Kinds this scan could not fully read, whose missing items are not called removed.
        var unread: Set<String>
    }

    nonisolated static func scan(shell: ShellInfo?) -> Snapshot {
        let shell = shell ?? .current()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appDirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let brewPrefixes = ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0) }
        let binDirs = [home.appendingPathComponent(".local/bin")]
        // Extensions folder in the home folder, and the editor's settings folder in Application Support.
        let editors = [(".vscode", "Code"), (".vscode-insiders", "Code - Insiders"), (".vscode-oss", "VSCodium"), (".cursor", "Cursor"), (".windsurf", "Windsurf"), (".kiro", "Kiro")]
            .map { (editor: $0.1, dir: home.appendingPathComponent("\($0.0)/extensions")) }
        var seen = Set<String>()
        let items = (Scanner.apps(in: appDirs) + brewPrefixes.flatMap(Scanner.brew) + Scanner.binaries(in: binDirs)
            + Scanner.npm(roots: shell.npmRoots) + Scanner.extensions(in: editors))
            .filter { seen.insert($0.id).inserted }
        let watch = (appDirs + brewPrefixes.flatMap { [$0.appendingPathComponent("Cellar"), $0.appendingPathComponent("Caskroom")] }
            + binDirs + shell.npmRoots + editors.map(\.dir))
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        // Without a login shell or a package manager that answers, the npm folders were not looked in.
        let unread = Scanner.unread(brewPrefixes: brewPrefixes, editors: editors).union(shell.complete && !shell.npmRoots.isEmpty ? [] : ["npm"])
        return Snapshot(shell: shell, items: items, watch: watch, unread: unread)
    }

    /// `userInitiated` also retries files macOS blocked earlier, in case access was granted since.
    func rescan(userInitiated: Bool = false) async {
        if userInitiated { (Probe.blockedFiles, refreshShell) = ([], true) }
        guard !scanning else { rescanQueued = true; return }
        scanning = true
        // An incomplete answer is asked for again, but at most once an hour: a lookup that always fails costs up to a minute.
        let stale = shell.map { !$0.complete && Date().timeIntervalSince($0.asked) > 3600 } ?? true
        let known = refreshShell || stale ? nil : shell
        refreshShell = false
        let snapshot = await Task.detached { Self.scan(shell: known) }.value
        shell = snapshot.shell
        saved.names = (saved.names ?? [:]).merging(snapshot.items.map { ($0.id, $0.name) }) { $1 }
        saved.editors = (saved.editors ?? [:]).merging(snapshot.items.filter { !$0.editors.isEmpty }.map { ($0.id, $0.editors) }) { $1 }
        let names = saved.aiRules.compactMapValues(\.name).merging(saved.names ?? [:]) { $1 }
        let gone = Scanner.gone(known: saved.known, names: names, editors: saved.editors ?? [:], present: snapshot.items, unread: snapshot.unread)
        removed = Set(gone.map(\.id))
        (env, shellFailed, items) = (snapshot.shell.env, snapshot.shell.failed, snapshot.items + gone)
        evaluate()

        // Slow part, once per item version: look for telemetry SDKs in items nothing else is known about.
        let unscanned = items.filter { !removed.contains($0.id) && verdicts[$0.id]?.source == Verdict.Source.none && saved.sdks[Self.sdkKey($0)] == nil }
        let found = await Task.detached { unscanned.map { SDKScan.scan($0) } }.value
        for (item, sdks) in zip(unscanned, found) { saved.sdks[Self.sdkKey(item)] = sdks }
        let current = Set(items.map(Self.sdkKey))
        saved.sdks = saved.sdks.filter { current.contains($0.key) }  // drop results for versions that are gone
        evaluate()

        let changed = items.filter { saved.known[$0.id] != $0.version }
        let firstScan = saved.known.isEmpty
        // Never forget an item: a bundle that briefly vanishes mid-update must not count as a new install.
        for item in changed { saved.known[item.id] = item.version }
        save()
        let flagged = changed.filter { [.bad, .warn].contains(verdicts[$0.id]?.status) }
        if !firstScan, !flagged.isEmpty {
            notify(
                // A song for red, ruffled feathers when every one of them can be switched off.
                (flagged.contains { verdicts[$0.id]?.status == .bad } ? "Arie sings at " : "Arie ruffles his feathers at ")
                    + (flagged.count == 1 ? flagged[0].name : "\(flagged.count) new or updated items"),
                flagged.count == 1 ? "It may send telemetry. \(verdicts[flagged[0].id]?.state ?? "")" : "They may send telemetry: \(flagged.prefix(5).map(\.name).joined(separator: ", "))"
            )
        }

        if watcher?.paths != snapshot.watch {
            watcher?.stop()
            watcher = Watcher(paths: snapshot.watch) { [weak self] in Task { await self?.rescan() } }
        }
        scanning = false
        if rescanQueued {
            rescanQueued = false
            await rescan()
        }
    }

    nonisolated static func sdkKey(_ item: Item) -> String { "\(item.id)@\(item.version)" }

    /// Runs an opt-out command the person confirmed, then reads the settings and the shell again. Returns what to say.
    func runOptOut(_ command: String) async throws -> String {
        let (env, home) = (env, FileManager.default.homeDirectoryForCurrentUser)
        let output = try await Task.detached { try ShellProfile.run(command, env: env, home: home) }.value
        await rescan(userInitiated: true)
        return output.isEmpty ? "Done." : "Done: \(output.suffix(300))"
    }

    /// Adds a line the person confirmed to their shell profile, then reads the shell again so the verdict follows.
    func addToProfile(_ line: String, file: URL) async throws -> String {
        let added = try await Task.detached { try ShellProfile.append(line, to: file) }.value
        await rescan(userInitiated: true)
        let name = ShellProfile.display(file, home: FileManager.default.homeDirectoryForCurrentUser)
        return added ? "Added to \(name). New terminal windows have it." : "\(name) has this line already."
    }

    /// This Mac's settings as the checks read them, for a finding that is not in use yet.
    var probe: Probe { Probe.live(env: env) }

    private func evaluate() {
        let probe = probe
        verdicts = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, Verdict(item: $0, rules: rules, aiRules: saved.aiRules, sdks: saved.sdks[Self.sdkKey($0)] ?? [], probe: probe))
        })
    }

    private func save() {
        saved.blocked = Probe.blockedFiles.sorted()
        do { try JSONEncoder().encode(saved).write(to: Self.stateFile, options: .atomic) } catch { NSLog("Kanarie: could not save state: \(error)") }
    }

    private func refreshFindings() async {
        guard UserDefaults.standard.bool(forKey: "refreshRules") else { return }
        do {
            let session = URLSession(configuration: .ephemeral)
            // Findings are a few kilobytes each. The cap also holds for the index, which is read before its signature can be checked.
            let fetch = { (path: String) in try await session.data(from: Self.findingsURL.appendingPathComponent(path), limit: 1_000_000) }
            let (indexData, signature) = (try await fetch("index.json"), try await fetch("index.json.sig"))
            let index = try Findings.index(indexData, signature: String(decoding: signature, as: UTF8.self), publicKey: Self.publicKey)
            // Nothing newer. This also refuses an older index that someone plays back, even after the cache was lost.
            guard index.serial > serial, index.serial >= saved.serial ?? 0 else { return }
            // Files the app already has are reused by their hash and every other listed file is fetched,
            // whether or not the app is installed here: the requests say nothing about this Mac.
            var have: [String: Data] = [:]
            for folder in [Self.bundledFindings, Self.cachedFindings].compactMap(\.self) {
                for data in Findings.read(folder: folder).values { have[Findings.sha256(data)] = data }
            }
            var files: [String: Data] = [:]
            for (path, hash) in index.files {
                if let data = have[hash] { files[path] = data } else { files[path] = try await fetch(path) }
            }
            let rules = try Findings.rules(from: files, matching: index)

            try FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
            try Findings.store(files, index: indexData, signature: signature, in: Self.cachedFindings)
            (self.rules, serial, saved.serial) = (rules, index.serial, index.serial)
            evaluate()
            save()
        } catch {
            NSLog("Kanarie: findings not updated, keeping the current ones: \(error.localizedDescription)")
        }
    }

    // MARK: AI lookup

    /// One request for all of the items. Each gets its own verdict or error, and its own copy of the log.
    func analyse(_ items: [Item]) async {
        let items = items.filter { !analysing.contains($0.id) }
        guard !items.isEmpty else { return }
        analysing.formUnion(items.map(\.id))
        for item in items { errors[item.id] = nil }
        let results: [(log: [LLM.Turn], rule: Result<Rule, any Error>)]
        do { results = await LLM.analyse(items, backend: try backend(), env: env) } catch {
            // A lookup that could not start is logged too: otherwise the log would still show an older failure.
            results = items.map { _ in ([LLM.Turn(role: .error, text: error.localizedDescription)], .failure(error)) }
        }
        for (item, result) in zip(items, results) {
            var failed = false
            do { saved.aiRules[item.id] = try result.rule.get() } catch {
                failed = true
                errors[item.id] = error.localizedDescription
            }
            do { try Self.lookupLogs.save(result.log, for: item.id, failed: failed) } catch { NSLog("Kanarie: could not save the lookup log: \(error)") }
        }
        save()
        evaluate()
        analysing.subtract(items.map(\.id))
    }

    /// Looks the given items up group by group. Stops when a whole group fails, which is usually a quota or configuration problem.
    /// One batch at a time: a stopped one counts until its running request has ended.
    func analyseAll(_ items: [Item]) {
        guard batch == nil else { return }
        batch = Task {
            var rest = items[...]
            // An item a lookup of its own judges while the batch waits is not looked up a second time.
            let judged = Set(items.map(\.id).filter { saved.aiRules[$0] != nil })
            while !rest.isEmpty, !Task.isCancelled {
                // The list was made when the batch began. By now a rescan may have updated an item, the findings may
                // cover it, or a lookup of its own may be running. An item removed meanwhile stays listed, and is looked up.
                let group = rest.prefix(LLM.batchSize).compactMap { old in self.items.first { $0.id == old.id } }.filter { item in
                    verdicts[item.id]?.source != .rules && !analysing.contains(item.id) && (saved.aiRules[item.id] == nil || judged.contains(item.id))
                }
                rest = rest.dropFirst(LLM.batchSize)
                if group.isEmpty { continue }
                await analyse(group)
                if group.allSatisfy({ errors[$0.id] != nil }) { break }
            }
            (batch, stopping) = (nil, false)
        }
    }

    func stopBatch() {
        batch?.cancel()
        stopping = batch != nil
    }

    private func backend() throws -> LLM.Backend {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "backend") == "claude" {
            guard let path = Shell.which("claude", env: env) else {
                throw LLM.Failure(errorDescription: "The claude command was not found on your PATH. Install Claude Code or choose the API backend in Settings.")
            }
            return .claudeCLI(path: path, model: defaults.string(forKey: "claudeModel") ?? "")
        }
        guard let url = URL(string: defaults.string(forKey: "apiBaseURL") ?? ""), url.host != nil,
              let model = defaults.string(forKey: "apiModel"), !model.isEmpty else {
            throw LLM.Failure(errorDescription: "Set the API base URL and model in Settings.")
        }
        guard let key = Keychain.apiKey, !key.isEmpty else { throw LLM.Failure(errorDescription: "Add your API key in Settings.") }
        return .openAI(baseURL: url, model: model, apiKey: key)
    }
}

func notify(_ title: String, _ body: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
}

/// The API key for the OpenAI-compatible backend lives in the login keychain, never in preferences.
enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.went.kanarie", kSecAttrAccount as String: "llm-api-key"]
    }

    static var apiKey: String? {
        get {
            var result: AnyObject?
            let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
            return status == errSecSuccess ? (result as? Data).map { String(decoding: $0, as: UTF8.self) } : nil
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            let status = SecItemAdd(query.merging([kSecValueData as String: Data(newValue.utf8)]) { $1 } as CFDictionary, nil)
            if status != errSecSuccess { NSLog("Kanarie: could not store the API key (\(status))") }
        }
    }
}

/// Recursive file system watch. Events arrive on the main queue, batched over ten seconds.
@MainActor
final class Watcher {
    let paths: [String]
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 10, 0)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
