//
//  AppleEventView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/26.
//

import SwiftUI

struct PermissionView: View {
    var body: some View {
        SettingForm {
            AppleEventSection()
        }
        .navigationTitle(DashboardOption.permissions.navigationTitle)
    }
}

private struct AppleEventSection: View {
    @State private var permissionGranted: Bool = false
    @State private var automationStatus: XcodeAutomation.PermissionStatus =
        .notDetermined

    @State private var processing: Bool = false

    @Environment(\.openURL) private var openURL

    /// whether the window has focus
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Section {
            Toggle(
                "Automation Permission",
                isOn: $permissionGranted
            )
        } header: {
            VStack(alignment: .leading) {
                Text("App Event")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ExplanationText(
                    """
                    Apple event / Automation used for closing Xcode project before 
                    running the agent Programmatically to process the message and get response.

                    This is needed because Xcode only loads chat data on project opening.
                    It then keeps the project's chats in memory and 
                    may overwrite the turns this app records.

                    For more details, please refer to [Why not keep Xcode open](\(String.gitHub)#why-not-keep-xcode-open)
                    """
                )
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: self.permissionGranted) {
            self.handlePermissionToggle()
        }
        .onChange(of: appearsActive, initial: true) {
            guard appearsActive else { return }
            self.refreshPermissionStates(prompt: false)
        }
    }

    private func refreshPermissionStates(prompt: Bool) {
        self.processing = true
        Task {
            defer { processing = false }
            self.automationStatus = await XcodeAutomation.automationPermission(
                askIfNeeded: false
            )
            self.permissionGranted = automationStatus == .granted
        }
    }

    private func handlePermissionToggle() {
        guard !self.processing else { return }
        if self.equal(
            granted: self.permissionGranted,
            automationStatus: automationStatus
        ) {
            return
        }

        guard self.automationStatus == .notDetermined else {
            openAutomationSettings()
            return
        }

        self.refreshPermissionStates(prompt: true)
    }

    private func openAutomationSettings() {
        if let url = URL(string: XcodeAutomation.settingURL) {
            self.openURL(url)
        }
    }

    private func equal(
        granted: Bool,
        automationStatus: XcodeAutomation.PermissionStatus
    ) -> Bool {
        granted == (automationStatus == .granted)
    }
}
