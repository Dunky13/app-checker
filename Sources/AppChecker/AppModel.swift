import AppCheckerCore
import AppKit
import Observation
import ServiceManagement
import UserNotifications

@MainActor @Observable
final class AppModel {
    nonisolated static let rulesURL = URL(string: "https://raw.githubusercontent.com/Dunky13/app-checker/main/rules.json")!
    nonisolated static let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("App Checker")
    nonisolated static let stateFile = supportDir.appendingPathComponent("state.json"), cachedRules = supportDir.appendingPathComponent("rules.json")

    /// Everything that survives a restart.
    struct Saved: Codable {
        var known: [String: String] = [:]      // item id -> last seen version, to spot installs and updates
        var aiRules: [String: Rule] = [:]      // item id -> AI lookup result
        var sdks: [String: [String]] = [:]     // "id@version" -> SDK scan result
        var blocked: [String]?                 // files macOS would not let the app read; optional so older state files still load
    }

    private(set) var items: [Item] = []
    private(set) var verdicts: [String: Verdict] = [:]
    private(set) var analysing: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private(set) var scanning = false
    private(set) var batch: Task<Void, Never>?

    private var rules: [Rule] = []
    private var saved = Saved()
    private var env: [String: String] = [:]
    private var watcher: Watcher?
    private var rescanQueued = false

    nonisolated static func loadSaved() -> Saved {
        (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    /// Uses whichever rules file is newer: the one shipped in the app or the last download.
    nonisolated static func loadRules() -> [Rule] {
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        return [Bundle.main.url(forResource: "rules", withExtension: "json"), cachedRules].compactMap(\.self)
            .sorted { modified($0) > modified($1) }
            .lazy.compactMap { try? RuleSet.decode(Data(contentsOf: $0)).rules }.first ?? []
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.supportDir, withIntermediateDirectories: true)
        saved = Self.loadSaved()
        Probe.blockedFiles = Set(saved.blocked ?? [])
        rules = Self.loadRules()
        UserDefaults.standard.register(defaults: [
            "refreshRules": true, "backend": "claude", "claudeModel": "sonnet",
            "apiBaseURL": "https://openrouter.ai/api/v1", "apiModel": "~anthropic/claude-sonnet-latest",
        ])
        if !UserDefaults.standard.bool(forKey: "didSetUp") {
            UserDefaults.standard.set(true, forKey: "didSetUp")
            try? SMAppService.mainApp.register()
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        Task {
            await rescan()
            while true {
                await refreshRules()
                try? await Task.sleep(for: .seconds(86400))
            }
        }
    }

    func count(_ status: Status) -> Int { verdicts.values.count { $0.status == status } }

    // MARK: Scanning

    struct Snapshot: Sendable {
        var env: [String: String]
        var items: [Item]
        var watch: [String]
    }

    nonisolated static func scan() -> Snapshot {
        let env = Shell.loginEnvironment()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appDirs = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        let brewPrefixes = ["/opt/homebrew", "/usr/local"].map { URL(fileURLWithPath: $0) }
        let npmRoots = ["npm", "pnpm"].compactMap { tool -> URL? in
            guard let path = Shell.which(tool, env: env), let out = try? Shell.run(path, ["root", "-g"], env: env, timeout: 20) else { return nil }
            return URL(fileURLWithPath: String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let extensionDirs = [".vscode", ".vscode-insiders", ".vscode-oss", ".cursor", ".windsurf"].map { home.appendingPathComponent("\($0)/extensions") }
        var seen = Set<String>()
        let items = (Scanner.apps(in: appDirs) + brewPrefixes.flatMap(Scanner.brew) + Scanner.npm(roots: npmRoots) + Scanner.extensions(in: extensionDirs))
            .filter { seen.insert($0.id).inserted }
        let watch = (appDirs + brewPrefixes.flatMap { [$0.appendingPathComponent("Cellar"), $0.appendingPathComponent("Caskroom")] } + npmRoots + extensionDirs)
            .map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        return Snapshot(env: env, items: items, watch: watch)
    }

    /// `userInitiated` also retries files macOS blocked earlier, in case access was granted since.
    func rescan(userInitiated: Bool = false) async {
        if userInitiated { Probe.blockedFiles = [] }
        guard !scanning else { rescanQueued = true; return }
        scanning = true
        let snapshot = await Task.detached { Self.scan() }.value
        (env, items) = (snapshot.env, snapshot.items)
        evaluate()

        // Slow part, once per item version: look for telemetry SDKs in items nothing else is known about.
        let unscanned = items.filter { verdicts[$0.id]?.source == Verdict.Source.none && saved.sdks[Self.sdkKey($0)] == nil }
        let found = await Task.detached { unscanned.map { SDKScan.scan($0) } }.value
        for (item, sdks) in zip(unscanned, found) { saved.sdks[Self.sdkKey(item)] = sdks }
        evaluate()

        let changed = items.filter { saved.known[$0.id] != $0.version }
        let firstScan = saved.known.isEmpty
        // Never forget an item: a bundle that briefly vanishes mid-update must not count as a new install.
        for item in changed { saved.known[item.id] = item.version }
        save()
        let flagged = changed.filter { [.bad, .warn].contains(verdicts[$0.id]?.status) }
        if !firstScan, !flagged.isEmpty {
            notify(
                flagged.count == 1 ? "\(flagged[0].name) may send telemetry" : "\(flagged.count) new or updated items may send telemetry",
                flagged.count == 1 ? verdicts[flagged[0].id]?.state ?? "" : flagged.prefix(5).map(\.name).joined(separator: ", ")
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

    private func evaluate() {
        let probe = Probe.live(env: env)
        verdicts = Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, Verdict(item: $0, rules: rules, aiRules: saved.aiRules, sdks: saved.sdks[Self.sdkKey($0)] ?? [], probe: probe))
        })
    }

    private func save() {
        saved.blocked = Probe.blockedFiles.sorted()
        do { try JSONEncoder().encode(saved).write(to: Self.stateFile, options: .atomic) } catch { NSLog("App Checker: could not save state: \(error)") }
    }

    private func refreshRules() async {
        guard UserDefaults.standard.bool(forKey: "refreshRules"),
              let (data, response) = try? await URLSession(configuration: .ephemeral).data(from: Self.rulesURL),
              (response as? HTTPURLResponse)?.statusCode == 200, let set = try? RuleSet.decode(data) else { return }
        rules = set.rules
        try? data.write(to: Self.cachedRules, options: .atomic)
        evaluate()
    }

    // MARK: AI lookup

    func analyse(_ item: Item) async {
        guard !analysing.contains(item.id) else { return }
        analysing.insert(item.id)
        errors[item.id] = nil
        do {
            saved.aiRules[item.id] = try await LLM.analyse(item, backend: backend(), env: env)
            save()
            evaluate()
        } catch {
            errors[item.id] = error.localizedDescription
        }
        analysing.remove(item.id)
    }

    /// Looks up the given items one after another. Stops on the first failure, which is usually a quota or configuration problem.
    func analyseAll(_ items: [Item]) {
        batch = Task {
            for item in items where !Task.isCancelled {
                await analyse(item)
                if errors[item.id] != nil { break }
            }
            batch = nil
        }
    }

    func stopBatch() {
        batch?.cancel()
        batch = nil
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
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "io.went.app-checker", kSecAttrAccount as String: "llm-api-key"]
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
            if status != errSecSuccess { NSLog("App Checker: could not store the API key (\(status))") }
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
