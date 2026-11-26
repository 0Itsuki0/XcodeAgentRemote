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

    private let apiServerManager: APIServerManager
    private let chatWatcher: ChatWatcher
    private let iCloudManager = ICloudManager()

    @Environment(\.openWindow) private var openWindow

    init() {
        let chatWatcher = ChatWatcher()
        let apiServerManager = APIServerManager(
            watchingConversations: { chatWatcher.watchingConversationIds },
            watchConversation: chatWatcher.watchConversation,
            stopWatchingConversation: chatWatcher.stopWatchingConversation
        )
        self.chatWatcher = chatWatcher
        self.apiServerManager = apiServerManager

        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        MenuBarExtra {
            AppMenu()
        } label: {
            Image(systemName: "cloud.fill")
                .onAppear {
                    self.openWindow(id: DashboardWindow.identifier)
                }
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: DashboardWindow.identifier) {
            DashboardWindow()
                .environment(apiServerManager)
                .environment(chatWatcher)
        }
        .defaultSize(width: 720, height: 560)
        .restorationBehavior(.automatic)
    }
}

//@main
//struct XcodeAgentRemoteApp: App {
//
//    var body: some Scene {
//
//        Window("Dashboard", id: DashboardWindow.identifier) {
//            ContentView()
//        }
//        .defaultSize(width: 720, height: 560)
//        .restorationBehavior(.automatic)
//    }
//}

struct AppMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack {
            menuButton("Dashboard", systemImage: "rectangle.split.2x1") {
                openWindow(id: DashboardWindow.identifier)
            }

            Divider()

            menuButton("Quit", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(width: 180)

    }

    @ContentBuilder
    private func menuButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        //        Button(title, systemImage: systemImage, action: action)
        //            .frame(maxWidth: .infinity, alignment: .leading)
        //            .contentShape(Rectangle())
        Button {
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
    }
}
