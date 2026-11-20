//
//  LoggerTests.swift
//  XcodeAgentRemoteTests
//
//  Logger writes each line to its file as it is logged, in the order it is logged.
//

import Foundation
import Testing
@testable import XcodeAgentRemote

struct LoggerTests {

    @Test func linesWrittenInOrder() throws {
        let run = UUID().uuidString
        let count = 200
        for index in 0..<count {
            Logger.shared.info(category: "LoggerTests", message: "\(run) \(index)")
        }
        // Written as logged: the lines are in the file right away, in order.
        let lines = try String(contentsOf: Logger.shared.filePath, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { LogMessage.fromJsonString(String($0)) }
            .filter { $0.message.hasPrefix(run) }
            .map(\.message)
        #expect(lines == (0..<count).map { "\(run) \($0)" })
    }
}
