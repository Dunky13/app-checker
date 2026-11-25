import Foundation
import os

public enum Shell {
    public struct Failure: LocalizedError {
        public var errorDescription: String?
        /// What the program had printed when it was stopped.
        public var output = Data()
    }

    /// Lets another task end a program that `run` is waiting for.
    public final class Stop: Sendable {
        private let state = OSAllocatedUnfairLock<(asked: Bool, end: (@Sendable () -> Void)?)>(initialState: (false, nil))
        public init() {}
        public func now() { state.withLock { $0.asked = true; return $0.end }?() }
        var asked: Bool { state.withLock { $0.asked } }
        /// Asked before the program started: it is ended as soon as it runs.
        func attach(_ end: @escaping @Sendable () -> Void) { if state.withLock({ $0.end = end; return $0.asked }) { end() } }
    }

    /// Runs a program and returns its stdout. Blocking: call from a background task.
    /// `acceptFailure` is for programs that report errors as output with a non-zero exit, like the claude CLI.
    /// shortcut: a timeout or a stop ends the program itself but not processes it started; those run on, and what they
    /// print later is lost. Give the program its own process group if that ever matters.
    public static func run(
        _ executable: String, _ arguments: [String],
        env: [String: String]? = nil, cwd: URL? = nil, timeout: TimeInterval, acceptFailure: Bool = false, stop: Stop? = nil
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
        // Signalled when the program has ended. Whoever is woken by it passes it on, so every thread below ends with the program.
        let over = DispatchSemaphore(value: 0)
        // Asked nicely first; a program that ignores that is killed two seconds later.
        // The waiting is done on threads of their own and not on a queue: callers wait in here on pooled threads, and on a
        // machine with few cores those can all be taken, after which nothing queued runs and no timeout would ever come.
        let end = { @Sendable in
            process.terminate()
            Thread.detachNewThread {
                if over.wait(timeout: .now() + 2) == .success { over.signal() } else if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        // Its own flag: a program that handles the signal exits like any other, and one that crashes was not timed out.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        Thread.detachNewThread {
            if over.wait(timeout: .now() + timeout) == .success {
                over.signal()
            } else if process.isRunning {
                timedOut.withLock { $0 = true }
                end()
            }
        }
        stop?.attach(end)
        // Read on a thread of its own, so that `run` is bound to the program and not to its output: a process the
        // program started can hold that open long after the program has ended.
        let read = OSAllocatedUnfairLock(initialState: Data()), closed = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            while case let part = out.fileHandleForReading.availableData, !part.isEmpty { read.withLock { $0.append(part) } }
            closed.signal()
        }
        process.waitUntilExit()
        over.signal()
        _ = closed.wait(timeout: .now() + 2)
        let data = read.withLock { $0 }
        let name = URL(fileURLWithPath: executable).lastPathComponent
        if stop?.asked == true { throw Failure(errorDescription: "\(name) was stopped.", output: data) }
        if timedOut.withLock({ $0 }) { throw Failure(errorDescription: "\(name) timed out after \(Int(timeout)) s.", output: data) }
        guard process.terminationReason == .exit else {
            throw Failure(errorDescription: "\(name) was stopped by signal \(process.terminationStatus).", output: data)
        }
        guard process.terminationStatus == 0 || (acceptFailure && !data.isEmpty) else {
            throw Failure(errorDescription: "\(name) exited with status \(process.terminationStatus).", output: data)
        }
        return data
    }

    /// The environment of the user's interactive login shell. Apps started from Finder do not inherit
    /// variables exported in .zshrc/.zprofile, and that is where telemetry opt-outs live.
    /// nil when the shell could not be asked, so the caller can say that variable-based verdicts may be wrong.
    public static func loginEnvironment() -> [String: String]? {
        let shell = ShellProfile.loginShell.isEmpty ? "/bin/zsh" : ShellProfile.loginShell, marker = "__KANARIE_ENV__"
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
