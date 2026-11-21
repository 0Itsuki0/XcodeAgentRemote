//
//  XcodeAgentRemote_iOSApp.swift
//  XcodeAgentRemote-iOS
//
//  Created by Itsuki on 2026/11/15.
//

import SwiftData
import SwiftUI

@main
struct XcodeAgentRemote_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let chatManager = XcodeChatManager()
    
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatView.debugUI
                    .environment(chatManager)
            }
        }
    }
}
