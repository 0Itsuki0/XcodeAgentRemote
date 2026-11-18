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
    
    var body: some View {
        NavigationStack {
            VStack {
                Button("PUSH") {
                }
#if os(macOS)
                Button("Send test message") {
                    sendTestMessage()
                }
                ScrollView {
                    Text(sendMessageOutput.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
#endif
            }
            .navigationTitle("Push Without Server")
        }
        
    }
    
#if os(macOS)
    /// Sends a test prompt to an existing chat of this project and lists the streamed events.
    private func sendTestMessage() {
        sendMessageOutput = []
        let project = URL(
            filePath: "/Users/itsuki/Desktop/XcodeAgentRemote/XcodeAgentRemote.xcodeproj"
        )
        let target = MessageTarget.conversation(
            id: "D868CB20-1251-4ECC-9047-041C449419CB",
            project: project
        )
        Task {
            do {
                for try await event in sendMessage("Reply with only the word pong.", to: target) {
                    sendMessageOutput.append(String(describing: event))
                }
                print(sendMessageOutput.joined())
            } catch {
                sendMessageOutput.append("error: \(error.localizedDescription)")
            }
        }
    }
#endif
    
}

private struct NavigationViewWrapper<Content: View>: View {
    let content: () -> Content
    
    var body: some View {
#if os(macOS)
        NavigationSplitView {
            content()
        } detail: {
            Text("Select an item")
        }
#else
        NavigationStack {
            content()
        }
#endif
    }
}
