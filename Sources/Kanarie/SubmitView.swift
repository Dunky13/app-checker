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
            let issue = try Submission.issue(item: item, rule: rule, origin: origin, readings: readings, sourceCheck: check, appVersion: version)
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
