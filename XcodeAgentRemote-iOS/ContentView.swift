//
//  ContentView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import CloudKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var sendMessageOutput: [String] = []
    @Environment(XcodeChatManager.self) private var chatManager

    var body: some View {
        NavigationStack {
            VStack {
                Text("\(chatManager.serverConfigurationState)")
                Button("Configure") {
                    chatManager.updateServerConfiguration(
                        url:
                            "https://madison-vernal-unanecdotally.ngrok-free.dev",
                        authHeader: nil
                    )
                }

                Button("Send message") {
//                    chatManager.sendMessage("hey")
                    chatManager.sendMessage("Use the Bash tool to run: touch /tmp/test-scenarios-CCECB3EE-allowed. Then reply DONE.")
                }
            }
            .navigationTitle("Push Without Server")
        }

    }

}
