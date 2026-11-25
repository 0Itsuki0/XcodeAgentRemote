//
//  XcodeAgentRemote_iOSApp.swift
//  XcodeAgentRemote-iOS
//
//  Created by Itsuki on 2026/11/15.
//

import SwiftData
import SwiftUI

// TODO: - add a link to get mac app somewhere

extension EnvironmentValues {
    @Entry var tappedConversationId: XcodeConversation.ID? = nil
}

@main
struct XcodeAgentRemote_iOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let serverSettingManager = ServerSettingManager()

    var body: some Scene {
        @Bindable var appDelegate = appDelegate
        WindowGroup {
            NavigationStack(path: $appDelegate.path) {
                ContentView()
                    .environment(serverSettingManager)
                    .environment(
                        \.tappedConversationId,
                        appDelegate.tappedConversationId
                    )
            }
        }
    }
}



struct SettingHeader: View {

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    private let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.subheadline)
            .padding(.bottom, UIConstants.standardTopMargin)
            .listRowInsets(.horizontal, 0)

    }
}
