//
//  XcodeAgentRemoteApp.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import SwiftData
import SwiftUI

@main
struct XcodeAgentRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    private let apiServer = APIServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
//        .modelContainer(sharedModelContainer)
    }
}
