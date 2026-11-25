import Foundation

/// What the app offers for an opt-out command, besides copying it. Every action is confirmed first, showing the exact text.
public enum ShellProfile {
    public enum Action: Equatable, Sendable {
        /// The command only sets one variable: written to the shell's profile in that shell's syntax.
        case add(name: String, value: String)
        /// Any other command: run once, as if typed in Terminal.
        case run
        /// Looks like a variable or a profile edit, but not one that can be written safely.
        case copyOnly
    }

    /// Variables that change what runs or where, not telemetry. Setting one of these from a finding is never offered.
    static func isRisky(_ name: String) -> Bool {
        ["PATH", "HOME", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "NODE_OPTIONS", "PYTHONPATH", "PYTHONSTARTUP", "PERL5OPT", "RUBYOPT"].contains(name)
            || name.hasPrefix("DYLD_") || name.hasPrefix("LD_")
    }

    public static func action(for command: String) -> Action {
        var line = Substring(command)
        // `echo 'export NAME=value' >> ~/.zshrc`: the variable, for whatever profile this person's shell reads.
        if let echo = command.wholeMatch(of: /echo '([^']*)' >> ~\/\.[A-Za-z0-9_.\/-]+/) ?? command.wholeMatch(of: /echo "([^"]*)" >> ~\/\.[A-Za-z0-9_.\/-]+/) {
            line = echo.output.1
        } else if command.contains(">") || command.hasPrefix("echo ") {
            return .copyOnly
        }
        if let set = line.wholeMatch(of: /export ([A-Za-z_][A-Za-z0-9_]*)=([A-Za-z0-9._-]+)/), !isRisky(String(set.output.1)) {
            return .add(name: String(set.output.1), value: String(set.output.2))
        }
        return line.hasPrefix("export ") || line != Substring(command) ? .copyOnly : .run
    }

    /// The profile a login shell reads, below the home folder, and the line that sets the variable there.
    /// nil for a shell this does not know: then the command is only offered for copying.
    public static func addition(name: String, value: String, shell: String) -> (file: String, line: String)? {
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh": (".zshrc", "export \(name)=\(value)")
        case "bash": (".bash_profile", "export \(name)=\(value)")
        case "sh", "dash", "ksh": (".profile", "export \(name)=\(value)")
        case "fish": (".config/fish/config.fish", "set -gx \(name) \(value)")
        default: nil
        }
    }

    /// The person's login shell: what the app was started with, else the account's.
    public static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? ""
    }

    /// Appends the line to the profile, unless a line of the profile is that line already. False when it was there.
    public static func append(_ line: String, to file: URL) throws -> Bool {
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if existing.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        // Appended, not rewritten: the rest of the file stays as it is, also when it is a link into a dotfiles folder.
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let start = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try handle.write(contentsOf: Data("\(start)# Added by Kanarie to switch off telemetry\n\(line)\n".utf8))
        return true
    }

    /// Runs a confirmed opt-out command with the login shell's variables. Its output and errors come back together.
    public static func run(_ command: String, env: [String: String]) throws -> String {
        let marker = "__KANARIE_EXIT__"
        let data = try Shell.run("/bin/sh", ["-c", "exec 2>&1; \(command)\nprintf '\\n\(marker)%s' \"$?\""], env: env, timeout: 60)
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: marker, options: .backwards) else { throw Shell.Failure(errorDescription: "The command ended the shell before it could report.", output: data) }
        let output = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let status = text[range.upperBound...]
        guard status == "0" else { throw Shell.Failure(errorDescription: "It ended with status \(status)" + (output.isEmpty ? "." : ": \(output.suffix(300))"), output: data) }
        return output
    }
}
