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
    #if os(iOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #else
        @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

//    var sharedModelContainer: ModelContainer = {
//        let schema = Schema([
//            ItemModel.self
//        ])
//        let modelConfiguration = ModelConfiguration(
//            schema: schema,
//            cloudKitDatabase: .private(ICloudManager.containerIdentifier)
//        )
//
//        do {
//            return try ModelContainer(
//                for: schema,
//                configurations: [modelConfiguration]
//            )
//        } catch {
//            fatalError("Could not create ModelContainer: \(error)")
//        }
//    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
//        .modelContainer(sharedModelContainer)
    }
}
