//
//  DashboardWindow.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/18.
//

import SwiftUI

enum DashboardOption: String, Hashable, CaseIterable {
    case server
    case watcher
    case permissions

    var label: String {
        switch self {
        case .server:
            "API Server"
        case .watcher:
            "Chat Watcher"
        case .permissions:
            "Permissions"
        }
    }

    var navigationTitle: String {
        switch self {
        case .server:
            "API Server Setting"
        case .watcher:
            "Chat Watcher"
        case .permissions:
            "Permissions"
        }
    }
}

struct DashboardWindow: View {
    static let identifier = "DashboardWindow"

    @State private var selection: DashboardOption = .server

    var body: some View {
        NavigationSplitView {
            List(DashboardOption.allCases, id: \.self, selection: $selection) {
                option in
                Text(option.label)
                    .bold(option == selection)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(240)
            .safeAreaInset(edge: .bottom, alignment: .trailing) {
                if let version = AppConstants.appVersion {
                    Text("v\(version)")
                        .font(.footnote)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .padding(.all)
                }
            }
        } detail: {
            switch selection {
            case .server:
                ServerSettingView()
            case .watcher:
                ChatWatcherView()
            case .permissions:
                PermissionView()
            }

        }
        .onWindow { window in
            window.collectionBehavior.insert(.moveToActiveSpace)
        }
    }
}

struct SettingForm<Content: View>: View {
    @ContentBuilder let content: Content

    var body: some View {
        Form {
            self.content
        }
        .contentMargins(.top, -8)
        .formStyle(.grouped)
        .scrollBounceBehavior(.basedOnSize)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

struct ExplanationText: View {
    private let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) {
        self.text = text
    }
    var body: some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

    }
}

struct InlineErrorView: View {
    @Binding var error: Error?
    let autoDisappear: Duration?
    var body: some View {
        if let error {
            Text(error.localizedDescription)
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.caption)
                .foregroundStyle(.red)
                .task {
                    if let autoDisappear {
                        try? await Task.sleep(for: autoDisappear)
                        self.error = nil
                    }
                }
        }
    }
}
