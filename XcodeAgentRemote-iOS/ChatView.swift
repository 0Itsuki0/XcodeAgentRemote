//
//  ChatView.swift
//  BrowserByItsuki
//
//  Created by Itsuki on 2025/10/29.
//

import SwiftUI

struct SelectedConversationDidChange: NotificationCenter.MainActorMessage {
    typealias Subject = Never

    struct Conversation: Sendable, Hashable, Equatable {
        var conversationId: String
        var projectId: String
        var lastActivityDate: Date
    }

    let conversation: Conversation?
}

extension NotificationCenter.MessageIdentifier
where
    Self == NotificationCenter.BaseMessageIdentifier<
        SelectedConversationDidChange
    >
{
    static var selectedConversationDidChange: Self { .init() }
}

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
                    projectId: DebugConstants.chatStore,
                    lastActivityDate: Date(),
                    isWatching: true
                )
            )

        }
    }
#endif

extension ChatView {
    init(
        apiClient: APIServerClient,
        conversation: XcodeConversation,
        projectName: String,
        /// store: Xcode chat store folder (`<ProjectName>-<hash>`, name or path).
        projectId: String,
        lastActivityDate: Date?,
        isWatching: Bool
    ) {
        self.chatViewModel = ChatViewModel(
            apiClient: apiClient,
            conversationId: conversation.id,
            conversationName: conversation.name,
            projectName: projectName,
            projectId: projectId,
            lastActivityDate: lastActivityDate,
            isWatching: isWatching
        )
    }
}

struct ChatView: View {
    @State private var chatViewModel: ChatViewModel

    private var history: [ChatEvent] {
        chatViewModel.history
    }

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

    @FocusState private var focused

    @State private var scrollPositionID: Int? = nil

    @State private var fetchID: Int = 0

    private let standardSpacing: CGFloat = UIConstants.standardSpacing

    private let bottomSpacer = Int.max

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: standardSpacing).fill(
            .secondary.opacity(0.5)
        )
    }

    private var cardPadding: CGFloat { standardSpacing * 2 / 3 }

    var body: some View {
        Group {
            if let error = chatViewModel.fetchError {
                self.errorView(error)
            } else {
                self.mainChatView
            }
        }
        .task(id: fetchID) {
            await chatViewModel.fetchConversationDetail()
        }
        .navigationTitle(chatViewModel.conversationName)
        .navigationSubtitle(chatViewModel.projectName)
        .navigationBarTitleDisplayMode(.inline)
        .onTapGesture {
            self.focused = false
        }
        .environment(self.chatViewModel)
    }

    @ContentBuilder
    private func errorView(_ error: Error) -> some View {
        ContentUnavailableView {
            Label(
                "Error fetching conversations",
                systemImage: "laptopcomputer.trianglebadge.exclamationmark"
            )
        } description: {
            Text(error.localizedDescription.trimmed)
                .padding(.top, UIConstants.standardSpacing)
        } actions: {
            Button("Retry") {
                fetchID += 1
            }
            .disabled(chatViewModel.isFetching)
        }
    }

    @ContentBuilder
    private var mainChatView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: standardSpacing) {
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
        .onDisappear {
            NotificationCenter.default.post(
                SelectedConversationDidChange(
                    conversation: nil
                )
            )
        }
        .scrollPosition(id: $scrollPositionID, anchor: .bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: history, initial: true) {
            /// Not using `onAppear` to
            /// 1. only update if there is history / fetch success
            /// 2. set lastActivityDate as messages sent
            guard !history.isEmpty,
                let lastActivityDate = chatViewModel.lastActivityDate
            else { return }
            NotificationCenter.default.post(
                SelectedConversationDidChange(
                    conversation: .init(
                        conversationId: chatViewModel.conversationId,
                        projectId: chatViewModel.projectId,
                        lastActivityDate: lastActivityDate
                    )
                )
            )
        }
        .onChange(of: chatViewModel.turnError == nil, initial: true) {
            self.scrollToEnd()
        }
        .onChange(of: nonResponseHistory, initial: true) {
            self.scrollToEnd()
        }
        .onChange(of: chatViewModel.pendingUserRequest, initial: true) {
            self.scrollToEnd()
        }
        .overlay { centerOverlay }
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
            EntryView(focused: $focused)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(chatViewModel.isWatching ? "Unwatch" : "Watch") {
                    chatViewModel.watchConversation(
                        shouldWatch: !chatViewModel.isWatching
                    )
                }.buttonStyle(.borderless)
                    .foregroundStyle(.link)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .labelsHidden()
        .labelStyle(.iconOnly)
        .multilineTextAlignment(.leading)
        .alert(error: $chatViewModel.watchError, actions: {})
    }

    @ContentBuilder
    private var centerOverlay: some View {
        if nonResponseHistory.isEmpty {
            if chatViewModel.isFetching {
                ProgressView()
                    .controlSize(.extraLarge)
            } else if chatViewModel.fetchError == nil {
                ContentUnavailableView(
                    "No conversations",
                    systemImage: "text.bubble"
                )
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
    }

    @ContentBuilder
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
        Text(text.trimmed)
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
                approve: response?.planResponse?.0 ?? true,
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
            showExclamation: !approve
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
            withAnimation(.smooth) {
                scrollPositionID = bottomSpacer
            }
        }
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
