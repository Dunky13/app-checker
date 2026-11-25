import Foundation

/// What the app offers for an opt-out command, besides copying it. Every action is confirmed first, showing the exact text.
public enum ShellProfile {
    public enum Action: Equatable, Sendable {
        /// The command only sets one variable to a switch value: written to the shell's profile in that shell's syntax.
        case add(name: String, value: String)
        /// Any other command: run once.
        case run
        /// Not plain enough to show in full, or a variable or profile edit that cannot be written safely.
        case copyOnly
    }

    /// Variables that change what runs, where traffic goes or what is trusted, not telemetry. Never offered for adding.
    static func isRisky(_ name: String) -> Bool {
        ["SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "IFS", "TMPDIR", "BROWSER", "PERL5OPT", "RUBYOPT"].contains(name)
            || ["DYLD_", "LD_", "XDG_", "GIT_SSH"].contains(where: name.hasPrefix)
            || ["PATH", "HOME", "LIB", "OPTIONS", "STARTUP", "TLS", "SSL", "VERIFY", "CERT", "PROXY", "PROMPT", "EDITOR", "PAGER", "ASKPASS"]
                .contains(where: name.contains)
    }

    /// What a confirmation can show in full: plain ASCII, short, without padding or hidden characters, like a curated command.
    static func isPlain(_ command: String) -> Bool {
        command.allSatisfy(\.isASCII) && command.unicodeScalars.count <= 300 && !command.contains("  ") && !Check.hasHiddenCharacters(command)
    }

    public static func action(for command: String) -> Action {
        guard isPlain(command) else { return .copyOnly }
        var line = Substring(command)
        // `echo 'export NAME=value' >> ~/.zshrc`: the variable, for whatever profile this person's shell reads.
        if let echo = command.wholeMatch(of: /echo '([^']*)' >> ~\/\.(?:zshrc|zshenv|zprofile|bashrc|bash_profile|bash_login|profile)/)
            ?? command.wholeMatch(of: /echo "([^"]*)" >> ~\/\.(?:zshrc|zshenv|zprofile|bashrc|bash_profile|bash_login|profile)/) {
            line = echo.output.1
        } else if command.contains(">") || command.hasPrefix("echo ") {
            return .copyOnly
        }
        // Only switch values: a variable set to a host, a path or a number of its own is more than a telemetry switch.
        if let set = line.wholeMatch(of: /export ([A-Za-z_][A-Za-z0-9_]*)=(?i:(0|1|true|false|yes|no|on|off|disabled))/), !isRisky(String(set.output.1)) {
            return .add(name: String(set.output.1), value: String(set.output.2))
        }
        return line.hasPrefix("export ") || line != Substring(command) ? .copyOnly : .run
    }

    /// The profile the login shell reads, and the line that sets the variable there.
    /// `env` is the login shell's environment, for a profile folder moved elsewhere (ZDOTDIR, XDG_CONFIG_HOME).
    /// nil for a shell this does not know: then the command is only offered for copying.
    public static func addition(name: String, value: String, shell: String, home: URL, env: [String: String]) -> (file: URL, line: String)? {
        let export = "export \(name)=\(value)"
        switch URL(fileURLWithPath: shell).lastPathComponent {
        case "zsh":
            return (URL(fileURLWithPath: env["ZDOTDIR"] ?? home.path).appendingPathComponent(".zshrc"), export)
        case "bash":
            // A login bash reads only the first of these that exists: a new .bash_profile would hide the others.
            let files = [".bash_profile", ".bash_login", ".profile"].map(home.appendingPathComponent)
            return (files.first { FileManager.default.fileExists(atPath: $0.path) } ?? files[0], export)
        case "sh", "dash", "ksh":
            return (home.appendingPathComponent(".profile"), export)
        case "fish":
            let config = env["XDG_CONFIG_HOME"].map(URL.init(fileURLWithPath:)) ?? home.appendingPathComponent(".config")
            return (config.appendingPathComponent("fish/config.fish"), "set -gx \(name) \(value)")
        default:
            return nil
        }
    }

    /// A path as the person knows it: `~/.zshrc` below the home folder.
    public static func display(_ file: URL, home: URL) -> String {
        file.path.hasPrefix(home.path + "/") ? "~" + file.path.dropFirst(home.path.count) : file.path
    }

    /// What is written for a line: a comment saying where it came from, and the line.
    public static func block(_ line: String) -> String { "# Added by Kanarie to switch off telemetry\n\(line)" }

    /// The person's login shell: what the app was started with, else the account's.
    public static var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } } ?? ""
    }

    /// Appends the block to the profile, unless a line of the profile is that line already. False when it was there.
    public static func append(_ line: String, to file: URL) throws -> Bool {
        let existing = (try? Data(contentsOf: file)) ?? Data()
        if String(decoding: existing, as: UTF8.self).split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            return false
        }
        // Writing through a link to a missing file would put a plain file in place of the link.
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil, !FileManager.default.fileExists(atPath: file.path) {
            throw Shell.Failure(errorDescription: "\(file.path) is a link to a file that does not exist.")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        // Appended, not rewritten: the rest of the file stays as it is, also when it is a link into a dotfiles folder.
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let start = existing.isEmpty || existing.last == UInt8(ascii: "\n") ? "" : "\n"
        try handle.write(contentsOf: Data("\(start)\(block(line))\n".utf8))
        return true
    }

    /// Runs a confirmed opt-out command from the home folder, with the login shell's variables. Output and errors come back together.
    public static func run(_ command: String, env: [String: String], home: URL) throws -> String {
        let marker = "__KANARIE_EXIT__"
        // Passed as an argument and run with eval, so nothing in the command (a final backslash, an open quote) can reach the report.
        let data = try Shell.run("/bin/sh", ["-c", "exec 2>&1; eval \"$1\"; printf '\\n\(marker)%s' \"$?\"", "sh", command], env: env, cwd: home, timeout: 60)
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: marker, options: .backwards) else { throw Shell.Failure(errorDescription: "The command ended the shell before it could report.", output: data) }
        let output = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let status = text[range.upperBound...]
        guard status == "0" else { throw Shell.Failure(errorDescription: "It ended with status \(status)" + (output.isEmpty ? "." : ": \(output.suffix(300))"), output: data) }
        return output
    }
}
