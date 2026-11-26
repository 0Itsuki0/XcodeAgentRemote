//
//  ICloudManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/17.
//

import CloudKit
import Synchronization

nonisolated private let logger = Logger.shared
nonisolated private let category = Logger.category(#fileID)

/// Using iCloud / CloudKit for sending Push Notifications between MacOS and iOS
/// Not tied to an actor: the mutable state is kept behind a lock.
nonisolated final class ICloudManager: Sendable {

    enum RecordType: String, Sendable {
        case pushToIOS = "PushToIOS"
    }

    enum PushToIOSRecordKey: String, Sendable, CaseIterable {
        case title = "Title"
        case subtitle = "Subtitle"
        case body = "Body"
        case conversationId = "ConversationID"
    }

    private static let containerIdentifier =
        "iCloud.itsuki.enjoy.xcodeAgentRemote"

    private let container = CKContainer(
        identifier: ICloudManager.containerIdentifier
    )

    private var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    private struct State {
        var accountStatus: CKAccountStatus = .couldNotDetermine
        var subscriptions: Set<RecordType> = []
        var failedSavingRecords: Set<CKRecord> = []
        var failedDeletingRecords: Set<CKRecord.ID> = []
    }

    private let state = Mutex(State())
    var accountStatus: CKAccountStatus { state.withLock { $0.accountStatus } }
    var subscriptions: Set<RecordType> { state.withLock { $0.subscriptions } }

    private let accountTask = Mutex<Task<Void, Never>?>(nil)

    private let networkMonitor = NetworkMonitor()

    private static let subscriptionIdPrefix =
        "XcodeAgentRemote.query.subscription."

    private static func subscriptionId(for type: RecordType) -> String {
        return "\(subscriptionIdPrefix)\(type.rawValue)"
    }

    #if os(macOS)
        private let chatHistoryChangeToken = Mutex<
            NotificationCenter.ObservationToken?
        >(nil)
    #endif

    private let connectivityChangeToken = Mutex<
        NotificationCenter.ObservationToken?
    >(nil)

    init() {
        self.updateAccountStatus()
        self.watchForAccountChange()

        let connectivityToken = NotificationCenter.default
            .addObserver(
                of: Never.self,
                for: .connectivityDidChange
            ) { [weak self] message in
                guard let self, message.isConnected else { return }
                self.retryFailedRecords()
            }
        self.connectivityChangeToken.withLock { $0 = connectivityToken }

        #if os(macOS)
            let token = NotificationCenter.default
                .addObserver(
                    of: Never.self,
                    for: .chatHistoryDidChange
                ) { [weak self] message in
                    guard let self else { return }
                    self.handleChatHistoryDidChange(
                        conversation: message.conversation,
                        chatEvent: message.chatEvent
                    )
                }
            self.chatHistoryChangeToken.withLock { $0 = token }
        #endif
    }

    deinit {
        self.accountTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func setAccountStatus(_ status: CKAccountStatus) {
        self.state.withLock { $0.accountStatus = status }
        #if os(iOS)
            self.subscribe(to: .pushToIOS)
        #endif
        self.retryFailedRecords()
    }

    private func checkCommon() -> Bool {
        let accountStatus = self.accountStatus
        guard accountStatus == .available else {
            logger.info(
                category: category,
                message:
                    "iCloud account not available. \(accountStatus.stringRepresentation)"
            )
            return false
        }
        guard networkMonitor.isConnected else {
            logger.info(category: category, message: "Network not available.")
            return false
        }
        return true
    }

    private func retryFailedRecords() {
        guard checkCommon() else { return }

        let (savingRecords, deletingRecords) = self.state.withLock { state in
            let saving = state.failedSavingRecords
            state.failedSavingRecords.removeAll()
            let deleting = state.failedDeletingRecords
            state.failedDeletingRecords.removeAll()
            return (saving, deleting)
        }

        Task {
            do {
                /// When adding a record for the first time (in sandbox / development env),
                /// CloudKit add record type to the schema automatically before saving the record.
                /// If the record type already exists in the schema, iCloud uses the existing type.
                let (saved, deleted) = try await self.privateDatabase
                    .modifyRecords(
                        saving: Array(savingRecords),
                        deleting: Array(deletingRecords),
                        /// If true, the entire operation fails if CloudKit can’t modify one or more of the specified records;
                        /// otherwise, CloudKit reports individual failures in the returned tuple.
                        /// Atomic changes are only applicable in record zones that have the atomic capability.
                        atomically: false
                    )

                let savedSuccess = saved.compactMapValues { try? $0.get() }
                    .map(\.key)

                let deleteSuccess = deleted.compactMapValues { try? $0.get() }
                    .map(\.key)

                let failedSave = savingRecords.filter {
                    !savedSuccess.contains($0.recordID)
                }

                let failedDelete = deletingRecords.filter {
                    !deleteSuccess.contains($0)
                }

                self.state.withLock { state in
                    state.failedSavingRecords.formUnion(failedSave)
                    state.failedDeletingRecords.formUnion(failedDelete)
                }
            } catch {
                logger.error(category: category, error: error)
                self.state.withLock { state in
                    state.failedSavingRecords.formUnion(savingRecords)
                    state.failedDeletingRecords.formUnion(deletingRecords)
                }
            }
        }
    }

    private func updateAccountStatus() {
        Task {
            do {
                let status = try await container.accountStatus()
                self.setAccountStatus(status)
            } catch {
                logger.error(category: category, error: error)
                self.setAccountStatus(.temporarilyUnavailable)
            }
        }
    }

    private func deleteSubscription(_ id: String) async throws {
        guard checkCommon() else { return }
        try await self.privateDatabase.deleteSubscription(withID: id)
    }

    static func recordTypeFromSubscriptionId(_ id: String?) -> RecordType? {
        guard let id else { return nil }
        guard id.hasPrefix(subscriptionIdPrefix) else { return nil }
        let raw = id.dropFirst(subscriptionIdPrefix.count)
        return RecordType(rawValue: String(raw))
    }

    static func extractConversationId(
        from queryNotification: CKQueryNotification
    ) -> String? {
        return queryNotification.recordFields?[
            PushToIOSRecordKey.conversationId.rawValue
        ] as? String
    }

    private static func subscriptionOptions(for type: RecordType)
        -> CKQuerySubscription.Options
    {
        switch type {
        case .pushToIOS:
            /// Each new push is a new record.
            [.firesOnRecordCreation]
        }
    }

    /// Make sure the record type is deployed before subscribing.
    /// Otherwise, the subscription may fail silently.
    private func subscribe(to type: RecordType) {
        guard !self.state.withLock({ $0.subscriptions.contains(type) }) else {
            return
        }
        guard checkCommon() else { return }

        logger.info(category: category, message: "Subscribe to \(type)")

        let notificationInfo = Self.buildNotificationInfo(for: type)

        let querySubscription = CKQuerySubscription(
            recordType: type.rawValue,
            predicate: .truePredicate,
            subscriptionID: Self.subscriptionId(for: type),
            options: Self.subscriptionOptions(for: type)
        )

        querySubscription.notificationInfo = notificationInfo

        Task {
            do {
                let _ = try await self.privateDatabase.save(
                    querySubscription
                )
                self.state.withLock { _ = $0.subscriptions.insert(type) }
            } catch {
                logger.error(category: category, error: error)
            }
        }
    }

    /// https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class
    private static func buildNotificationInfo(for type: RecordType)
        -> CKSubscription.NotificationInfo
    {
        /// common notification info configuration
        let notificationInfo = CKSubscription.NotificationInfo()

        /// set `shouldSendContentAvailable` to `true` to have the system to wake or launch an app that isn’t currently running
        notificationInfo.shouldSendContentAvailable = true
        /// set any other properties other than `shouldSendContentAvailable`
        /// so that CloudKit treats the notification as high-priority and show the push notification.
        notificationInfo.soundName = "default"
        notificationInfo.shouldBadge = true

        switch type {
        case .pushToIOS:
            updateNotificationInfoForPushToIOS(notificationInfo)
        }

        return notificationInfo
    }

    private static func updateNotificationInfoForPushToIOS(
        _ notificationInfo: CKSubscription.NotificationInfo
    ) {
        /// The names of fields to include in the push notification’s payload
        notificationInfo.desiredKeys = PushToIOSRecordKey.allCases.map(
            \.rawValue
        )

        /// title
        notificationInfo.titleLocalizationArgs = [
            PushToIOSRecordKey.title.rawValue
        ]
        notificationInfo.titleLocalizationKey = "%@"

        /// subtitle
        notificationInfo.subtitleLocalizationArgs = [
            PushToIOSRecordKey.subtitle.rawValue
        ]
        notificationInfo.subtitleLocalizationKey = "%@"

        /// alert body
        notificationInfo.alertLocalizationArgs = [
            PushToIOSRecordKey.body.rawValue
        ]
        notificationInfo.alertLocalizationKey = "%@"

    }

    func deleteRecord(_ recordId: CKRecord.ID) {
        guard checkCommon() else { return }

        Task {
            do {
                try await privateDatabase.deleteRecord(withID: recordId)
            } catch {
                logger.error(category: category, error: error)
                self.state.withLock {
                    _ = $0.failedDeletingRecords.insert(recordId)
                }
            }
        }
    }
}

nonisolated extension NSPredicate {
    static var truePredicate: NSPredicate {
        NSPredicate(format: "TRUEPREDICATE")
    }
}

nonisolated extension ICloudManager {
    func watchForAccountChange() {
        let task = Task { [weak self, container] in
            for await _ in NotificationCenter.default.notifications(
                named: .CKAccountChanged,
                object: container
            ) {
                guard let self else { return }
                self.updateAccountStatus()
            }
        }
        self.accountTask.withLock { $0 = task }
    }
}

#if os(macOS)
    nonisolated extension ICloudManager {
        private func handleChatHistoryDidChange(
            conversation: XcodeConversationDetail,
            chatEvent: ChatEvent
        ) {
            print(#function)
            let subtitle = "[\(conversation.project.name)] \(conversation.name)"

            switch chatEvent {
            case .assistantMessage(let message):
                self.sendPushToIOS(
                    title: "New message",
                    subtitle: subtitle,
                    body: message,
                    conversationId: conversation.id
                )
            case .userRequest(let request):
                switch request {
                case .permission(let permission):
                    self.sendPushToIOS(
                        title: "New permission request",
                        subtitle: subtitle,
                        body: permission.jsonInput,
                        conversationId: conversation.id
                    )
                case .questions(_, let questions):
                    self.sendPushToIOS(
                        title: "New questions",
                        subtitle: subtitle,
                        body: questions.map(\.question).joined(separator: "\n"),
                        conversationId: conversation.id
                    )
                case .planApproval(_, let plan):
                    self.sendPushToIOS(
                        title: "New plan",
                        subtitle: subtitle,
                        body: plan,
                        conversationId: conversation.id
                    )
                }
            default:
                return
            }
        }

        /// send a push notification to iOS by creating and saving a new record of type `RecordType.pushToIOS`
        func sendPushToIOS(
            title: String,
            subtitle: String,
            body: String,
            conversationId: String
        ) {
            /// Saving a record works only if the user has signed into their iCloud account on their device.
            guard checkCommon() else { return }

            let record = CKRecord(recordType: RecordType.pushToIOS.rawValue)
            record.setValuesForKeys([
                PushToIOSRecordKey.title.rawValue: title,
                PushToIOSRecordKey.subtitle.rawValue: subtitle,
                PushToIOSRecordKey.body.rawValue: body,
                PushToIOSRecordKey.conversationId.rawValue: conversationId,
            ])

            Task {
                do {
                    /// When adding a record for the first time (in sandbox / development env),
                    /// CloudKit add record type to the schema automatically before saving the record.
                    /// If the record type already exists in the schema, iCloud uses the existing type.
                    let _ = try await self.privateDatabase.save(record)
                } catch {
                    logger.error(category: category, error: error)
                    self.state.withLock {
                        _ = $0.failedSavingRecords.insert(record)
                    }
                }
            }
        }

    }
#endif

nonisolated extension CKAccountStatus {
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
