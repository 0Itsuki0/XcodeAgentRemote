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
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [ItemModel]
    @State private var sendMessageOutput: [String] = []
    
    var body: some View {
        //        NavigationViewWrapper {
        //            List {
        //                ForEach(items) { item in
        //                    NavigationLink {
        //                        Text(
        //                            "Item at \(item.timestamp, format: Date.FormatStyle(date: .numeric, time: .standard))"
        //                        )
        //                    } label: {
        //                        Text(
        //                            item.timestamp,
        //                            format: Date.FormatStyle(
        //                                date: .numeric,
        //                                time: .standard
        //                            )
        //                        )
        //                    }
        //                    .contextMenu {
        //                        Button("delete") {
        //                            modelContext.delete(item)
        //                            try? modelContext.save()
        //                        }
        //                    }
        //
        //                }
        //                .onDelete(perform: deleteItems)
        //            }
        //            #if os(macOS)
        //                .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        //            #endif
        //            .toolbar {
        //                #if os(iOS)
        //                    ToolbarItem(placement: .navigationBarTrailing) {
        //                        EditButton()
        //                    }
        //                #endif
        //                ToolbarItem {
        //                    Button(action: addItem) {
        //                        Label("Add Item", systemImage: "plus")
        //                    }
        //                }
        //            }
        //            .task {
        //                let descriptor = FetchDescriptor<ItemModel>()
        //                print((try? modelContext.fetch(descriptor)) ?? [])
        //            }
        //            .navigationTitle("Push Without Server")
        //        }
        NavigationStack {
            VStack {
                Button("PUSH") {
                    addItem()
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
    
    private func addItem() {
        let newItem = ItemModel(timestamp: Date())
        modelContext.insert(newItem)
        try? modelContext.save()
    }
    
    private func deleteItems(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(items[index])
            try? modelContext.save()
        }
    }
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

class CloudManager {
    static let containerIdentifier =
    "iCloud.itsuki.enjoy.xcodeAgentRemote"
    
    private static let recordType: String = "AgentConversation"
    private static let databaseSubscriptionId: String =
    "database.subscription"
    
    private let container = CKContainer(
        identifier: CloudManager.containerIdentifier
    )
    
    private var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }
    //
    //    private var defaultZone: CKRecordZone {
    //        get async throws { try await privateDatabase.recordZone(for: .default) }
    //    }
    
    var accountStatus: CKAccountStatus = .couldNotDetermine
    
    //    private var databaseSubscription: CKSubscription?
    
    init() {
        
        Task {
            do {
                try await checkAccountStatus()
                try await self.privateDatabase.deleteSubscription(
                    withID: Self.databaseSubscriptionId
                )
                //                try await addDatabaseSubscription()
                try await self.addRecordSubscription()
            } catch {
                print("Error: ", error.localizedDescription)
            }
        }
        //        self.accountStatus = accountStatus
        //        self.databaseSubscription = databaseSubscription
    }
    
    private func checkAccountStatus() async throws {
        self.accountStatus = try await container.accountStatus()
        print("Account status: \(accountStatus.stringRepresentation)")
        if self.accountStatus != .available {
            //            throw _Error.iCloudAccountUnavailable
        }
    }
    
    private func addDatabaseSubscription() async throws {
        print("\(#function)")
        
        /// https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class
        let notificationInfo = CKSubscription.NotificationInfo()
        /// set `shouldSendContentAvailable` to `true` to have the system to wake or launch an app that isn’t currently running
        notificationInfo.shouldSendContentAvailable = true
        /// set any other properties other than `shouldSendContentAvailable`
        /// so that CloudKit treats the notification as high-priority.
        notificationInfo.soundName = "default"
        notificationInfo.title = "New message"
        notificationInfo.shouldBadge = true
        
        let databaseSubscription = CKDatabaseSubscription(
            subscriptionID: CloudManager.databaseSubscriptionId
        )
        databaseSubscription.notificationInfo = notificationInfo
        
        /// To  specialize a database subscription to a specific record type,
        /// we can set its `recordType` property accordingly.
        /// `databaseSubscription.recordType = "CD_ItemModel"`
        ///
        /// NOTE: regardless of whether `recordType` is set or not,
        /// `desiredKeys` are not allowed for Database Subscription
        
        /// After the operation completes, record that state on-device (in UserDefaults, for example). You can then check that state on subsequent launches to prevent unnecessary trips to the server.
        let _ = try await self.privateDatabase.save(
            databaseSubscription
        )
    }
    
    private func addRecordSubscription() async throws {
        print("\(#function)")
        
        /// https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class
        let notificationInfo = CKSubscription.NotificationInfo()
        /// set `shouldSendContentAvailable` to `true` to have the system to wake or launch an app that isn’t currently running
        notificationInfo.shouldSendContentAvailable = true
        /// set any other properties other than `shouldSendContentAvailable`
        /// so that CloudKit treats the notification as high-priority.
        notificationInfo.soundName = "default"
        notificationInfo.desiredKeys = ["CD_timestamp"]
        notificationInfo.titleLocalizationArgs = ["CD_timestamp"]
        /// This can also be written as `%@`
        /// If you use %@ for your substitution variables, CloudKit replaces those variables by traversing the array in order.
        /// If you use variables of the form %n$@, where n is an integer, n represents the index (starting at 1) of the item in the array to use.
        notificationInfo.titleLocalizationKey = "Timestamp: %1$@"
        notificationInfo.shouldBadge = true
        
        let truePredicate = NSPredicate(format: "TRUEPREDICATE")
        
        let querySubscription = CKQuerySubscription(
            recordType: "CD_ItemModel",
            predicate: truePredicate,
            subscriptionID: "query.subscription",
            options: [
                .firesOnRecordCreation, .firesOnRecordDeletion,
                .firesOnRecordUpdate,
            ]
        )
        
        querySubscription.notificationInfo = notificationInfo
        
        /// After the operation completes, record that state on-device (in UserDefaults, for example). You can then check that state on subsequent launches to prevent unnecessary trips to the server.
        let _ = try await self.privateDatabase.save(
            querySubscription
        )
    }
    
}

extension CKAccountStatus {
    var stringRepresentation: String {
        switch self {
        case .couldNotDetermine:
            "couldNotDetermine"
        case .available:
            "available"
        case .restricted:
            "restricted"
        case .noAccount:
            "noAccount"
        case .temporarilyUnavailable:
            "temporarilyUnavailable"
        @unknown default:
            "unknown"
        }
    }
}
