//
//  ICloudManager.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/17.
//

import CloudKit

private let logger = Logger.shared
private let category = Logger.category(#fileID)

class ICloudManager {

    enum RecordType: String, Sendable {
        case pushToIOS = "PushToIOS"
    }

    enum PushToIOSRecordKey: String, Sendable, CaseIterable {
        case title = "Title"
        case subtitle = "Subtitle"
        case body = "Body"
        case conversationId = "ConversationID"
    }

    static let containerIdentifier =
        "iCloud.itsuki.enjoy.xcodeAgentRemote"

    private static let databaseSubscriptionId: String =
        "database.subscription"

    private let container = CKContainer(
        identifier: ICloudManager.containerIdentifier
    )

    private var privateDatabase: CKDatabase {
        container.privateCloudDatabase
    }

    private(set) var accountStatus: CKAccountStatus = .couldNotDetermine {
        didSet {
            #if os(iOS)
                self.subscribe(to: .pushToIOS)
            #endif
        }
    }

    private var accountTask: Task<Void, Never>?
    private(set) var subscriptions: Set<RecordType> = []

    private var failedSavingRecords: Set<CKRecord> = []
    private var failedDeletingRecords: Set<CKRecord.ID> = []

    private let networkMonitor = NetworkMonitor()

    init() {
        self.updateAccountStatus()
        self.watchForAccountChange()
    }

    private func checkCommon() -> Bool {
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
                self.failedSavingRecords.insert(record)
            }
        }
    }

    private func retryFailedRecords() {
        guard checkCommon() else { return }

        let savingRecords = self.failedSavingRecords
        self.failedSavingRecords.removeAll()

        let deletingRecords = self.failedDeletingRecords
        self.failedDeletingRecords.removeAll()

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
                let savedSuccess =
                    saved
                    .compactMapValues { try? $0.get() }
                    .map(\.key)

                let deleteSuccess =
                    deleted
                    .compactMapValues { try? $0.get() }
                    .map(\.key)

                let failedSave = savingRecords.filter {
                    !savedSuccess.contains($0.recordID)
                }

                let failedDelete = deletingRecords.filter {
                    !deleteSuccess.contains($0)
                }

                self.failedSavingRecords = failedSave
                self.failedDeletingRecords = failedDelete

            } catch {
                logger.error(category: category, error: error)
                self.failedSavingRecords = savingRecords
                self.failedDeletingRecords = deletingRecords
            }
        }
    }

    private func updateAccountStatus() {
        Task {
            do {
                self.accountStatus = try await container.accountStatus()
            } catch {
                logger.error(category: category, error: error)
                self.accountStatus = .temporarilyUnavailable
            }
        }
    }

    private func deleteSubscription(_ id: String) async throws {
        guard checkCommon() else { return }

        try await self.privateDatabase.deleteSubscription(
            withID: Self.databaseSubscriptionId
        )
    }

    private func addSubscription(for record: RecordType) async throws {
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

    private static func subscriptionId(for type: RecordType) -> String {
        return "XcodeAgentRemote.query.subscription.\(type.rawValue)"
    }

    private static func subscriptionOptions(for type: RecordType)
        -> CKQuerySubscription.Options
    {
        switch type {
        case .pushToIOS:
            [.firesOnRecordCreation]
        }
    }

    /// Make sure the record type is deployed before subscribing.
    /// Otherwise, the subscription may fail silently.
    private func subscribe(to type: RecordType) {
        guard !self.subscriptions.contains(type) else { return }
        guard checkCommon() else { return }

        print("\(#function)")

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
                self.subscriptions.insert(type)
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
            updateForPushToIOS(notificationInfo)
        }

        return notificationInfo
    }

    private static func updateForPushToIOS(
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
}

extension NSPredicate {
    static var truePredicate: NSPredicate {
        NSPredicate(format: "TRUEPREDICATE")
    }
}

extension ICloudManager {
    func watchForAccountChange() {
        accountTask = Task {
            for await _ in NotificationCenter.default.notifications(
                named: .CKAccountChanged,
                object: self.container
            ) {
                self.updateAccountStatus()
            }
        }
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
