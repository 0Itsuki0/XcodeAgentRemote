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

    private let apiServerManager = APIServerManager()
    private let chatWatcher = ChatWatcher()

    var body: some Scene {
        MenuBarExtra {
            AppMenu()
        } label: {
            Image(systemName: "cloud.fill")
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

struct AppMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack {
            menuButton("Dashboard", systemImage: "rectangle.split.2x1") {
                openWindow(id: DashboardWindow.identifier)
            }

            Divider()

            //            Button(
            //                action: {
            //                    NSApplication.shared.terminate(nil)
            //                },
            //                label: {
            //                    Label(String(localized: "Quit", table: localizationTable), systemImage: "power")
            //                }
            //            )

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
