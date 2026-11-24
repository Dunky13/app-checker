import AppCheckerCore
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
                Text("App Checker").font(.headline)
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
            Button("Quit App Checker") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .padding()
        .frame(width: 300)
    }
}

struct MainView: View {
    var model: AppModel
    @State private var selection: Item.ID?
    @State private var search = ""
    @State private var filter: Status?
    @State private var showSettings = false
    @State private var confirmBatch = false

    private var shown: [Item] {
        model.items
            .filter { item in
                (filter == nil || model.verdicts[item.id]?.status == filter)
                    && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search) || item.id.localizedCaseInsensitiveContains(search))
            }
            .sorted { a, b in
                let (ra, rb) = (model.verdicts[a.id]?.status.rank ?? 0, model.verdicts[b.id]?.status.rank ?? 0)
                return ra != rb ? ra < rb : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Items an AI lookup could still say something about.
    private var lookupCandidates: [Item] {
        shown.filter { [.sdk, Verdict.Source.none].contains(model.verdicts[$0.id]?.source) }
    }

    var body: some View {
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
            if let item = model.items.first(where: { $0.id == selection }), let verdict = model.verdicts[item.id] {
                DetailView(model: model, item: item, verdict: verdict)
            } else {
                ContentUnavailableView("Select an item", systemImage: "checkmark.shield", description: Text("\(model.items.count) apps, packages and extensions checked."))
            }
        }
        // In the toolbar: a sidebar search field scrolls out of sight with a long list.
        .searchable(text: $search)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // A Menu with an explicit title: a bare toolbar Picker collapses to an unlabeled chevron.
                Menu {
                    Picker("Show", selection: $filter) {
                        Text("All items (\(model.items.count))").tag(Status?.none)
                        ForEach([Status.bad, .warn, .ok, .unknown], id: \.self) { status in
                            Label("\(status.label) (\(model.count(status)))", systemImage: status.symbol).tag(Status?.some(status))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label(filter?.label ?? "All items", systemImage: "line.3.horizontal.decrease.circle").labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Filter by status")
            }
            ToolbarItemGroup {
                if model.batch != nil {
                    Button("Stop Lookups", systemImage: "stop.circle") { model.stopBatch() }
                } else {
                    Button("Look Up Listed Items with AI", systemImage: "sparkles") { confirmBatch = true }
                        .disabled(lookupCandidates.isEmpty)
                }
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await model.rescan(userInitiated: true) } }.disabled(model.scanning)
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
        }
        .confirmationDialog("Look up \(lookupCandidates.count) items with AI?", isPresented: $confirmBatch) {
            Button("Look Up \(lookupCandidates.count) Items") { model.analyseAll(lookupCandidates) }
        } message: {
            Text("Each lookup sends the item's name, identifier and version to the AI backend chosen in Settings and uses your quota or credits. Lookups run one at a time and can be stopped.")
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

    private var sourceNote: String {
        switch verdict.source {
        case .rules: "From the App Checker findings."
        case .ai: "From an AI lookup. Not verified: check its sources before relying on it."
        case .sdk: "The hint comes from an offline search of the installed files for analytics service names."
        case .none: "Not in the App Checker findings."
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
                            Task { await model.analyse(item) }
                        }
                        .disabled(model.analysing.contains(item.id))
                        if model.analysing.contains(item.id) {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                            Text("Searching the web. This can take a minute or two.").foregroundStyle(.secondary)
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
