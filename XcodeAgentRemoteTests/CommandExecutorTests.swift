//
//  CommandExecutorTests.swift
//  XcodeAgentRemoteTests
//
//  Commands are looked up in the login shell's PATH, not the app's own (launchd's default for an app started from
//  Finder / the Dock / Xcode). To check that, run the tests with that default PATH:
//  `env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild test … -only-testing:XcodeAgentRemoteTests/CommandExecutorTests`
//

#if os(macOS)
    import Foundation
    import Testing
    @testable import XcodeAgentRemote

    struct CommandExecutorTests {

        /// The login shell's PATH, read the same way a terminal gets it.
        private static var loginShellPATH: String {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-l", "-c", "printf '%s' \"$PATH\""]
            let output = Pipe()
            process.standardOutput = output
            try? process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        /// A command that never writes (like ngrok) doesn't hold up another command's output, and a line arrives as soon
        /// as it is written, while the command keeps running (like the agent waiting for its next input).
        @Test(.timeLimit(.minutes(1))) func linesArriveWhileCommandsRun() async throws {
            let silent = try CommandExecutor.runCommandStream(["sleep", "30"])
            defer { silent.terminate() }
            let talking = try CommandExecutor.runCommandStream(["sh", "-c", "echo hello; sleep 30"])
            defer { talking.terminate() }
            let start = Date()
            var first: String?
            for try await line in talking.outputLines {
                first = String(decoding: line, as: UTF8.self)
                break
            }
            #expect(first == "hello")
            #expect(Date().timeIntervalSince(start) < 5, "the line came only when the command ended")
        }

        @Test func commandsGetTheLoginShellPATH() {
            let path = CommandExecutor.runCommand(["sh", "-c", "printf '%s' \"$PATH\""])
            #expect(path == Self.loginShellPATH)
        }

        @Test func findsHomebrewCommands() throws {
            try #require(FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ngrok"), "ngrok is not installed")
            #expect(CommandExecutor.runCommand(["ngrok", "version"]) != nil)
        }

        @Test func streamFindsHomebrewCommands() async throws {
            try #require(FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ngrok"), "ngrok is not installed")
            let command = try CommandExecutor.runCommandStream(["ngrok", "version"])
            var lines: [String] = []
            for try await line in command.outputLines { lines.append(String(decoding: line, as: UTF8.self)) }
            await command.waitUntilExit()
            #expect(lines.contains { $0.contains("ngrok version") }, "\(lines)")
        }
    }
#endif
