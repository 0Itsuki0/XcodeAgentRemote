//
//  AppleEventView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/26.
//

import SwiftUI

struct AppleEventView: View {
    @State private var permissionGranted: Bool = false
    @State private var automationStatus: XcodeAutomation.PermissionStatus =
        .notDetermined

    @State private var processing: Bool = false

    @Environment(\.openURL) private var openURL

    /// whether the window has focus
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        SettingForm {
            Section {
                Toggle(
                    "Automation Permission",
                    isOn: $permissionGranted
                )
            } header: {
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
            }
        }
        .navigationTitle(DashboardOption.appleEvent.navigationTitle)
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
        print(#function)
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
