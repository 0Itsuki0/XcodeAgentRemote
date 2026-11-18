//
//  AppDelegate.swift
//  iCloudDemo
//
//  Created by Itsuki on 2025/06/01.
//

import CloudKit
import SwiftUI
import UserNotifications

class AppDelegate: NSObject {
    // to initialize the records on launch
//    let manager = CloudManager()
    let manager = ICloudManager()

    /// perform set ups
    func setupAppOnLaunch() {

        #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
        #else
            NSApplication.shared.registerForRemoteNotifications()
        #endif

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setBadgeCount(0)
        requestNotificationPermission()

        //        Task {
        //            do {
        //                try await manager.addDatabaseSubscription()
        //            } catch (let error) {
        //                print("error adding database subscription: \(error)")
        //            }
        //        }

    }

    func didRegisterForRemoteNotificationsWithDeviceToken(
        deviceToken: Data
    ) {
        print(
            "\(#function). \(deviceToken.base64EncodedString())"
        )
    }

    func didReceiveRemoteNotification(
        userInfo: [AnyHashable: Any]
    ) {
        print(#function)
        guard
            let notification = CKNotification(
                fromRemoteNotificationDictionary: userInfo
            )
        else {
            return
        }
        
        print(notification)
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
        // to initialize the records on launch
        //        let manager = CloudManager.shared

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

            //            print("\(#function)")
            //
            //            // we are not interested in processing if our app is not active
            //            if application.applicationState != .active {
            //                print("not active")
            //                return .newData
            //            }
            //
            //            guard
            //                let notification = CKNotification(
            //                    fromRemoteNotificationDictionary: userInfo
            //                )
            //            else {
            //                return .noData
            //            }
            //
            //            print(notification)
            //
            //            if notification.notificationType == .database,
            //                notification.subscriptionID
            //                    == CloudManager.sharedCloudDatabaseSubscriptionId
            //            {
            //                Task {
            //                    do {
            //                        try await manager.fetchChangesForSharedDBSubscription()
            //                    } catch (let error) {
            //                        print(
            //                            "error fetching changes for shared database subscription: \(error)"
            //                        )
            //                        manager.error = error
            //                    }
            //
            //                }
            //            }
            //
            //            if notification.notificationType == .query,
            //                notification.subscriptionID
            //                    == CloudManager.privateDatabaseQuerySubscriptionId,
            //                let queryNotification = notification as? CKQueryNotification
            //            {
            //
            //                Task {
            //                    do {
            //                        try await manager.fetchChangesForQuerySubscription(
            //                            queryNotification
            //                        )
            //                    } catch (let error) {
            //                        print(
            //                            "error fetching changes for query subscription: \(error)"
            //                        )
            //                        manager.error = error
            //                    }
            //
            //                }
            //            }
            //
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
            print("\(#function). \(error))")
        }
    }

#else

    extension AppDelegate: NSApplicationDelegate {
        func application(
            _ application: NSApplication,
            didFailToRegisterForRemoteNotificationsWithError error: any Error
        ) {

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
                print("Permission granted: \(granted)")
            }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        print(#function)
        return [[.badge, .sound, .banner, .list]]
    }

    /// handles explicit user interactions (like tapping a notification or action button).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        print(response.notification.request.content)
        // title, body, userInfo(data)
    }
}
