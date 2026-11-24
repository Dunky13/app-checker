import Foundation
import os

public enum Shell {
    public struct Failure: LocalizedError {
        public var errorDescription: String?
        /// What the program had printed when it was stopped.
        public var output = Data()
    }

    /// Runs a program and returns its stdout. Blocking: call from a background task.
    /// `acceptFailure` is for programs that report errors as output with a non-zero exit, like the claude CLI.
    /// shortcut: the timeout stops the program itself but not processes it started; give it its own process group if that ever matters.
    public static func run(
        _ executable: String, _ arguments: [String],
        env: [String: String]? = nil, cwd: URL? = nil, timeout: TimeInterval, acceptFailure: Bool = false
    ) throws -> Data {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Assigning nil is not the same as leaving it unset: the child would start with an empty environment.
        if let env { process.environment = env }
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Its own flag: a program that handles the signal exits like any other, and one that crashes was not timed out.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            timedOut.withLock { $0 = true }
            process.terminate()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if timedOut.withLock({ $0 }) { throw Failure(errorDescription: "\(name) timed out after \(Int(timeout)) s.", output: data) }
        guard process.terminationReason == .exit else {
            throw Failure(errorDescription: "\(name) was stopped by signal \(process.terminationStatus).", output: data)
        }
        guard process.terminationStatus == 0 || (acceptFailure && !data.isEmpty) else {
            throw Failure(errorDescription: "\(name) exited with status \(process.terminationStatus).")
        }
        return data
    }

    /// The environment of the user's interactive login shell. Apps started from Finder do not inherit
    /// variables exported in .zshrc/.zprofile, and that is where telemetry opt-outs live.
    /// nil when the shell could not be asked, so the caller can say that variable-based verdicts may be wrong.
    public static func loginEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", marker = "__KANARIE_ENV__"
        guard let data = try? run(shell, ["-ilc", "printf \(marker); /usr/bin/env -0"], timeout: 15),
              let start = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[start.upperBound...].split(separator: 0) {
            let pair = String(decoding: entry, as: UTF8.self).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { env[String(pair[0])] = String(pair[1]) }
        }
        return env.isEmpty ? nil : env
    }

    /// Absolute path of a command on the given PATH.
    public static func which(_ command: String, env: [String: String]) -> String? {
        (env["PATH"] ?? "").split(separator: ":").map { "\($0)/\(command)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
