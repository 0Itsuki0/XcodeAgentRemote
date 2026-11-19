//
//  UserDefaultsKey.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/01/22.
//

import Foundation

nonisolated enum UserDefaultsKey: String, CaseIterable {
    case apiServerPort

    static var userDefaults: UserDefaults { .standard }

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
