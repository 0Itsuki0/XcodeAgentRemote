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
    /// The pid of the ngrok the app started, while it runs: stopped on the next launch if the app was killed first.
    case ngrokProcessID

    case startAPIServerOnAppLaunch
    case startNgrokTunnelOnServerStart

    case apiServerURL
    case iosFirstLaunch

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
