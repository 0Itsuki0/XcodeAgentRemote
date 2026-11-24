//
//  UserDefaultsKey.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/01/22.
//

import Foundation

nonisolated enum UserDefaultsKey: String, CaseIterable {
    case startAppOnSystemLaunch

    case apiServerPort
    case apiServerAuthHeaderName
    case apiServerAuthHeaderValue
    case apiServerUseAuth
    case ngrokURL

    case startAPIServerOnAppLaunch
    case startNgrokTunnelOnServerStart

    case apiServerURL

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
