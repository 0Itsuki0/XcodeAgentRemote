//
//  Logging.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2025/12/18.
//

import OSLog
import SwiftUI
import Synchronization

nonisolated private let logger = os.Logger(
    subsystem: Logger.subsystem,
    category: "ApplicationLog"
)

/// Logs to the console (`os.Logger`) and to a file. Each line is written as it is logged, in the order it is logged:
/// the file is kept behind a lock (writing a line never waits on anything).
nonisolated final class Logger: Sendable {
    nonisolated static let subsystem = "itsuki.enjoy.XcodeAgentRemote"

    static let shared = Logger()

    private static let baseURL: URL = URL.temporaryDirectory

    private static let directory: URL = baseURL.appending(
        path: "Swiftly/Logs"
    )
    private static let fileExtension = "txt"
    let filePath: URL

    /// The log file; nil if it could not be opened (then each line is written to `filePath` directly).
    private let fileHandle: Mutex<FileHandle?>

    private init() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Self.directory.path) {
            do {
                try fileManager.createDirectory(
                    at: Self.directory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                logger.error(
                    "Error creating directory: \(error.localizedDescription)"
                )
            }
        }

        let fileSafeISOString = Date().formatted(
            .iso8601.year().month().day().timeZone(separator: .omitted).time(
                includingFractionalSeconds: false
            ).timeSeparator(.omitted)
        )

        self.filePath = Self.directory.appending(
            path: "\(fileSafeISOString).\(Self.fileExtension)"
        )
        if !fileManager.fileExists(atPath: filePath.path) {
            fileManager.createFile(atPath: filePath.path, contents: nil)
        }

        logger.info("Log file written to \(self.filePath, privacy: .public)")
        do {
            self.fileHandle = Mutex(try FileHandle(forWritingTo: self.filePath))
        } catch (let error) {
            logger.error("\(error.localizedDescription)")
            self.fileHandle = Mutex(nil)
        }

        Task.detached {
            // when log file count is large, could eventually block and therefore spawn to Task
            Self.removeOldLogFiles()
        }
    }

    deinit {
        fileHandle.withLock { try? $0?.close() }
    }

    func info(category: String, message: String) {
        logger.info(
            "\(Date().formatted()) info [\(category, privacy: .public)] \(message, privacy: .public)"
        )
        writeLog(category: category, message: message, level: .info)
    }

    func error(category: String, error: Error) {
        let message = error.localizedDescription
        logger.error(
            "\(Date().formatted()) error [\(category, privacy: .public)] \(message, privacy: .public)"
        )
        writeLog(category: category, message: message, level: .error)
    }

    private func writeLog(
        category: String,
        message: String,
        level: LogLevel
    ) {
        let log: LogMessage = .init(
            level: level,
            category: category,
            message: message
        )
        var message: String = """
            "time": "\(Date().ISO8601Format())", "level": "\(level)", "category": "\(category)", "msg": "\(message)"
            """
        if let jsonString = log.jsonString {
            message = jsonString
        }
        message = message + "\n"

        fileHandle.withLock { fileHandle in
            if let fileHandle {
                fileHandle.seekToEndOfFile()
                fileHandle.write(message.data)
            } else {
                try? message.data.write(to: self.filePath, options: .atomicWrite)
            }
        }
    }

    // remove log files > 30 days
    static private func removeOldLogFiles() {
        let oldLogs = allLogFiles.filter({
            abs($0.createdAt.timeIntervalSinceNow) > 30.0 * 24.0 * 60.0 * 60.0
        })
        let fileManager = FileManager.default
        for log in oldLogs {
            try? fileManager.removeItem(at: log)
        }
    }
}

nonisolated extension Logger {
    static func category(_ fileId: String) -> String {
        return fileId.split(separator: "/").last.map(String.init) ?? fileId
    }

    private static var allLogFiles: [URL] {
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: Self.directory,
                includingPropertiesForKeys: [
                    .creationDateKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles]
            )) ?? []

        return Array(Set(items)).filter({
            $0.pathExtension == Self.fileExtension
        }).filter {
            url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true
        }
        .sorted { a, b in
            return a.createdAt > b.createdAt  // newest first
        }
    }
}

nonisolated struct LogMessage: Codable {
    var time: String = Date().ISO8601Format()
    var level: LogLevel
    var category: String
    var message: String

    var jsonString: String? {
        let encoder = JSONEncoder()

        if let data = try? encoder.encode(self),
            let jsonString = String(data: data, encoding: .utf8)
        {
            return jsonString
        }
        return nil
    }

    static func fromJsonString(_ string: String) -> LogMessage? {
        let data = Data(string.utf8)
        let decoder = JSONDecoder()
        return try? decoder.decode(LogMessage.self, from: data)
    }
}

nonisolated enum LogLevel: String, Codable {
    case info
    case error
}

nonisolated extension String {
    var data: Data {
        return Data(self.utf8)
    }
}

nonisolated extension URL {
    var createdAt: Date {
        (try? self.resourceValues(forKeys: [.creationDateKey]))?
            .creationDate ?? Date.distantPast
    }
}
