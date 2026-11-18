//
//  AppDelegate.swift
//  iCloudDemo
//
//  Created by Itsuki on 2025/06/01.
//

import CloudKit
import SwiftUI
import UserNotifications

private let logger = Logger.shared
private let category = Logger.category(#fileID)

class AppDelegate: NSObject {
    let iCloudManager = ICloudManager()

    /// perform set ups
    private func setupAppOnLaunch() {

        #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
        #else
            NSApplication.shared.registerForRemoteNotifications()
        #endif

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setBadgeCount(0)
        requestNotificationPermission()
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
    ) {
        logger.info(
            category: category,
            message: "\(#function)"
        )
        guard
            let notification = CKNotification(
                fromRemoteNotificationDictionary: userInfo
            )
        else {
            return
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
            return
        }

        guard
            let type = ICloudManager.recordTypeFromSubscriptionId(
                queryNotification.subscriptionID
            )
        else {
            logger.info(category: category, message: "Unknown record type.")
            return
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

        //        let record = queryNotification.recordFields

        //        let queryNotification = notification as! CKQueryNotification
        //        queryNotification.recordID

        //        guard
        //            let notification = CKNotification(
        //                fromRemoteNotificationDictionary: userInfo
        //            )
        //                else {
        //            return .noData
        //        }
        //
        //        print(notification)
        //
        //        if notification.notificationType == .database,
        //           notification.subscriptionID
        //            == CloudManager.sharedCloudDatabaseSubscriptionId
        //        {
        //            Task {
        //                do {
        //                    try await manager.fetchChangesForSharedDBSubscription()
        //                } catch (let error) {
        //                    print(
        //                        "error fetching changes for shared database subscription: \(error)"
        //                    )
        //                    manager.error = error
        //                }
        //
        //            }
        //        }
        //
        //        if notification.notificationType == .query,
        //           notification.subscriptionID
        //            == CloudManager.privateDatabaseQuerySubscriptionId,
        //           let queryNotification = notification as? CKQueryNotification
        //        {
        //
        //            Task {
        //                do {
        //                    try await manager.fetchChangesForQuerySubscription(
        //                        queryNotification
        //                    )
        //                } catch (let error) {
        //                    print(
        //                        "error fetching changes for query subscription: \(error)"
        //                    )
        //                    manager.error = error
        //                }
        //
        //            }
        //        }

        return
    }

}

#if os(iOS)

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
            didReceiveRemoteNotification(userInfo: userInfo)
            return .newData
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

#else

    extension AppDelegate: NSApplicationDelegate {
        func application(
            _ application: NSApplication,
            didFailToRegisterForRemoteNotificationsWithError error: any Error
        ) {
            didFailToRegisterForRemoteNotifications(error)
        }

        func application(
            _ application: NSApplication,
            didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
        ) {
            didRegisterForRemoteNotificationsWithDeviceToken(
                deviceToken: deviceToken
            )
        }

        func application(
            _ application: NSApplication,
            didReceiveRemoteNotification userInfo: [String: Any]
        ) {
            didReceiveRemoteNotification(userInfo: userInfo)
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            setupAppOnLaunch()
        }
    }

#endif

extension AppDelegate: UNUserNotificationCenterDelegate {

    // Request user permissions
    func requestNotificationPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) {
                granted,
                error in
                logger.info(
                    category: category,
                    message: "Notification permission granted"
                )
            }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        logger.info(
            category: category,
            message: "\(#function): \(notification)"
        )
        return [[.badge, .sound, .banner, .list]]
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

        guard
            let notification = CKNotification(
                fromRemoteNotificationDictionary: response.notification.request
                    .content.userInfo
            )
        else {
            return
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

    }
}
