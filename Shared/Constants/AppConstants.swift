//
//  AppConstants.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/27.
//

import Foundation

enum AppConstants {
    static let appVersion =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
}
