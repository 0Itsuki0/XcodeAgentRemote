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
