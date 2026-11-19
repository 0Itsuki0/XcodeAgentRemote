//
//  XcodeAgentConfiguration.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/19.
//

import Foundation

/// Xcode Agent Configuration
/// - current mode (auto vs manual)
nonisolated extension XcodeAgentConfiguration {

    /// Xcode's permission menu (Manual / Auto), for all chats.
    /// Stored in Xcode's preferences: `com.apple.dt.Xcode` → `IDEChatAgentPermissionMode`.
    enum PermissionMode: String, Sendable {
        case manual = "standard"
        case auto
        /// Options Xcode hides by default.
        case dontAsk
        case bypassPermissions

        /// Xcode's current permission mode; Manual if it is not set.
        static var currentMode: PermissionMode {
            let domain = "com.apple.dt.Xcode" as CFString
            CFPreferencesAppSynchronize(domain)  // re-read: Xcode may have changed it since
            let value =
                CFPreferencesCopyAppValue(
                    "IDEChatAgentPermissionMode" as CFString,
                    domain
                ) as? String
            return value.flatMap(PermissionMode.init(rawValue:)) ?? .manual
        }
    }
}
