//
//  RunningSessions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation
import Synchronization

/// The sessions whose agent the app is running now (by session id). A tool use with no result in one of them is the
/// app's own: its requests are marked (`PendingToolUses`), so Xcode's permission check (`PermissionRule`) is not used.
nonisolated enum RunningSessions {
    private static let ids = Mutex<Set<String>>([])

    // Kept lowercased, and looked up lowercased (`ChatStore.sameID`): the id may be cased differently.
    static func insert(_ sessionID: String) {
        ids.withLock { _ = $0.insert(sessionID.lowercased()) }
    }
    static func remove(_ sessionID: String) {
        ids.withLock { _ = $0.remove(sessionID.lowercased()) }
    }
    static func contains(_ sessionID: String) -> Bool {
        ids.withLock { $0.contains(sessionID.lowercased()) }
    }
}
