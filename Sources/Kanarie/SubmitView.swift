import KanarieCore
import SwiftUI

/// Proposes a finding for one item. Nothing is sent from here: the last step opens a prefilled GitHub issue in the browser.
struct SubmitView: View {
    var model: AppModel
    var item: Item
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Submission.Draft
    // What the sheet opened with. The verdict may change behind it, for example when new findings arrive.
    @State private var initial: Submission.Draft
    @State private var source: Verdict.Source
    @State private var check: Submission.SourceCheck?
    /// The source check and the opening of the issue, while they run.
    @State private var task: Task<Void, Never>?
    /// The finding is too long for a link, and the person has been told that continuing replaces the clipboard.
    @State private var mayCopy = false
    @State private var failure: String?

    init(model: AppModel, item: Item, verdict: Verdict) {
        (self.model, self.item) = (model, item)
        let start = Submission.Draft(from: verdict.rule, item: item)
        (_draft, _initial, _source) = (State(initialValue: start), State(initialValue: start), State(initialValue: verdict.source))
    }

    private var origin: String {
        switch source {
        case .rules: "Correction of the current finding"
        case .ai: draft == initial ? "AI lookup, not edited" : "AI lookup, edited by hand"
        case .sdk, .none: "Written by hand"
        }
    }

    var body: some View {
        let rule = draft.rule(for: item), problems = draft.problems(for: item)
        Form {
            Section {
                LabeledContent("Item", value: item.id)
                TextField("Name", text: $draft.name)
                Picker("Telemetry", selection: $draft.telemetry) {
                    Text("None").tag(Telemetry.none)
                    Text("Off until you switch it on").tag(Telemetry.optIn)
                    Text("On, can be switched off").tag(Telemetry.optOut)
                    Text("On, cannot be switched off").tag(Telemetry.forced)
                }
                TextField("What is collected", text: $draft.summary, prompt: Text("What is sent, and who receives it"), axis: .vertical).lineLimit(2...4)
                TextField("Privacy policy", text: $draft.policyURL, prompt: Text("https://"))
            }
            if [.optOut, .optIn].contains(draft.telemetry) {
                Section("How to switch it off") {
                    TextField("Steps", text: $draft.instructions, axis: .vertical).lineLimit(1...4)
                    TextField("Command", text: $draft.command, prompt: Text("echo 'export NAME=0' >> ~/.zshrc"))
                    TextField("Documentation", text: $draft.optOutURL, prompt: Text("https://"))
                    if !draft.checks.isEmpty {
                        LabeledContent("Checked on a Mac") { VStack(alignment: .trailing) { ForEach(draft.checks, id: \.self) { Text($0) } } }
                        Button("Replace These Checks") { draft.replaceChecks = true }
                            .help("Removes them from your proposal, so you can name the variable yourself")
                    } else if draft.telemetry == .optOut {
                        TextField("Variable that switches it off", text: $draft.variable, prompt: Text("EXAMPLE_TELEMETRY"))
                        TextField("Its value", text: $draft.value, prompt: Text("any value"))
                    }
                }
            }
            Section {
                TextField("Sources", text: $draft.sources, prompt: Text("One link per line"), axis: .vertical).lineLimit(2...5)
            } footer: {
                Text("Pages that say so: the vendor's documentation, its source code or an issue.").frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("With this finding, on this Mac") {
                ForEach(Submission.readings(rule, item: item, probe: model.probe), id: \.self) { Text($0) }
            }
        }
        .formStyle(.grouped)
        .disabled(task != nil)
        .onChange(of: draft) { (check, mayCopy, failure) = (nil, false, nil) }
        .onExitCommand { dismiss() }
        // Cancel, Escape or closing the window: stop fetching, and do not open anything afterwards.
        .onDisappear { task?.cancel() }
        .sheetFooter {
            VStack(alignment: .leading) {
                // Below the form, where it stays in view whatever the form is scrolled to.
                if !problems.isEmpty {
                    Label("Not ready yet: \(problems.joined(separator: "; ")).", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else if let failure {
                    Label("The issue could not be prepared: \(failure)", systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
                } else if mayCopy {
                    Label("This finding is too long for a link. Continuing copies it to your clipboard, replacing what is there, so you can paste it into the issue.", systemImage: "doc.on.clipboard")
                        .fixedSize(horizontal: false, vertical: true)
                } else if let check, !check.missing.isEmpty {
                    Label("\(check.lines.joined(separator: " ").replacingOccurrences(of: "`", with: "")) A name that no cited page mentions may be misspelled or invented: correct it, cite the page that has it, or continue and say so in the issue.", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Kanarie fetches the cited pages to look for the names, then opens a public GitHub issue in your browser. Nothing is sent until you submit it there.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if task != nil { ProgressView().controlSize(.small).accessibilityLabel("Fetching the cited pages") }
                    Button("Cancel") { dismiss() }
                    Button(mayCopy ? "Copy and Continue" : check?.missing.isEmpty == false ? "Continue Anyway" : "Continue on GitHub…") {
                        // Set here and not inside the task, so a second press in the same moment starts nothing.
                        guard task == nil else { return }
                        task = Task {
                            await proceed(rule)
                            task = nil
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty || task != nil)
                }
            }
        }
        .frame(width: 560, height: 640)
    }

    /// First the source check. When it finds every name, or the person continues anyway, the issue opens.
    private func proceed(_ rule: Rule) async {
        if check == nil {
            let pages = await Submission.pages(for: rule)
            guard !Task.isCancelled else { return }
            let result = Submission.sourceCheck(rule, pages: pages.texts, cited: pages.cited)
            check = result
            guard result.missing.isEmpty else { return }
        }
        guard let check else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
        // Checks from an AI lookup were chosen by whatever the lookup read. What they find on this Mac is shown in the form
        // and stays out of the public issue, so such a check cannot be used to ask a question about the Mac.
        let readings = source == .ai && !draft.checks.isEmpty ? nil : Submission.readings(rule, item: item, probe: model.probe)
        do {
            let issue = try Submission.issue(item: item, rule: rule, origin: origin, readings: readings, sourceCheck: check, appVersion: version, removed: model.removed.contains(item.id))
            if let text = issue.clipboard {
                guard mayCopy else { return mayCopy = true }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            NSWorkspace.shared.open(issue.url)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// What a bulk submission sends for an item: its AI lookup as it is, or why the item is left out.
@MainActor
func bulkFinding(for item: Item, model: AppModel) -> (rule: Rule?, why: String) {
    guard let verdict = model.verdicts[item.id] else { return (nil, "Not checked yet.") }
    switch verdict.source {
    case .rules: return (nil, "The Kanarie findings cover it. To change that, use Suggest a Correction…")
    case .sdk, .none: return (nil, "No finding to send. Look it up with AI first, or write one with Submit a Finding…")
    case .ai: break
    }
    // The form turns "unknown" into a telemetry class, which would be a claim the lookup did not make.
    guard let found = verdict.rule, found.telemetry != .unknown else { return (nil, "The lookup could not tell. Use Submit a Finding… to write one.") }
    let draft = Submission.Draft(from: found, item: item)
    let problems = draft.problems(for: item)
    guard problems.isEmpty else { return (nil, "Not ready: \(problems.joined(separator: "; ")). Fix it with Submit a Finding…") }
    return (draft.rule(for: item), "")
}

/// Proposes the AI lookups of several items in one GitHub issue. Nothing can be edited here: an item that needs
/// changes goes through `SubmitView`. Like there, the last step opens a prefilled issue in the browser.
struct BulkSubmitView: View {
    var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Decided when the sheet opens. The verdicts may change behind it.
    private let included: [(item: Item, rule: Rule)]
    private let skipped: [(item: Item, why: String)]
    @State private var checks: [Submission.SourceCheck]?
    @State private var task: Task<Void, Never>?
    @State private var mayCopy = false
    @State private var failure: String?

    init(model: AppModel, items: [Item]) {
        self.model = model
        var included: [(item: Item, rule: Rule)] = [], skipped: [(item: Item, why: String)] = []
        var folders: [String: String] = [:]
        for item in items {
            let (rule, why) = bulkFinding(for: item, model: model)
            guard let rule else { skipped.append((item, why)); continue }
            // The script refuses an issue whose findings would share a file, so the later one waits for its own issue.
            guard let folder = Submission.folder(for: item, rule: rule) else { skipped.append((item, "No folder name can be made from its name. Use Submit a Finding…")); continue }
            if let other = folders[folder] { skipped.append((item, "It would go to the same folder as \(other). Send it on its own.")); continue }
            guard included.count < Submission.bulkLimit else { skipped.append((item, "One issue holds at most \(Submission.bulkLimit) findings. Send it in a next one.")); continue }
            folders[folder] = item.name
            included.append((item, rule))
        }
        (self.included, self.skipped) = (included, skipped)
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(included.enumerated()), id: \.element.item.id) { index, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.rule.name ?? entry.item.name)
                        Text(entry.rule.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if let missing = checks?[index].missing, !missing.isEmpty {
                            Label("Not found on any cited page: \(missing.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            } header: {
                Text("Sent as AI lookups, not edited (\(included.count))")
            }
            if !skipped.isEmpty {
                Section("Left out (\(skipped.count))") {
                    ForEach(skipped, id: \.item.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.name)
                            Text(entry.why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onExitCommand { dismiss() }
        .onDisappear { task?.cancel() }
        .sheetFooter {
            VStack(alignment: .leading) {
                let missing = checks?.contains { !$0.missing.isEmpty } == true
                if included.isEmpty {
                    Label("None of the selected items has a lookup that can be sent as it is.", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else if let failure {
                    Label("The issue could not be prepared: \(failure)", systemImage: "exclamationmark.triangle").fixedSize(horizontal: false, vertical: true)
                } else if mayCopy {
                    Label("These findings are too long for a link. Continuing copies them to your clipboard, replacing what is there, so you can paste them into the issue.", systemImage: "doc.on.clipboard")
                        .fixedSize(horizontal: false, vertical: true)
                } else if missing {
                    Label("A name that no cited page mentions may be misspelled or invented. Correct that item with Submit a Finding…, or continue and say so in the issue.", systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Kanarie fetches the cited pages to look for the names, then opens one public GitHub issue with all of them in your browser. Nothing is sent until you submit it there.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if task != nil { ProgressView().controlSize(.small).accessibilityLabel("Fetching the cited pages") }
                    Button("Cancel") { dismiss() }
                    Button(mayCopy ? "Copy and Continue" : missing ? "Continue Anyway" : "Continue on GitHub…") {
                        guard task == nil else { return }
                        task = Task {
                            await proceed()
                            task = nil
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(included.isEmpty || task != nil)
                }
            }
        }
        .frame(width: 560, height: 640)
    }

    /// The source check of every finding at once, then, when all names were found or the person continues anyway, the issue.
    private func proceed() async {
        if checks == nil {
            let rules = included.map(\.rule)
            let pages = await withTaskGroup(of: (Int, (texts: [String], cited: Int)).self) { group in
                for (index, rule) in rules.enumerated() { group.addTask { (index, await Submission.pages(for: rule)) } }
                var pages = [(texts: [String], cited: Int)](repeating: ([], 0), count: rules.count)
                for await (index, result) in group { pages[index] = result }
                return pages
            }
            guard !Task.isCancelled else { return }
            let results = zip(rules, pages).map { Submission.sourceCheck($0, pages: $1.texts, cited: $1.cited) }
            checks = results
            guard results.allSatisfy(\.missing.isEmpty) else { return }
        }
        guard let checks else { return }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
        let entries = zip(included, checks).map { entry, check in
            // As in SubmitView: what a lookup's own checks read stays on this Mac.
            let readings = entry.rule.disabledWhen == nil && entry.rule.enabledWhen == nil ? Submission.readings(entry.rule, item: entry.item, probe: model.probe) : nil
            return Submission.Entry(item: entry.item, rule: entry.rule, origin: "AI lookup, not edited", readings: readings, sourceCheck: check, removed: model.removed.contains(entry.item.id))
        }
        do {
            let issue = try Submission.issue(entries, appVersion: version)
            if let text = issue.clipboard {
                guard mayCopy else { return mayCopy = true }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            NSWorkspace.shared.open(issue.url)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
