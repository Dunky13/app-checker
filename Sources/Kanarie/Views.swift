import KanarieCore
import ServiceManagement
import SwiftUI

extension Status {
    var label: String {
        switch self {
        case .bad: "Telemetry, no opt-out"
        case .warn: "Telemetry, opt-out available"
        case .ok: "Telemetry off"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .bad: "xmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .ok: "checkmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .bad: .red
        case .warn: .yellow
        case .ok: .green
        case .unknown: .gray
        }
    }

    /// Worst first.
    var rank: Int { [.bad, .warn, .unknown, .ok].firstIndex(of: self) ?? 0 }
}

extension Verdict.Source {
    var label: String {
        switch self {
        case .rules: "Kanarie findings"
        case .ai: "AI lookup"
        case .sdk: "Analytics code found, no finding"
        case .none: "Nothing known"
        }
    }
}

struct StatusIcon: View {
    var status: Status

    var body: some View {
        Image(systemName: status.symbol).foregroundStyle(status.color).accessibilityLabel(status.label)
    }
}

let kindNames = ["app": "App", "brew": "Homebrew", "cask": "Homebrew cask", "bin": "Command-line tool", "npm": "npm package", "ext": "Editor extension"]

struct MenuView: View {
    var model: AppModel
    var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kanarie").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }
            ForEach([Status.bad, .warn, .ok, .unknown], id: \.self) { status in
                HStack {
                    StatusIcon(status: status)
                    Text(status.label)
                    Spacer()
                    Text("\(model.count(status))").monospacedDigit().foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            Divider()
            if updater.updateAvailable {
                Button("Install Update…") { updater.checkForUpdates() }.buttonStyle(.borderedProminent)
            }
            Button("Open List") {
                NotificationCenter.default.post(name: .openMainWindow, object: nil)
                dismiss()
            }
            Button("Rescan Now") { Task { await model.rescan(userInitiated: true) } }.disabled(model.scanning)
            Button("Check for Updates…") { updater.checkForUpdates() }
            Button("Quit Kanarie") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .padding()
        .frame(width: 300)
    }
}

/// Where a verdict comes from, as the filter offers it.
private enum SourceFilter: Hashable {
    case any, only(Verdict.Source), notAI

    func allows(_ source: Verdict.Source?) -> Bool {
        switch self {
        case .any: true
        case .only(let wanted): source == wanted
        case .notAI: source != .ai
        }
    }

    var label: String? {
        switch self {
        case .any: nil
        case .only(let source): source.label
        case .notAI: "Not from an AI lookup"
        }
    }
}

struct MainView: View {
    var model: AppModel
    @State private var selection: Set<Item.ID> = []
    @State private var search = ""
    @State private var filter: Status?
    @State private var source = SourceFilter.any
    @State private var kind: String?
    @State private var showSettings = false
    @State private var confirmBatch = false
    /// What the open confirmation is about. Kept, because the list can change while it is open.
    @State private var pending: [Item] = []

    private var shown: [Item] {
        model.items
            .filter { item in
                (filter == nil || model.verdicts[item.id]?.status == filter)
                    && source.allows(model.verdicts[item.id]?.source)
                    && (kind == nil || item.kind == kind)
                    && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.id.localizedCaseInsensitiveContains(search))
            }
            .sorted { a, b in
                let (ra, rb) = (model.verdicts[a.id]?.status.rank ?? 0, model.verdicts[b.id]?.status.rank ?? 0)
                return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// What the lookup button works on. Several selected items: those, as far as the findings do not cover them, also
    /// when a lookup judged them before. Otherwise every listed item an AI lookup could still say something about.
    private func lookupCandidates(shown: [Item], picked: [Item]) -> [Item] {
        // An item that is being looked up right now is left out: a batch would skip it anyway.
        let free = (picked.count > 1 ? picked : shown).filter { !model.analysing.contains($0.id) }
        guard picked.count > 1 else { return free.filter { [.sdk, Verdict.Source.none].contains(model.verdicts[$0.id]?.source) } }
        return free.filter { model.verdicts[$0.id]?.source != .rules }
    }

    private var filterLabel: String {
        let active = [filter?.label, source.label, kind.map { kindNames[$0] ?? $0 }].compactMap { $0 }
        // Several names in a row push the search field out of the toolbar.
        return active.isEmpty ? "All items" : active.count == 1 ? active[0] : "\(active.count) filters"
    }

    var body: some View {
        // Once per redraw: filtering and sorting a few hundred items is too much to repeat for every use below.
        let shown = shown
        // The selected items that are in the list: a filter or a search can hide a selected one.
        let picked = shown.filter { selection.contains($0.id) }
        let lookupCandidates = lookupCandidates(shown: shown, picked: picked)
        NavigationSplitView {
            List(shown, selection: $selection) { item in
                HStack {
                    StatusIcon(status: model.verdicts[item.id]?.status ?? .unknown)
                    VStack(alignment: .leading) {
                        Text(item.name)
                        Text([kindNames[item.kind] ?? item.kind, item.version].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.verdicts[item.id]?.source == .ai {
                        Spacer()
                        Image(systemName: "sparkles").foregroundStyle(.secondary).help("From an AI lookup, not verified").accessibilityLabel("From an AI lookup, not verified")
                    }
                    if model.analysing.contains(item.id) {
                        Spacer()
                        ProgressView().controlSize(.small).accessibilityLabel("Looking up")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .safeAreaInset(edge: .bottom) {
                if model.shellFailed {
                    Label("Could not read your shell environment. Settings made with environment variables may show as on.", systemImage: "exclamationmark.triangle")
                        .font(.callout).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
                }
            }
            .overlay {
                if model.items.isEmpty, model.scanning {
                    ProgressView("Scanning installed software…")
                } else if shown.isEmpty {
                    ContentUnavailableView.search
                }
            }
        } detail: {
            if picked.count > 1 {
                ContentUnavailableView {
                    Label("\(picked.count) items selected", systemImage: "checklist")
                } description: {
                    Text(lookupCandidates.isEmpty ? "The Kanarie findings cover all of them." : "\(lookupCandidates.count) of them can be looked up with AI.")
                } actions: {
                    Button("Look Up \(lookupCandidates.count) Items with AI", systemImage: "sparkles") { (pending, confirmBatch) = (lookupCandidates, true) }
                        .disabled(lookupCandidates.isEmpty || model.batch != nil)
                }
            // A single selected item stays open when its new verdict moves it out of the filtered list.
            } else if let item = picked.first ?? (selection.count == 1 ? model.items.first { selection.contains($0.id) } : nil), let verdict = model.verdicts[item.id] {
                DetailView(model: model, item: item, verdict: verdict)
            } else {
                ContentUnavailableView("Select an item", systemImage: "bird", description: Text("\(model.items.count) apps, packages and extensions checked."))
            }
        }
        // In the toolbar: a sidebar search field scrolls out of sight with a long list.
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // A Menu with an explicit title: a bare toolbar Picker collapses to an unlabeled chevron.
                Menu {
                    Picker("Status", selection: $filter) {
                        Text("Any status (\(model.items.count))").tag(Status?.none)
                        ForEach([Status.bad, .warn, .ok, .unknown], id: \.self) { status in
                            Label("\(status.label) (\(model.count(status)))", systemImage: status.symbol).tag(Status?.some(status))
                        }
                    }
                    Picker("Verdict from", selection: $source) {
                        Text("Any source").tag(SourceFilter.any)
                        ForEach([Verdict.Source.rules, .ai, .sdk, .none], id: \.self) { Text($0.label).tag(SourceFilter.only($0)) }
                        Text(SourceFilter.notAI.label ?? "").tag(SourceFilter.notAI)
                    }
                    Picker("Kind", selection: $kind) {
                        Text("Any kind").tag(String?.none)
                        ForEach(kindNames.sorted { $0.value < $1.value }, id: \.key) { Text($0.value).tag(String?.some($0.key)) }
                    }
                } label: {
                    Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle").labelStyle(.titleAndIcon)
                }
                .pickerStyle(.inline)
                .accessibilityLabel("Filter")
            }
            ToolbarItemGroup {
                if model.batch != nil {
                    Button("Stop Lookups", systemImage: "stop.circle") { model.stopBatch() }.disabled(model.stopping)
                } else {
                    Button(picked.count > 1 ? "Look Up Selected Items with AI" : "Look Up Listed Items with AI", systemImage: "sparkles") { (pending, confirmBatch) = (lookupCandidates, true) }
                        .disabled(lookupCandidates.isEmpty)
                }
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await model.rescan(userInitiated: true) } }.disabled(model.scanning)
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .confirmationDialog("Look up \(pending.count) items with AI?", isPresented: $confirmBatch) {
            Button("Look Up \(pending.count) Items") { model.analyseAll(pending) }
        } message: {
            Text("A lookup sends each item's name, identifier and version to the AI backend chosen in Settings and uses your quota or credits. The items go out in groups of \(LLM.batchSize), one group at a time. Stopping ends the group that is running without an answer.")
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct DetailView: View {
    var model: AppModel
    var item: Item
    var verdict: Verdict
    @State private var copied = false
    @State private var submitting = false
    @State private var log: OpenedLog?

    private var sourceNote: String {
        switch verdict.source {
        case .rules: "From the Kanarie findings."
        case .ai: "From an AI lookup. Not verified: check its sources before relying on it."
        case .sdk: "The hint comes from an offline search of the installed files for analytics service names."
        case .none: "Not in the Kanarie findings."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    StatusIcon(status: verdict.status).font(.title)
                    VStack(alignment: .leading) {
                        Text(verdict.rule?.name ?? item.name).font(.title2).bold()
                        Text(verdict.status.label).foregroundStyle(.secondary)
                    }
                }
                Text(verdict.state).font(.headline)
                if let summary = verdict.rule?.summary { Text(summary) }

                if let optOut = verdict.rule?.optOut {
                    GroupBox("How to switch it off") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(optOut.instructions)
                            if let command = optOut.command, !command.isEmpty {
                                HStack {
                                    Text(command).font(.body.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(command, forType: .string)
                                        copied = true
                                    }
                                }
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                if verdict.source == .ai {
                                    Label("This command was suggested by an AI lookup. Read it and check the linked source before you run it.", systemImage: "exclamationmark.triangle")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                            }
                            if let url = safeURL(optOut.url) { Link("Opt-out documentation", destination: url) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                if let url = safeURL(verdict.rule?.policyURL) { Link("Privacy information", destination: url) }
                let sources = (verdict.rule?.sources ?? []).compactMap { safeURL($0) }
                if !sources.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sources").font(.headline)
                        ForEach(sources, id: \.self) { url in
                            Link(destination: url) { Text(url.absoluteString).lineLimit(1).truncationMode(.middle) }
                        }
                    }
                }

                Divider()
                Text(sourceNote).font(.callout).foregroundStyle(.secondary)
                if verdict.source != .rules {
                    HStack {
                        Button(verdict.source == .ai ? "Look Up Again with AI" : "Look Up with AI", systemImage: "sparkles") {
                            Task { await model.analyse([item]) }
                        }
                        .disabled(model.analysing.contains(item.id))
                        if model.analysing.contains(item.id) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text("Searching the web. This can take a minute or two.").foregroundStyle(.secondary)
                        } else if AppModel.lookupLogs.hasLog(for: item.id) {
                            Button("Show Lookup Log…", systemImage: "text.bubble") {
                                let parts = AppModel.lookupLogs.load(for: item.id)
                                log = OpenedLog(name: item.name, verdict: parts.verdict, failed: parts.failed, fromLookup: verdict.source == .ai)
                            }
                        }
                    }
                    if let error = model.errors[item.id] {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    Button(verdict.source == .rules ? "Suggest a Correction…" : "Submit a Finding…") { submitting = true }
                }
                Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: item.id) { copied = false }
        .sheet(isPresented: $submitting) { SubmitView(model: model, item: item, verdict: verdict) }
        .sheet(item: $log) { LookupLogView(log: $0) }
    }
}

/// A log as it was read when its window opened, so a lookup that ends or a selection that changes meanwhile does not change it.
private struct OpenedLog: Identifiable {
    let id = UUID()
    var name: String
    /// The lookup the verdict comes from and a later one that failed. nil: not there, or not readable.
    var verdict: [LLM.Turn]?, failed: [LLM.Turn]?
    /// The verdict is a lookup's, so there should be a log for it.
    var fromLookup: Bool
}

/// What an AI lookup asked and got back. All of it is shown as plain text: tool results are web pages.
struct LookupLogView: View {
    @Environment(\.dismiss) private var dismiss
    fileprivate var log: OpenedLog

    var body: some View {
        // Two lookups in one list would read as one conversation, so each gets its heading.
        let twoParts = log.failed != nil && (log.verdict != nil || log.fromLookup)
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if log.verdict == nil, log.failed == nil { Text("This log could not be read.").foregroundStyle(.secondary) }
                    if twoParts {
                        Text("The lookup behind the verdict").font(.headline)
                        if log.verdict == nil { Text("Its log is not on this Mac, or cannot be read.").foregroundStyle(.secondary) }
                    }
                    LogTurns(turns: log.verdict ?? [])
                    if twoParts { Text("A later lookup, which failed").font(.headline).padding(.top, 8) }
                    LogTurns(turns: log.failed ?? [])
                }
                .padding()
            }
            Divider()
            HStack {
                Text("AI lookup log of \(log.name). Kept on this Mac only.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 640, height: 600)
    }
}

/// One lookup: its messages, with the tool calls between two messages folded into a group.
private struct LogTurns: View {
    var turns: [LLM.Turn]

    var body: some View {
        ForEach(Array(LLM.grouped(turns).enumerated()), id: \.offset) { _, group in
            if group[0].role == .tool {
                DisclosureGroup(group.count == 1 ? "1 tool call" : "\(group.count) tool calls") {
                    ForEach(Array(group.enumerated()), id: \.offset) { _, call in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: call.tool ?? "Tool").font(.callout).bold()
                            LogText(text: call.text)
                            LogText(text: call.result ?? "No result was recorded.").foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    switch group[0].role {
                    case .user: Text("Prompt").font(.caption).bold().foregroundStyle(.secondary)
                    case .error: Label("The lookup failed", systemImage: "exclamationmark.triangle").font(.caption).bold().foregroundStyle(.red)
                    default: Text("Model").font(.caption).bold().foregroundStyle(.secondary)
                    }
                    LogText(text: group[0].text)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

/// A text of the log, with its JSON and fenced code set as code blocks.
private struct LogText: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(LLM.blocks(of: text).enumerated()), id: \.offset) { _, block in
                if block.isCode {
                    Text(verbatim: block.text).font(.callout.monospaced())
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(verbatim: block.text)
                }
            }
        }
        .textSelection(.enabled)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("refreshRules") private var refreshRules = true
    @AppStorage("backend") private var backend = "claude"
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("apiBaseURL") private var apiBaseURL = ""
    @AppStorage("apiModel") private var apiModel = ""
    @State private var apiKey = Keychain.apiKey ?? ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() } catch { launchAtLogin = !on }
                    }
                Toggle("Download new findings daily", isOn: $refreshRules)
            } footer: {
                Text("Findings are fetched from GitHub. Nothing about your Mac is sent.").frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Picker("Backend", selection: $backend) {
                    Text("Claude Code CLI (your Claude login)").tag("claude")
                    Text("OpenAI-compatible API (OpenRouter)").tag("api")
                }
                if backend == "claude" {
                    TextField("Model", text: $claudeModel, prompt: Text("CLI default"))
                } else {
                    TextField("Base URL", text: $apiBaseURL)
                    TextField("Model", text: $apiModel)
                    SecureField("API key", text: $apiKey)
                }
            } header: {
                Text("AI lookup")
            } footer: {
                Text("Lookups only run when you ask for them. They send the item's name, identifier and version to the backend. The API key is stored in your keychain.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onExitCommand { dismiss() }
        .onDisappear { if apiKey != Keychain.apiKey ?? "" { Keychain.apiKey = apiKey } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }
}
