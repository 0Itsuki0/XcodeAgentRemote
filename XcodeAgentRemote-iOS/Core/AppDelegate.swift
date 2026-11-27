//
//  AppDelegate.swift
//  iCloudDemo
//
//  Created by Itsuki on 2025/06/01.
//

import CloudKit
import SwiftUI
import UserNotifications

nonisolated private let logger = Logger.shared
nonisolated private let category = Logger.category(#fileID)

@Observable class AppDelegate: NSObject {
    let iCloudManager = ICloudManager()

    var path: NavigationPath = NavigationPath()

    private var observationToken: NotificationCenter.ObservationToken?

    private var selectedConversationId: XcodeConversation.ID?

    private(set) var tappedConversationId: XcodeConversation.ID? = nil

    /// perform set ups
    private func setupAppOnLaunch() {
        UIApplication.shared.registerForRemoteNotifications()

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setBadgeCount(0)

        self.observationToken = NotificationCenter.default.addObserver(
            of: Never.self,
            for: .selectedConversationDidChange
        ) { [weak self] message in
            guard let self else { return }
            self.selectedConversationId = message.conversation?.conversationId

            if let tappedConversationId, let selectedConversationId,
                tappedConversationId == selectedConversationId
            {
                self.tappedConversationId = nil
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }

    private func didRegisterForRemoteNotificationsWithDeviceToken(
        deviceToken: Data
    ) {
        logger.info(
            category: category,
            message: "\(#function). \(deviceToken.base64EncodedString())"
        )
    }

    private func didFailToRegisterForRemoteNotifications(
        _ error: Error
    ) {
        logger.error(category: category, error: error)
    }

    private func didReceiveRemoteNotification(
        userInfo: [AnyHashable: Any]
    ) -> UIBackgroundFetchResult {
        logger.info(
            category: category,
            message: "\(#function)"
        )
        guard
            let notification = CKNotification(
                fromRemoteNotificationDictionary: userInfo
            )
        else {
            return .noData
        }

        logger.info(
            category: category,
            message: "\(notification.debugDescription)"
        )

        /// Sample notification
        /// ```
        /// <CKQueryNotification: 0x109435c00; notificationType=1, notificationID=a04efc92-0dfa-48b0-97e6-4751d6d57d16, containerID=iCloud.xxx:Sandbox, subscriptionOwnerUserRecordID=xxx:(_defaultZone:__defaultOwner__), subscriptionID=XcodeAgentRemote.query.subscription.PushToIOS, queryNotificationReason=1, recordFields={
        ///     Body = "some body";
        ///     ConversationID = 123;
        ///     Subtitle = "2026-11-18T02:30:44Z";
        ///     Title = test;
        /// }, recordID=96E4847D-78BC-4E94-9FD9-CECE02FC8952:(_defaultZone:xxx), database=Private>
        /// ```
        guard let queryNotification = notification as? CKQueryNotification
        else {
            logger.info(
                category: category,
                message: "Unknown notification type."
            )
            return .noData
        }

        guard
            let type = ICloudManager.recordTypeFromSubscriptionId(
                queryNotification.subscriptionID
            )
        else {
            logger.info(category: category, message: "Unknown record type.")
            return .noData
        }

        switch type {
        case .pushToIOS:
            /// delete the record here instead of `userNotificationCenter.didReceive`
            /// in case user never tap on the notification to avoid the records getting piled up.
            ///
            /// we can still retrieve the `CKQueryNotification` with necessary information (such as ConversationID) within `userNotificationCenter.didReceive` even if the record itself is deleted.
            if let recordID = queryNotification.recordID {
                self.iCloudManager.deleteRecord(recordID)
            }
        }

        return .newData
    }

    /// Whether to show the push notification to the user or not.
    private func shouldNotify(_ notification: UNNotification) -> Bool {
        guard let conversationId = extractConversationId(from: notification)
        else {
            return false
        }
        /// the one being notified is the one currently opened in the foreground
        if UIApplication.shared.applicationState == .active,
            conversationId == self.selectedConversationId
        {
            return false
        }

        return true
    }

    private func extractConversationId(
        from notification: UNNotification
    ) -> String? {
        guard
            let notification = CKNotification(
                fromRemoteNotificationDictionary: notification.request.content
                    .userInfo
            )
        else {
            return nil
        }

        guard let queryNotification = notification as? CKQueryNotification
        else {
            logger.info(
                category: category,
                message: "Unknown notification type."
            )
            return nil
        }

        return ICloudManager.extractConversationId(
            from: queryNotification
        )
    }
}

extension AppDelegate: UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication
            .LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        setupAppOnLaunch()
        return true
    }

    // didReceiveRemoteNotification do not trigger correctly on simulators
    @MainActor
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        return didReceiveRemoteNotification(userInfo: userInfo)
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        didRegisterForRemoteNotificationsWithDeviceToken(
            deviceToken: deviceToken
        )
    }

    // Report the error if the app fails to register for remote notifications.
    //
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        didFailToRegisterForRemoteNotifications(error)
    }
}
extension AppDelegate: UNUserNotificationCenterDelegate {

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let shouldNotify = shouldNotify(notification)
        logger.info(
            category: category,
            message: "\(#function). Should notify: \(shouldNotify)"
        )

        return shouldNotify ? [[.badge, .sound, .banner, .list]] : []
    }

    /// handles explicit user interactions (like tapping a notification or action button).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        logger.info(
            category: category,
            message: """
                User interacted with notification:
                content: \(response.notification.request.content)
                userInfo: \(response.notification.request.content.userInfo)
                """
        )
        self.path = NavigationPath()
        self.tappedConversationId = extractConversationId(
            from: response.notification
        )
    }
}
