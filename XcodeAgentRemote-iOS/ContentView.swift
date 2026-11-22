//
//  ContentView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import CloudKit
import SwiftData
import SwiftUI

//@Observable class AppViewRouter {
//
//}

struct ContentView: View {
    @Environment(ServerSettingManager.self) private var serverSettingManager
    @State private var showSettings: Bool = false

    var body: some View {
        Group {
            if let apiClient = serverSettingManager.apiClient {
                ProjectListView(apiClient: apiClient)
            } else {
                ContentUnavailableView {
                    Label("Server not configured", systemImage: "server.rack")
                } description: {
                    Text(
                        "Please set up the configuration parameters for your Mac server."
                    )
                } actions: {
                    Button("Settings") {
                        // TODO: - show server settings directly instead of top settings
                        showSettings = true
                    }
                }
            }
        }
        .navigationTitle("Chat Projects")
        .navigationSubtitle("Xcode projects with conversations")
        .toolbarTitleDisplayMode(.inlineLarge)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape") {
                    showSettings = true
                }
            }
        }
        .labelStyle(.iconOnly)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(serverSettingManager)
        }
    }
}

struct ProjectListView: View {
    //    @Environment(XcodeChatManager.self) private var chatManager
    init(apiClient: APIServerClient) {
        self.projectViewModel = ProjectViewModel(apiClient: apiClient)
    }
    @State private var projectViewModel: ProjectViewModel
    var body: some View {
        List {
            NavigationLink {
                ChatView.debugUI()
            } label: {
                Text("Dummy chat")
            }

        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .task {
            print("ProjectListView task")
            //            await chatManager.loadProjects()
        }
        .refreshable {
            //            await chatManager.loadProjects()
        }
    }
}
