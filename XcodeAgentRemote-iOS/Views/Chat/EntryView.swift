//
//  EntryView.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/23.
//

import SwiftUI

// TODO: - add a setting to hide intermediate messages
struct EntryView: View {
    @Environment(ChatViewModel.self) private var chatViewModel

    var focused: FocusState<Bool>.Binding
    @State private var selectedPermissionMode: PermissionMode = .auto
    @State private var text: String = ""

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    var body: some View {
        VStack(alignment: .leading, spacing: standardSpacing / 2) {
            if let turnError = self.chatViewModel.turnError {
                Text(turnError.localizedDescription.trimmed)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        self.chatViewModel.turnError = nil
                    }
            }

            Group {
                if let userRequest = chatViewModel.pendingUserRequest.last {
                    switch userRequest {
                    case .permission(let toolUse):
                        ApprovalView(
                            title: "Allow using tool above?",
                            approveButtonTitle: "Allow",
                            textFieldPrompt: "Any message...",
                            onAnswer: { allowed, message in
                                self.answerPermission(
                                    toolUseID: toolUse.id,
                                    allow: allowed,
                                    message: message
                                )
                            },
                            focused: focused
                        )
                    case .planApproval(toolUseID: let toolUseId, plan: _):
                        ApprovalView(
                            title: "Approve plan above?",
                            approveButtonTitle: "Approve",
                            textFieldPrompt: "Any feedback...",
                            onAnswer: { allowed, message in
                                self.approvePlan(
                                    toolUseID: toolUseId,
                                    approve: allowed,
                                    message: message
                                )
                            },
                            focused: focused
                        )
                    case .questions(toolUseID: let toolUseId, let questions):
                        AnswerQuestionView(
                            questions: questions,
                            focused: focused,
                            onAnswer: {
                                self.answerQuestions(
                                    toolUseID: toolUseId,
                                    answers: $0
                                )
                            },
                            onDecline: {
                                self.declineQuestions(
                                    toolUseID: toolUseId,
                                    message: $0
                                )
                            }
                        )
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
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, standardSpacing)
        .simultaneousGesture(
            TapGesture().onEnded {
                self.focused.wrappedValue = false
            }
        )
    }

    private func sendPrompt() {
        let prompt = self.text.trimmed
        guard !prompt.trimmed.isEmpty else { return }

        processServerRequest {
            chatViewModel.sendMessage(
                prompt,
                permissionModeOverride: self.selectedPermissionMode
            )
            self.text = ""
        }
    }

    private func answerPermission(
        toolUseID: String,
        allow: Bool,
        message: String?
    ) {
        processServerRequest {
            chatViewModel.answerPermission(
                toolUseID: toolUseID,
                allow: allow,
                message: message
            )
        }
    }

    private func approvePlan(
        toolUseID: String,
        approve: Bool,
        message: String?
    ) {
        processServerRequest {
            chatViewModel.answerPlanApproval(
                toolUseID: toolUseID,
                approve: approve,
                feedback: message
            )
        }
    }

    func answerQuestions(
        toolUseID: String,
        answers: [String: [String]]
    ) {
        processServerRequest {
            chatViewModel.answerQuestions(
                toolUseID: toolUseID,
                answers: answers
            )
        }
    }

    func declineQuestions(
        toolUseID: String,
        message: String?
    ) {
        processServerRequest {
            chatViewModel.declineQuestions(
                toolUseID: toolUseID,
                message: message
            )
        }
    }

    private func processServerRequest(_ request: @escaping () -> Void) {
        self.focused.wrappedValue = false
        guard !chatViewModel.isResponding else { return }
        request()
    }
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

                Button("", systemImage: "arrow.up", action: sendPrompt)
                    .buttonBorderShape(.circle)
                    .buttonStyle(.glassProminent)
                    .disabled(text.trimmed.isEmpty)

            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.all, standardSpacing / 2)

    }
}

/// Plan and tool input will already be shown within the chat history card.
/// Not repeating those again here.
private struct ApprovalView: View {

    let title: String
    let approveButtonTitle: String
    let textFieldPrompt: String
    let onAnswer: (_ allow: Bool, _ message: String?) -> Void
    var focused: FocusState<Bool>.Binding

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    @State private var text: String = ""

    private var message: String? {
        text.trimmed.isEmpty ? nil : text.trimmed
    }

    var body: some View {
        RequestFormWrapper(
            top: {
                Text(title)
                    .font(.headline)
            },
            center: {
                RequestFreeEntry(
                    text: $text,
                    textFieldPrompt: textFieldPrompt,
                    focused: focused
                )
            },
            bottom: {
                HStack(spacing: standardSpacing) {
                    Button("Deny") {
                        self.onAnswer(false, message)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
                    .buttonSizing(.flexible)

                    Button(approveButtonTitle) {
                        self.onAnswer(true, message)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glassProminent)
                    .buttonSizing(.flexible)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }
        )
    }
}

private struct RequestFreeEntry: View {
    @Binding var text: String

    let textFieldPrompt: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        TextField(
            "",
            text: $text,
            prompt: Text(textFieldPrompt),
            axis: .vertical
        )
        .focused(focused)
        .lineLimit(3, reservesSpace: true)
    }
}

private struct RequestFormWrapper<Top: View, Center: View, Bottom: View>: View {
    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    @ContentBuilder var top: Top
    @ContentBuilder var center: Center
    @ContentBuilder var bottom: Bottom

    var body: some View {
        VStack(alignment: .leading, spacing: standardSpacing) {
            self.top

            Divider()

            self.center

            Divider()

            self.bottom
        }
        .padding(.all, standardSpacing)
    }
}

private struct AnswerQuestionView: View {
    let questions: [ChatEvent.UserRequest.Question]
    var focused: FocusState<Bool>.Binding
    let onAnswer: ([String: [String]]) -> Void
    let onDecline: (String?) -> Void

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    @State private var currentIndex: Int = 0
    @State private var text: String = ""

    @State private var answers: [String: [String]] = [:]
    @State private var showDecline: Bool = false

    private var count: Int {
        questions.count
    }

    var body: some View {
        Group {
            if showDecline {
                self.declineView
            } else {
                if questions.indices.contains(currentIndex) {
                    let question = questions[currentIndex]
                    let questionKey = question.question
                    SingleQuestionView(
                        question: question,
                        index: currentIndex,
                        total: count,
                        focused: focused,
                        selectedOptions: Set(
                            self.answers[questionKey] ?? []
                        ),
                        onNext: {
                            self.answers[questionKey] = Array($0)
                            let lastIndex = count - 1
                            if currentIndex == lastIndex {
                                self.onAnswer(answers)
                            } else {
                                self.currentIndex = min(
                                    lastIndex,
                                    self.currentIndex + 1
                                )
                            }
                        },
                        onPrevious: {
                            self.answers[questionKey] = Array($0)
                            self.currentIndex = max(0, self.currentIndex - 1)
                        },
                        onDecline: {
                            showDecline = true
                        }
                    )
                }
            }
        }
        .animation(.smooth, value: showDecline)
    }

    @ContentBuilder
    private var declineView: some View {
        RequestFormWrapper(
            top: {
                Text("Decline all questions")
                    .font(.headline)
            },
            center: {
                RequestFreeEntry(
                    text: $text,
                    textFieldPrompt: "Any message...",
                    focused: focused
                )
            },
            bottom: {
                HStack(spacing: standardSpacing) {
                    Button("Back") {
                        showDecline = false
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
                    .buttonSizing(.flexible)

                    Button("Decline") {
                        onDecline(
                            text.trimmed.isEmpty ? nil : text.trimmed
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glassProminent)
                    .buttonSizing(.flexible)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }
        )

    }

}

private struct SingleQuestionView: View {
    let question: ChatEvent.UserRequest.Question
    let index: Int
    let total: Int

    var focused: FocusState<Bool>.Binding

    @State var selectedOptions: Set<String>

    let onNext: (_ selected: Set<String>) -> Void
    let onPrevious: (_ selected: Set<String>) -> Void
    let onDecline: () -> Void

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    private var isLast: Bool {
        index >= total - 1
    }

    private var isFirst: Bool {
        index == 0
    }

    @State private var text: String = ""

    private var multiSelect: Bool {
        question.multiSelect ?? false
    }

    private var processedOptions: Set<String> {
        var options = selectedOptions
        guard options.contains(freeAnswerLabel) else {
            return options
        }
        options.remove(freeAnswerLabel)
        if !text.trimmed.isEmpty {
            options.insert(text.trimmed)
        }
        return options
    }

    private let freeAnswerLabel =
        "itsuki.enjoy.XcodeAgentRemote.freeAnswerOption"

    var body: some View {
        RequestFormWrapper(
            top: {
                HStack(spacing: standardSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(question.question)
                            .font(.headline)
                        Text("`[\(index+1)/\(total)]`")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Decline", action: onDecline)
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                }

            },
            center: {
                Form {
                    ForEach(question.options, id: \.self) { option in
                        Button {
                            self.selectedOptions.remove(freeAnswerLabel)
                            if multiSelect {
                                self.selectedOptions.insert(option.label)
                            } else {
                                self.selectedOptions = [option.label]
                            }
                        } label: {
                            HStack(spacing: standardSpacing) {
                                VStack(
                                    alignment: .leading,
                                    spacing: standardSpacing / 4
                                ) {
                                    Text(option.label)
                                    if let description = option.description {
                                        Text(description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if selectedOptions.contains(option.label) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.headline)
                                }
                            }
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                        }
                    }
                    .listRowInsets(.vertical, standardSpacing / 2)

                    HStack(spacing: standardSpacing) {

                        TextField(
                            "",
                            text: $text,
                            prompt: Text("Something else...")
                        )
                        .focused(focused)
                        .listRowInsets(.vertical, standardSpacing / 2)
                        .onChange(of: focused.wrappedValue) {
                            if focused.wrappedValue {
                                self.selectedOptions = [freeAnswerLabel]
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if selectedOptions.contains(freeAnswerLabel) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.headline)
                        }
                    }
                }
                .font(.footnote)
                .buttonStyle(.plain)
                .contentMargins(.vertical, 0)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 180)

            },
            bottom: {
                HStack(spacing: standardSpacing) {
                    Button("Previous") {
                        self.onPrevious(processedOptions)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glass)
                    .buttonSizing(.flexible)
                    .disabled(isFirst)

                    Button(isLast ? "Submit" : "Next") {
                        self.onNext(processedOptions)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.glassProminent)
                    .buttonSizing(.flexible)
                    .disabled(processedOptions.isEmpty)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }
        )
    }
}
