//
//  EntryView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/23.
//

import SwiftUI

struct EntryView: View {
    @Environment(ChatViewModel.self) private var chatViewModel

    var scrollToEnd: () -> Void
    var focused: FocusState<Bool>.Binding
    @State private var selectedPermissionMode: PermissionMode = .auto
    @State private var text: String = "Echo back \"hello\""

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    var body: some View {
        Group {
            if let userRequest = chatViewModel.pendingUserRequest.last {
                //            if let userRequest = DebugConstants.permissionRequest
                //                as? ChatEvent.UserRequest
                //            {
                switch userRequest {
                case .permission(let toolUse):
                    PermissionRequestView(
                        toolUse: toolUse,
                        onAnswer: { allowed, message in
                            self.answerPermission(
                                toolUseID: toolUse.id,
                                allow: allowed,
                                message: message
                            )
                        }
                    )
                default:
                    Text("nope")
                }
            } else {
                TextEntryView(
                    focused: focused,
                    text: $text,
                    selectedPermissionMode: $selectedPermissionMode,
                    sendPrompt: sendPrompt
                )
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(chatViewModel.isResponding)
        .glassEffect(
            .regular.tint(.clear),
            in: .rect(cornerRadius: standardSpacing * 2)
        )
        .padding(.horizontal, standardSpacing)
    }

    private func sendPrompt() {
        self.focused.wrappedValue = false
        let prompt = self.text.trimmed
        guard !prompt.trimmed.isEmpty else { return }
        guard !chatViewModel.isResponding else { return }
        chatViewModel.sendMessage(
            prompt,
            permissionModeOverride: self.selectedPermissionMode
        )
        self.text = ""
    }

    private func answerPermission(
        toolUseID: String,
        allow: Bool,
        message: String? = nil
    ) {
        self.focused.wrappedValue = false
        guard !chatViewModel.isResponding else { return }
        chatViewModel.answerPermission(
            toolUseID: toolUseID,
            allow: allow,
            message: message
        )
    }

    //    @ContentBuilder
    //    private var textEntry: TextField

}

private struct TextEntryView: View {
    var focused: FocusState<Bool>.Binding

    @Binding var text: String
    @Binding var selectedPermissionMode: PermissionMode
    let sendPrompt: () -> Void

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: standardSpacing / 2) {

            TextField("", text: $text, axis: .vertical)
                .focused(focused)
                .onSubmit {
                    sendPrompt()
                }
                .padding(.horizontal, standardSpacing / 2)
                .padding(.top, standardSpacing / 2)
                .lineLimit(5)

            Divider()
            HStack {
                Picker(
                    selection: $selectedPermissionMode,
                    content: {
                        Section("Mode") {
                            ForEach(PermissionMode.allCases) { mode in
                                Text(mode.displayString)
                                    .tag(mode)
                            }
                        }
                    },
                    label: {},
                    currentValueLabel: {
                        Text("\(selectedPermissionMode.displayString) Mode")
                    }
                )

                .buttonStyle(.glass)

                Button("", systemImage: "arrow.up") {
                    sendPrompt()
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.glassProminent)
                .disabled(text.trimmed.isEmpty)

            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.all, standardSpacing / 2)

    }
}

private struct PermissionRequestView: View {
    let toolUse: ChatEvent.ToolUse
    let onAnswer: (_ allow: Bool, _ message: String?) -> Void

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    // TODO: - consider adding a text field for user entry
    private let message: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: standardSpacing) {
            Text("Allow using tool [\(toolUse.name)]?")
                .font(.headline)
            let inputs = toolUse.jsonInput.trimmed
            if !inputs.isEmpty {
                Text(inputs)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(10)
            }

            HStack(spacing: standardSpacing) {
                Button("Deny") {
                    self.onAnswer(false, message)
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.glass)
                .buttonSizing(.flexible)

                Button("Allow") {
                    self.onAnswer(true, message)
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.glassProminent)
                .buttonSizing(.flexible)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
        }
        .padding(.all, standardSpacing)

    }
}
