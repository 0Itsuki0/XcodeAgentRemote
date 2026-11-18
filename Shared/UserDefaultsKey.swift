//
//  UserDefaultsKey.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/01/22.
//

import Foundation

nonisolated enum UserDefaultsKey: String, CaseIterable {
    /// Tool user Id that are requests waiting for user response. By agent.
    /// `[agent: [tool use id]]`: tool use ids are an agent's own, and only that agent's provider reads them.
    case pendingToolUseIdMap
    case apiServerPort

    static let userDefaults = UserDefaults.standard

    var key: String {
        return "XcodeAgentRemote_\(self.rawValue)"
    }

    func setValue(value: Any?) {
        Self.userDefaults.setValue(value, forKey: self.key)
    }

    func getValue() -> Any? {
        return Self.userDefaults.object(forKey: self.key)
    }
}
