//
//  Command.swift
//  XcodeAgentRemote
//

import Foundation

/// Runs a command (looked up in PATH, e.g. `git`, `xcrun`) and returns its output,
/// or nil if it could not run or exited with a non-zero code.
nonisolated func runCommand(_ arguments: [String], in directory: URL? = nil) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/env")
    process.arguments = arguments
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
