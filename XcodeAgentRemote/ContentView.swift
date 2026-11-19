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
//    @Environment(\.modelContext) private var modelContext
//    @Query private var items: [ItemModel]
    @State private var sendMessageOutput: [String] = []
    @State private var runningCommand: CommandExecutor.RunningCommand?
    private let server = APIServer()
    private let iCloudManager = ICloudManager()

    var body: some View {
        NavigationStack {
            VStack {
                Button("PUSH") {
                    //                    addItem()
                    iCloudManager.sendPushToIOS(
                        title: "test",
                        subtitle: Date().ISO8601Format(),
                        body: "some body",
                        conversationId: "123"
                    )
                }

                Button("Start server") {
                    Task {
                        do {
                            try await server.start()
                        } catch {
                            print("error starting server: ", error)
                        }
                    }
                }

                Button("stop server") {
                    Task {
                        await server.stop()
                    }
                }

                Button("test command") {
                    Task {
                        print(
                            CommandExecutor.runCommand(["ngrok", "http", "-h"])
                                ?? "fail to get a result"
                        )
                        print(
                            CommandExecutor.runCommand(["ngrok", "http", "80"])
                                ?? "fail to get a result"
                        )

                    }
                }

                Button("test command stream") {
                    Task {
                        do {
                            let command = try CommandExecutor.runCommandStream(
                                ["sh", "-c", "for i in 1 2 3 4 5 6 7 8 9 10; do echo \"line $i\"; sleep 1; done"]
                            )
                            runningCommand = command
                            for try await line in command.outputLines {
                                print(String(decoding: line, as: UTF8.self))
                            }
                            await command.waitUntilExit()
                            print("exited")
                        } catch {
                            print("error: ", error)
                        }
                        runningCommand = nil
                    }
                }

                Button("terminate command") {
                    runningCommand?.terminate()
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
            .onAppear {
                //                print(#fileID, #file, #filePath, fileName(#fileID))
            }
        }

    }

    #if os(macOS)
        /// Sends a test prompt to an existing chat of this project and lists the streamed events.
        private func sendTestMessage() {
            sendMessageOutput = []
            let project = URL(
                filePath:
                    "/Users/itsuki/Desktop/XcodeAgentRemote/XcodeAgentRemote.xcodeproj"
            )
            let target = MessageTarget.conversation(
                id: "D868CB20-1251-4ECC-9047-041C449419CB",
                project: project
            )
            Task {
                do {
                    for try await event in sendMessage(
                        "Reply with only the word pong.",
                        to: target
                    ) {
                        sendMessageOutput.append(String(describing: event))
                    }
                    print(sendMessageOutput.joined())
                } catch {
                    sendMessageOutput.append(
                        "error: \(error.localizedDescription)"
                    )
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

//#Preview {
//    ContentView()
//        .modelContainer(for: Item.self, inMemory: true)
//}
