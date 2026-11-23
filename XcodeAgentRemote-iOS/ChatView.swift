//
//  ChatView.swift
//  BrowserByItsuki
//
//  Created by Itsuki on 2025/10/29.
//

import SwiftUI

// TODO: - show errors

#if DEBUG
    extension ChatView {
        static func debugUI() -> ChatView {
            ChatView(
                chatViewModel: ChatViewModel(
                    debugEventJson: DebugConstants.chatEventJsonURL
                )
            )
        }

        static func debugServerCall(_ apiClient: APIServerClient) -> ChatView {
            ChatView(
                chatViewModel: ChatViewModel(
                    apiClient: apiClient,
                    conversationId: DebugConstants.conversationId,
                    conversationName: "Debug Conversation",
                    projectName: "Debug Project",
                    projectStore: DebugConstants.chatStore
                )
            )

        }
    }
#endif

struct ChatView: View {
    //    @Environment(XcodeChatManager.self) private var chatManager
    @State private var chatViewModel: ChatViewModel

    private var conversationId: String {
        chatViewModel.conversationId
    }
    private var conversationName: String {
        chatViewModel.conversationName
    }
    private var projectName: String {
        chatViewModel.projectName
    }
    private var history: [ChatEvent] {
        chatViewModel.history
    }

    // var focused: FocusState<Bool>.Binding
    @FocusState private var focused

    @State private var entry: String = "ddd\n\\nddfdfs\ndfd\n"
    //    @State private var scrollPosition: ScrollPosition = .init(idType: UUID.self)
    @State private var scrollPositionID: Int? = nil

    @State private var entryHeight: CGFloat = 24

    private let streamingMessageID = UUID()

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    @State private var bottomSpacer = Int.max

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: standardSpacing).fill(
            .secondary.opacity(0.5)
        )
    }

    private var cardPadding: CGFloat { standardSpacing * 2 / 3 }

    /// user response will be cover together with
    private var nonResponseHistory: [ChatEvent] {
        return history.filter {
            $0.userResponse == nil
        }
    }

    /// id to force the entire history to refresh
    private var historyViewID: UUID {
        chatViewModel.historyViewID
    }

    @State private var fetchID: Int = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: standardSpacing) {
                // TODO: - add Error
                // TODO: - add `ContentUnavailableView`
                /// 1. unsupported agent type
                /// 2. empty history
                /// 3. request error
                ForEach(nonResponseHistory.enumerated(), id: \.offset) {
                    _,
                    event in
                    self.eventView(event)
                }
                .id(historyViewID)

                EmptyView()
                    .frame(height: standardSpacing / 2)
                    .id(bottomSpacer)
            }
            .contentMargins(.top, 0)
            .scrollTargetLayout()
            .background(.background)
            .padding(.all, standardSpacing)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .top
            )
        }
        .refreshable {
            /// Calling `fetchConversationDetail` here will cause the request getting cancelled immediately
            self.fetchID += 1
        }
        .task(id: fetchID) {
            await chatViewModel.fetchConversationDetail()
        }
        .scrollPosition(id: $scrollPositionID, anchor: .bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: nonResponseHistory, initial: true) {
            self.scrollToEnd()
        }
        .overlay(alignment: .bottom) {
            let ids = [nonResponseHistory.count - 1] + [bottomSpacer]
            if let scrollPositionID, !ids.contains(scrollPositionID) {
                Button("", systemImage: "arrow.down") {
                    self.scrollToEnd()
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
                .padding(.all, standardSpacing)
            }
        }
        .safeAreaBar(edge: .bottom) {
            EntryView(scrollToEnd: scrollToEnd, focused: $focused)
        }
        .labelsHidden()
        .labelStyle(.iconOnly)
        .multilineTextAlignment(.leading)
        .navigationTitle(conversationName)
        .navigationSubtitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .onTapGesture {
            self.focused = false
        }
        .environment(self.chatViewModel)
    }

    @ViewBuilder
    private func eventView(_ event: ChatEvent) -> some View {
        switch event {
        case .userMessage(let text):
            self.userMessage(text)
        case .toolUse(let toolUse):
            self.toolUse(
                toolUse,
                errored: history.result(
                    for: toolUse
                )?.isError ?? false
            )
        case .toolResult(let toolResult):
            self.toolResult(toolResult)
        case .userRequest(let request):
            self.userRequest(
                request,
                response: history.response(
                    for: request
                )
            )
        case .userResponse(_):
            /// already covered under `.userRequest`
            EmptyView()
        case .assistantMessage(let text):
            self.assistantMessage(text)
        case .intermediate(let text):
            self.secondaryMessage(text)
        }
    }

    @ContentBuilder
    private func userMessage(_ text: String) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.all, cardPadding)
            .background(cardBackground)
            .padding(.leading, standardSpacing * 3)
    }

    /// `errored`: either a tool execution error or a user denial
    @ContentBuilder
    private func toolUse(
        _ toolUse: ChatEvent.ToolUse,
        errored: Bool
    )
        -> some View
    {
        self.assistantCard(
            leadingIcon: "wrench.and.screwdriver",
            title: toolUse.name,
            description: toolUse.jsonInput,
            showExclamation: errored
        )
    }

    @ContentBuilder
    private func toolResult(_ toolResult: ChatEvent.ToolResult) -> some View {
        self.secondaryMessage(toolResult.output)
    }

    @ContentBuilder
    private func userRequest(
        _ request: ChatEvent.UserRequest,
        response: ChatEvent.UserResponse?
    ) -> some View {
        switch request {
        case .permission(let toolUse):
            /// In both the `history` and the live turn, for an allowed permission, the tool result isn't the user's response, it's the tool's output after the user
            /// 1. `.userRequest(.permission)` in place of the `.toolUse`
            /// 2. `.userResponse(.permission(allow: true))`
            /// 3. `.toolResult with the tool's output`
            self.toolUse(toolUse, errored: response?.permissionAllowed ?? false)
        case .planApproval(_, let plan):
            self.planRequest(
                plan,
                approve: response?.planResponse?.0 ?? false,
                feedback: response?.planResponse?.1
            )
        case .questions(_, let questions):
            self.questionRequest(
                questions,
                answers: response?.answers ?? [:],
                decline: response?.declineQuestion
            )
        }
    }

    @ContentBuilder
    private func planRequest(
        _ plan: String,
        approve: Bool,
        feedback: String?
    ) -> some View {
        self.assistantCard(
            leadingIcon: "pencil.and.list.clipboard",
            title: "Plan",
            description: plan,
            showExclamation: approve
        )
        if let feedback {
            self.secondaryMessage(feedback)
        }
    }

    @ContentBuilder
    private func questionRequest(
        _ questions: [ChatEvent.UserRequest.Question],
        answers: [String: [String]],
        decline: String?
    ) -> some View {
        self.assistantCard(
            leadingIcon: "pencil.and.list.clipboard",
            title: "Questions",
            description: makeQuestionAnswerString(
                questions: questions,
                answers: answers
            ),
            showExclamation: decline != nil
        )
        if let decline {
            self.secondaryMessage(decline)
        }
    }

    private func makeQuestionAnswerString(
        questions: [ChatEvent.UserRequest.Question],
        answers: [String: [String]],
    ) -> String {
        var string = ""
        for question in questions {
            string += "Q: \(question.question) \n"
            if let answer = answers[question.question], !answer.isEmpty {
                string += "A: \(answer.joined(separator: ", "))"
            }
        }

        return string
    }

    @ContentBuilder
    private func secondaryMessage(_ text: String) -> some View {
        if !text.trimmed.isEmpty {
            Text(text.trimmed)
                .lineLimit(3)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.secondary)
        }
    }

    @ContentBuilder
    private func assistantMessage(_ text: String) -> some View {
        if !text.trimmed.isEmpty {
            Text(text.trimmed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ContentBuilder
    private func assistantCard(
        leadingIcon: String,
        title: String,
        description: String,
        showExclamation: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: standardSpacing / 2) {
            HStack(spacing: standardSpacing / 2) {
                Image(systemName: "wrench.and.screwdriver")
                Text(title.trimmed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showExclamation {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
            if !description.trimmed.isEmpty {
                Text(description.trimmed)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.all, cardPadding)
        .background(cardBackground)

    }

    private func scrollToEnd() {
        scrollPositionID = nil
        guard !nonResponseHistory.isEmpty else {
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(10))
            scrollPositionID = bottomSpacer
        }
    }
}

extension String {
    var trimmed: String {
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatEvent.ToolUse {
    var jsonInput: String {
        var jsonInputs: [String] = []
        for (key, value) in self.input {
            jsonInputs.append(
                "\(key): \(value.jsonString, default: String(describing: value))"
            )
        }
        return jsonInputs.joined(separator: "\n")
    }
}

extension ChatEvent.UserRequest {
    var name: String {
        switch self {
        case .permission(_):
            "Permission"
        case .questions(_, _):
            "Questions"
        case .planApproval(_, plan: _):
            "Plan Approval"
        }
    }
}

extension ChatEvent.UserResponse {
    var permissionAllowed: Bool {
        if case .permission(_, allow: let allowed, message: _) = self {
            return allowed
        }
        return false
    }

    var planResponse: (Bool, String?)? {
        if case .planApproval(
            _,
            approve: let approved,
            feedback: let feedback
        ) = self {
            return (approved, feedback)
        }
        return nil
    }

    var answers: [String: [String]] {
        if case .questions(_, answers: let answers) = self {
            return answers
        }
        return [:]
    }

    var declineQuestion: String? {
        if case .declineQuestions(_, message: let message) = self {
            /// return empty string instead of nil to show the exclamation mark
            return message ?? ""
        }
        return nil
    }
}

extension Array where Element == ChatEvent {
    func response(for request: ChatEvent.UserRequest) -> ChatEvent.UserResponse?
    {
        let responses: [ChatEvent.UserResponse] = self.compactMap {
            $0.userResponse
        }

        return responses.first {
            $0.toolUseID == request.toolUseID
        }

    }

    func result(for toolUse: ChatEvent.ToolUse) -> ChatEvent.ToolResult? {
        let results: [ChatEvent.ToolResult] = self.compactMap {
            $0.toolResult
        }
        return results.first { $0.toolUseID == toolUse.id }
    }
}

extension ChatEvent {
    var userResponse: UserResponse? {
        if case .userResponse(let response) = self {
            return response
        }
        return nil
    }

    var toolResult: ToolResult? {
        if case .toolResult(let toolResult) = self {
            return toolResult
        }
        return nil
    }
}

extension PermissionMode {
    var displayString: String {
        self.rawValue.capitalized
    }
}
