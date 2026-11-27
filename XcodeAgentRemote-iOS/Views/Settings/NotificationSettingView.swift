//
//  NotificationSettingView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import SwiftUI

struct NotificationSettingView: View {
    @State private var authorizationStatus: UNAuthorizationStatus =
        .notDetermined
    @State private var notificationEnabled: Bool = false
    @State private var fetching: Bool = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private let standardSpacing = UIConstants.standardSpacing

    private let notificationCenter = UNUserNotificationCenter.current()

    func requestNotificationPermission() async throws -> Bool {
        return try await notificationCenter.requestAuthorization(options: [
            .alert, .sound, .badge,
        ])
    }

    private var currentAuthorizationStatus: UNAuthorizationStatus {
        get async {
            let settings = await notificationCenter.notificationSettings()
            return settings.authorizationStatus
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Enable", isOn: $notificationEnabled)
                    .tint(.accentColor)
                    .fontWeight(.medium)

            } header: {
                SettingHeader(
                    """
                    The app uses `iCloud` for sending push notifications on watched conversations update.

                    To receive notifications on a conversation update:
                    1. Watch a conversation, either from Mac or within the iOS app.
                    2. Sign in to the same iCloud account on both Mac and iOS.
                    3. Enable push notification on iOS.
                    """
                )
            }
        }
        .disabled(self.fetching)
        .overlay {
            if fetching {
                ProgressView()
                    .controlSize(.extraLarge)
            }
        }
        .contentMargins(.top, UIConstants.standardTopMargin)
        .navigationTitle("Push Notification")
        .navigationSubtitle("Get notified on new messages in real time")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: notificationEnabled, initial: false) {
            self.handlePreferenceChange()
        }
        .onChange(
            of: scenePhase,
            initial: true,
            self.refreshAuthStatus
        )
        .onChange(of: authorizationStatus) {
            self.notificationEnabled = self.authorizationStatus == .authorized
        }
    }

    private func handlePreferenceChange() {
        guard !self.fetching else { return }
        if self.equal(
            enabled: self.notificationEnabled,
            authorizationStatus: self.authorizationStatus
        ) {
            return
        }

        guard self.authorizationStatus == .notDetermined else {
            openNotificationSetting()
            return
        }
        Task {
            do {
                self.notificationEnabled =
                    try await requestNotificationPermission()
                self.authorizationStatus = await currentAuthorizationStatus
            } catch (_) {
                self.notificationEnabled = false
            }
        }
    }

    private func openNotificationSetting() {
        guard
            let url = URL(string: UIApplication.openSettingsURLString)
        else { return }
        self.openURL(url)
    }

    private func refreshAuthStatus() {
        guard scenePhase == .active else { return }
        guard !self.fetching else { return }
        self.fetching = true
        Task {
            defer { self.fetching = false }
            self.authorizationStatus = await currentAuthorizationStatus
            self.notificationEnabled = self.authorizationStatus == .authorized
        }
    }

    private func equal(
        enabled: Bool,
        authorizationStatus: UNAuthorizationStatus
    ) -> Bool {
        enabled == (authorizationStatus == .authorized)
    }
}
