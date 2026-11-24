//
//  Command.swift
//  XcodeAgentRemote
//

import Foundation

/// Running commands (looked up in the login shell's PATH, e.g. `git`, `xcrun`, `ngrok`): to completion for their output
/// (`runCommand`), or with their input and output connected for a back-and-forth over lines (`runCommandStream`).
nonisolated enum CommandExecutor {

    /// The login shell's PATH (what a terminal has), read once. An app started from Finder, the Dock or Xcode gets only
    /// launchd's default (`/usr/bin:/bin:/usr/sbin:/sbin`), without e.g. Homebrew's `/opt/homebrew/bin`.
    /// nil if it could not be read: the app's own PATH is used.
    private static let loginShellPATH: String? = {
        let shell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // A profile may print something before it: the PATH is the last line.
        guard process.terminationStatus == 0,
            let path = String(decoding: data, as: UTF8.self).split(separator: "\n").last, !path.isEmpty
        else { return nil }
        return String(path)
    }()

    /// The app's environment, with the login shell's PATH.
    private static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let loginShellPATH { environment["PATH"] = loginShellPATH }
        return environment
    }

    /// Runs a command (looked up in the login shell's PATH, e.g. `git`, `xcrun`) and returns its output,
    /// or nil if it could not run or exited with a non-zero code.
    static func runCommand(_ arguments: [String], in directory: URL? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a large output (e.g. `git diff`) would otherwise fill the pipe and block the command.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: - A command with its input and output connected

    /// A command started by `runCommandStream`: lines written to its input, its output read line by line.
    struct RunningCommand: Sendable {
        private let process: Process
        private let input: FileHandle
        private let exit: AsyncStream<Void>
        /// Its output, one line at a time (without the "\n"), until it closes its output.
        /// Split on "\n" only, not on other line separators (U+2028 can be inside a JSON string).
        let outputLines: AsyncThrowingStream<Data, Error>

        fileprivate init(process: Process, input: FileHandle, output: FileHandle, exit: AsyncStream<Void>) {
            self.process = process
            self.input = input
            self.exit = exit
            outputLines = AsyncThrowingStream { continuation in
                // Read on a thread of its own, not with `FileHandle.bytes`: that reads every handle in the app on one
                // shared serial queue, so a command that never writes (e.g. ngrok) blocks every other command's output.
                // It ends when the command closes its output (it exited, or was terminated).
                // `availableData` returns as soon as some output arrives (`read(upToCount:)` would wait for that
                // many bytes or the end), and is empty at the end.
                Thread {
                    var line = Data()
                    while case let data = output.availableData, !data.isEmpty {
                        for byte in data {
                            if byte == UInt8(ascii: "\n") {
                                continuation.yield(line)
                                line.removeAll(keepingCapacity: true)
                            } else {
                                line.append(byte)
                            }
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                }.start()
            }
        }

        /// Writes one line (a "\n" is added) to its input. Ignored once it exited.
        func writeLine(_ line: Data) {
            try? input.write(contentsOf: line + [UInt8(ascii: "\n")])
        }

        /// Closes its input (it reads end of file).
        func closeInput() {
            try? input.close()
        }

        func terminate() {
            process.terminate()
        }

        var processIdentifier: Int32 { process.processIdentifier }

        /// Returns once it exited.
        func waitUntilExit() async {
            for await _ in exit {}
        }
    }

    /// Starts a command (looked up in the login shell's PATH, e.g. `xcrun`, `ngrok`) with its input and output connected,
    /// for a back-and-forth over lines (`RunningCommand`). Its error output goes where the app's does. `onExit` runs once
    /// it exits. Throws if it could not start.
    static func runCommandStream(
        _ arguments: [String], in directory: URL? = nil, onExit: @escaping @Sendable () -> Void = {}
    ) throws -> RunningCommand {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        let (exit, exitContinuation) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            onExit()
            exitContinuation.finish()
        }
        // Writing after the command exited fails instead of killing the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        return RunningCommand(
            process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading, exit: exit)
    }
}
