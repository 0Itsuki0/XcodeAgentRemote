//
//  RunningSessions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation
import Synchronization

/// The sessions the app is running a turn in now (by session id), from the start of the turn until it is recorded
/// (`XcodeChat.runTurn`). One turn per session at a time: another message to that chat is refused meanwhile.
/// A tool use with no result in one of them is the app's own: its requests are marked (`PendingToolUses`), so Xcode's
/// permission check (`PermissionRule`) is not used.
nonisolated enum RunningSessions {
    private static let ids = Mutex<Set<String>>([])

    // Kept lowercased, and looked up lowercased (`ChatStore.sameID`): the id may be cased differently.
    /// Adds the session; false if it was running already (checked and added at once).
    @discardableResult
    static func insert(_ sessionID: String) -> Bool {
        ids.withLock { $0.insert(sessionID.lowercased()).inserted }
    }
    static func remove(_ sessionID: String) {
        ids.withLock { _ = $0.remove(sessionID.lowercased()) }
    }
    static func contains(_ sessionID: String) -> Bool {
        ids.withLock { $0.contains(sessionID.lowercased()) }
    }
}
