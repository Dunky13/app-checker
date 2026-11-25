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
    /// No longer installed: a crossed-out circle instead of the status, which the detail pane and VoiceOver still give.
    var removed = false

    var body: some View {
        // Every status takes the room of the widest symbol, so the texts next to the icons line up.
        Image(systemName: Status.warn.symbol).hidden()
            .overlay { Image(systemName: removed ? "circle.slash" : status.symbol).foregroundStyle(removed ? .secondary : status.color) }
            .accessibilityElement().accessibilityLabel(status.label).accessibilityAddTraits(.isImage)
    }
}

let kindNames = ["app": "App", "brew": "Homebrew", "cask": "Homebrew cask", "bin": "Command-line tool", "npm": "npm package", "ext": "Editor extension"]

struct MenuView: View {
    var model: AppModel
    var updater: Updater
    @Environment(\.dismiss) private var dismiss
    /// Holding Option turns About Kanarie into About Arie, which opens where he comes from.
    @State private var option = false
    @State private var flags: Any?
    private let origin = (Bundle.main.object(forInfoDictionaryKey: "ArieOrigin") as? String).flatMap(URL.init(string:))

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kanarie").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }
            if !model.items.isEmpty { Text(arie).font(.callout).foregroundStyle(.secondary) }
            ForEach([Status.bad, .warn, .ok, .unknown], id: \.self) { status in
                HStack {
                    StatusIcon(status: status).accessibilityHidden(true)
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
            // One button, so focus and a click in progress survive Option going down or up. The click reads the key itself.
            Button(option && origin != nil ? "About Arie" : "About Kanarie") {
                dismiss()
                if NSEvent.modifierFlags.contains(.option), let origin {
                    NSWorkspace.shared.open(origin)
                    return
                }
                NSApp.activate(ignoringOtherApps: true)
                let centred = NSMutableParagraphStyle()
                centred.alignment = .center
                // Without attributes the credits are set in Helvetica, black also in dark mode.
                let credits = NSAttributedString(
                    string: "Arie, the canary, does not sing. He stays quiet while nothing on your Mac phones home, and sings right back at whatever does.",
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: centred])
                NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
            Button("Quit Kanarie") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .padding()
        .onAppear {
            option = NSEvent.modifierFlags.contains(.option)
            guard flags == nil else { return }
            flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                option = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let flags { NSEvent.removeMonitor(flags) }
            flags = nil
        }
        // Option may have changed while another app was active, where the monitor does not hear it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            option = NSEvent.modifierFlags.contains(.option)
        }
        .frame(width: 300)
    }

    /// What Arie, the canary, is doing: the loudest status decides.
    private var arie: String {
        let items = { (n: Int) in n == 1 ? "1 item" : "\(n) items" }
        if model.count(.bad) > 0 { return "Arie sings at \(items(model.count(.bad))) with no known opt-out." }
        if model.count(.warn) > 0 { return "Arie ruffles his feathers: \(items(model.count(.warn))) can be switched off." }
        if model.count(.unknown) > 0 { return "Arie cocks his head: he cannot tell for \(items(model.count(.unknown)))." }
        return "Arie dozes. Nothing hums."
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
    /// The items of an open bulk submission, kept like `pending`.
    @State private var submitting: [Item]?
    /// What the open confirmation is about. Kept, because the list can change while it is open.
    @State private var pending: [Item] = []

    /// What a choice of filters lets through, together with the search. The filter menu counts with it.
    private func listed(_ status: Status?, _ source: SourceFilter, _ kind: String?) -> [Item] {
        model.items.filter { item in
            (status == nil || model.verdicts[item.id]?.status == status)
                && source.allows(model.verdicts[item.id]?.source)
                && (kind == nil || item.kind == kind)
                && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.id.localizedCaseInsensitiveContains(search))
        }
    }

    private var shown: [Item] {
        listed(filter, source, kind)
            .sorted { a, b in
                // Removed items go last.
                let (ga, gb) = (model.removed.contains(a.id), model.removed.contains(b.id))
                let (ra, rb) = (model.verdicts[a.id]?.status.rank ?? 0, model.verdicts[b.id]?.status.rank ?? 0)
                return ga != gb ? gb : ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// What the lookup button works on. Several selected items: those, as far as the findings do not cover them, also
    /// when a lookup judged them before. Otherwise every listed item an AI lookup could still say something about.
    private func lookupCandidates(shown: [Item], picked: [Item]) -> [Item] {
        // An item that is being looked up right now is left out: a batch would skip it anyway.
        let free = (picked.count > 1 ? picked : shown).filter { !model.analysing.contains($0.id) }
        // Removed items only when selected: the list of everything ever uninstalled is not worth a batch.
        guard picked.count > 1 else { return free.filter { !model.removed.contains($0.id) && [.sdk, Verdict.Source.none].contains(model.verdicts[$0.id]?.source) } }
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
                    let removed = model.removed.contains(item.id)
                    StatusIcon(status: model.verdicts[item.id]?.status ?? .unknown, removed: removed)
                    VStack(alignment: .leading) {
                        Text(item.name).foregroundStyle(removed ? .secondary : .primary)
                        Text([kindNames[item.kind] ?? item.kind, item.version, removed ? "Removed" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.verdicts[item.id]?.source == .ai {
                        Image(systemName: "sparkles").foregroundStyle(.secondary).help("From an AI lookup, not verified").accessibilityLabel("From an AI lookup, not verified")
                    }
                    if model.analysing.contains(item.id) {
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
                } else if model.items.isEmpty {
                    ContentUnavailableView { Arie.emptyState("No software found") }
                } else if shown.isEmpty, search.isEmpty {
                    ContentUnavailableView("No items match the filter", systemImage: "line.3.horizontal.decrease.circle")
                } else if shown.isEmpty, filter != nil || source != .any || kind != nil {
                    ContentUnavailableView("No results for “\(search)” with this filter", systemImage: "magnifyingglass")
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: search)
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
                    // Always open: the sheet says which items go and why the others do not.
                    Button("Submit Findings…", systemImage: "square.and.pencil") { submitting = picked }
                        .help("Sends their AI lookups, as they are, in one GitHub issue")
                }
            // A single selected item stays open when its new verdict moves it out of the filtered list.
            } else if let item = picked.first ?? (selection.count == 1 ? model.items.first { selection.contains($0.id) } : nil), let verdict = model.verdicts[item.id] {
                // Its own state per item: a copy, a run's outcome or an open confirmation does not carry over to the next item.
                DetailView(model: model, item: item, verdict: verdict).id(item.id)
            } else {
                ContentUnavailableView {
                    Arie.emptyState("Select an item")
                } description: {
                    Text("\(model.items.count - model.removed.count) apps, packages and extensions checked.")
                }
            }
        }
        // In the toolbar: a sidebar search field scrolls out of sight with a long list.
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // A Menu with an explicit title: a bare toolbar Picker collapses to an unlabeled chevron.
                Menu {
                    Picker("Status", selection: $filter) {
                        // Each count is what choosing the entry would list, with the other filters and the search as they are.
                        Text("Any status (\(listed(nil, source, kind).count))").tag(Status?.none)
                        ForEach([Status.bad, .warn, .ok, .unknown], id: \.self) { status in
                            Label("\(status.label) (\(listed(status, source, kind).count))", systemImage: status.symbol).tag(Status?.some(status))
                        }
                    }
                    Picker("Verdict from", selection: $source) {
                        Text("Any source (\(listed(filter, .any, kind).count))").tag(SourceFilter.any)
                        ForEach([Verdict.Source.rules, .ai, .sdk, .none].map(SourceFilter.only) + [.notAI], id: \.self) { entry in
                            Text("\(entry.label ?? "") (\(listed(filter, entry, kind).count))").tag(entry)
                        }
                    }
                    Picker("Kind", selection: $kind) {
                        Text("Any kind (\(listed(filter, source, nil).count))").tag(String?.none)
                        ForEach(kindNames.sorted { $0.value < $1.value }, id: \.key) { kind in
                            Text("\(kind.value) (\(listed(filter, source, kind.key).count))").tag(String?.some(kind.key))
                        }
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
            Text("A lookup sends each item's name, identifier and version to the AI backend chosen in Settings and uses your quota or credits. The items go out in groups of \(LLM.batchSize), one group at a time. Stopping ends the group that is running without an answer.\(pending.contains { model.isEdited($0.id) } ? " A new lookup replaces the changes you saved on this Mac." : "")")
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: Binding { submitting != nil } set: { if !$0 { submitting = nil } }) { BulkSubmitView(model: model, items: submitting ?? []) }
    }
}

struct DetailView: View {
    var model: AppModel
    var item: Item
    var verdict: Verdict
    @State private var copied = false
    /// The run or the profile change waiting for confirmation, what it did, and whether it is running.
    @State private var confirming: OptOutStep?
    @State private var outcome: Result<String, Error>?
    @State private var working = false
    @State private var submitting = false
    @State private var log: OpenedLog?

    private var sourceNote: String {
        switch verdict.source {
        case .rules: "From the Kanarie findings."
        case .ai: model.isEdited(item.id) ? "From an AI lookup, edited by you on this Mac. Not verified: check its sources before relying on it."
            : "From an AI lookup. Not verified: check its sources before relying on it."
        case .sdk: "The hint comes from an offline search of the installed files for analytics service names."
        case .none: "Not in the Kanarie findings."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    // The status is written out next to it.
                    StatusIcon(status: verdict.status).font(.title).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text(verdict.rule?.name ?? item.name).font(.title2).bold()
                        Text(verdict.status.label).foregroundStyle(.secondary)
                    }
                }
                if model.removed.contains(item.id) {
                    Label(item.version.isEmpty ? "No longer installed." : "No longer installed. Last seen: version \(item.version).", systemImage: "circle.slash")
                        .foregroundStyle(.secondary)
                }
                Text(verdict.state).font(.headline)
                if let summary = verdict.rule?.summary { Text(summary) }

                if let optOut = verdict.rule?.optOut {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(optOut.instructions)
                            if let command = optOut.command, !command.isEmpty {
                                HStack {
                                    Text(command).font(.body.monospaced()).textSelection(.enabled)
                                    Spacer()
                                    if working { ProgressView().controlSize(.small).accessibilityLabel("Working") }
                                    switch OptOutStep(command: command, env: model.env, ai: verdict.source == .ai) {
                                    case let step?:
                                        Button(step.button, systemImage: step.icon) { confirming = step }.disabled(working)
                                    case nil:
                                        // A shell this does not know, or a command that cannot be done safely: copy it, as before.
                                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(command, forType: .string)
                                            copied = true
                                        }
                                    }
                                }
                                .padding(8)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                if verdict.source == .ai {
                                    Label(model.isEdited(item.id) ? "This command is from an AI lookup you edited. Read it and check the linked source before you run it." : "This command was suggested by an AI lookup. Read it and check the linked source before you run it.", systemImage: "exclamationmark.triangle")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                switch outcome {
                                case .success(let text)?: Label(text, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
                                case .failure(let error)?: Label(error.localizedDescription, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                                case nil: EmptyView()
                                }
                            }
                            if let url = safeURL(optOut.url) { Link("Opt-out documentation", destination: url) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    } label: {
                        Text("How to switch it off").font(.headline)
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
                    if !model.removed.contains(item.id) {
                        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    }
                    Button(verdict.source == .rules ? "Suggest a Correction…" : verdict.source == .ai ? "Edit or Submit…" : "Submit a Finding…", systemImage: "square.and.pencil") { submitting = true }
                }
                Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(confirming?.title ?? "", isPresented: Binding { confirming != nil } set: { if !$0 { confirming = nil } }, presenting: confirming) { step in
            Button(step.button) {
                working = true
                Task {
                    do { outcome = .success(try await step.perform(model)) } catch { outcome = .failure(error) }
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { step in
            Text(step.message)
        }
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
            .padding(20)
        }
        .sheetFooter {
            HStack {
                Text("AI lookup log of \(log.name). Kept on this Mac only.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .onExitCommand { dismiss() }
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
        .sheetFooter {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

extension View {
    /// The foot of a sheet: the same bar in every sheet, with the margins of a grouped form.
    func sheetFooter(@ViewBuilder _ content: () -> some View) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            content().padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
        }
    }
}

/// Running an opt-out command, or adding the variable it sets to the shell profile. Always confirmed first.
struct OptOutStep: Identifiable {
    enum Kind { case run(String), add(line: String, file: URL) }
    var kind: Kind
    /// Fixed when the button is pressed, so a verdict changing behind the alert cannot change what it says.
    var ai: Bool
    var id: String { title + message }
    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// nil when only copying is offered: a shell this does not know, or a command that cannot be done safely.
    init?(command: String, env: [String: String], ai: Bool) {
        self.ai = ai
        switch ShellProfile.action(for: command) {
        case .run: kind = .run(command)
        case let .add(name, value):
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard let addition = ShellProfile.addition(name: name, value: value, shell: ShellProfile.loginShell, home: home, env: env) else { return nil }
            kind = .add(line: addition.line, file: addition.file)
        case .copyOnly: return nil
        }
    }

    var button: String {
        switch kind {
        case .run: "Run"
        case .add(_, let file): "Add to \(ShellProfile.display(file, home: home))"
        }
    }

    var icon: String {
        switch kind {
        case .run: "play"
        case .add: "text.badge.plus"
        }
    }

    var title: String {
        switch kind {
        case .run: "Run this command?"
        case .add(_, let file): "Add these lines to \(ShellProfile.display(file, home: home))?"
        }
    }

    var message: String {
        let text = switch kind {
        case .run(let command): "\(command)\n\nIt runs once in sh, from your home folder, with your login shell's variables."
        case .add(let line, _): "\(ShellProfile.block(line))\n\nNew terminal windows will have it set. Apps opened from the Dock or Finder do not read this file."
        }
        return text + (ai ? "\n\nAn AI lookup suggested this. Check the linked source first." : "")
    }

    @MainActor func perform(_ model: AppModel) async throws -> String {
        switch kind {
        case .run(let command): try await model.runOptOut(command)
        case let .add(line, file): try await model.addToProfile(line, file: file)
        }
    }
}
