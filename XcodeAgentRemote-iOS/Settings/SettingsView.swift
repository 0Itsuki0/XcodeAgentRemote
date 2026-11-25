//
//  SettingsView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import SwiftUI

enum SettingRoute: String, Equatable, Hashable, CaseIterable, Identifiable {
    case server
    case notification

    var id: String { rawValue }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        ServerSettingView()
                    } label: {
                        Text("Mac Server")
                    }

                    NavigationLink {
                        NotificationSettingView()
                    } label: {
                        Text("Push Notification")
                    }
                }

                Section {
                    // TODO: - add privacy
                    // Button("Privacy", action: {})
                    if let gitHub = URL.gitHub {
                        Link("GitHub", destination: gitHub)
                    }
                }
            }
            .contentMargins(.top, UIConstants.standardTopMargin)
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close", systemImage: "xmark") {
                        self.dismiss()
                    }
                }
            }
            .labelStyle(.iconOnly)
        }
    }
}
