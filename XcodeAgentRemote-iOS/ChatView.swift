//
//  ChatView.swift
//  BrowserByItsuki
//
//  Created by Itsuki on 2025/10/29.
//

import SwiftUI

private let logger = Logger.shared
private let category = Logger.category(#fileID)

private struct IdentifiableChatEvent: Identifiable, Hashable, Equatable,
    Sendable
{
    let id = UUID()
    let event: ChatEvent
}

#if DEBUG
    extension ChatView {
        static private var debugHistory: [IdentifiableChatEvent] {
            do {
                guard let url = DebugConstants.chatEventJsonURL else {
                    logger.info(
                        category: category,
                        message: "Debug sample URL not found."
                    )
                    return []
                }
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([ChatEvent].self, from: data)
                    .map(IdentifiableChatEvent.init(event:))
            } catch {
                logger.error(category: category, error: error)
                return []
            }
        }
        static var debugUI: ChatView {
            ChatView(
                conversationId: "DebugConversationId",
                conversationName: "DebugConversation",
                projectName: "DebugProject",
                _history: State(initialValue: debugHistory)
            )
        }

        static var debugServerCall: ChatView {
            ChatView(
                conversationId: DebugConstants.conversationId,
                conversationName: "DebugConversation",
                projectName: "DebugProject",
                _history: State(initialValue: [])
            )
        }
    }
#endif

struct ChatView: View {
    @Environment(XcodeChatManager.self) private var chatManager
    let conversationId: String
    let conversationName: String
    let projectName: String
    @State private var history: [IdentifiableChatEvent] = []
    //    var focused: FocusState<Bool>.Binding
    @FocusState private var focused

    @State private var entry: String = "ddd\n\\nddfdfs\ndfd\n"
    //    @State private var scrollPosition: ScrollPosition = .init(idType: UUID.self)
    @State private var scrollPositionID: UUID? = nil

    @State private var entryHeight: CGFloat = 24

    private let streamingMessageID = UUID()

    private let standardSpacing: CGFloat = 16

    private let bottomSpacer = UUID()

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: standardSpacing).fill(
            .secondary.opacity(0.5)
        )
    }

    private var cardPadding: CGFloat { standardSpacing * 2 / 3 }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: standardSpacing) {
                // TODO: - add `ContentUnavailableView`
                /// 1. unsupported agent type
                /// 2. empty history
                /// 3. request error
                ForEach(
                    history.filter {
                        $0.event.response == nil
                    }
                ) { event in
                    self.eventView(event.event)
                }

                EmptyView()
                    .id(bottomSpacer)
            }
            .contentMargins(.top, 0)
            .scrollTargetLayout()
            .background(.background)
            .onChange(of: history, initial: true) {
                scrollPositionID = bottomSpacer
            }
            .padding(.all, standardSpacing)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .top
            )
        }
        .refreshable {
            // TODO: - add in refresh history logic
            try? await Task.sleep(for: .seconds(1))
        }
        .scrollPosition(id: $scrollPositionID, anchor: .bottom)
        .defaultScrollAnchor(.bottom, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottom) {
            let ids = history.suffix(1).map(\.id) + [bottomSpacer]
            if let scrollPositionID, !ids.contains(scrollPositionID) {
                Button("", systemImage: "arrow.down") {
                    self.scrollPositionID = bottomSpacer
                }
                .buttonBorderShape(.circle)
                .buttonStyle(.glass)
                .padding(.all, standardSpacing)
            }
        }
        .safeAreaBar(edge: .bottom) {
            EntryView(focused: $focused, standardSpacing: standardSpacing)
        }

        //                    .onChange(of: chatManager.streamingMessage, initial: true, {
        //                        guard chatManager.streamingMessage != nil else {
        //                            return
        //                        }
        //                        proxy.scrollTo(self.streamingMessageID, anchor: .bottom)
        //                    })
        //        }
        .labelsHidden()
        .labelStyle(.iconOnly)
        .multilineTextAlignment(.leading)
        .navigationTitle(conversationName)
        .navigationSubtitle(projectName)
        .navigationBarTitleDisplayMode(.inline)
        .onTapGesture {
            self.focused = false
        }

    }

    @ViewBuilder
    private func eventView(_ event: ChatEvent) -> some View {
        switch event {
        case .userMessage(let text):
            self.userMessage(text)
        case .toolUse(let toolUse):
            self.toolUse(
                toolUse,
                errored: history.map(\.event).result(
                    for: toolUse
                )?.isError ?? false
            )
        case .toolResult(let toolResult):
            self.toolResult(toolResult)
        case .userRequest(let request):
            self.userRequest(
                request,
                response: history.map(\.event).response(
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

    //    private func sendPrompt() {
    //        self.focused.wrappedValue = false
    //        let entry = self.entry.trimmed
    //        guard !entry.trimmed.isEmpty else {
    //            return
    //        }
    //        guard !chatManager.isResponding else {
    //            return
    //        }
    //
    //        self.entry = ""
    //
    //        Task {
    //            await chatManager.respond(to: entry)
    //        }
    //    }
}

struct EntryView: View {
    @Environment(XcodeChatManager.self) private var chatManager

    var focused: FocusState<Bool>.Binding
    var standardSpacing: CGFloat
    @State private var selectedPermissionMode: PermissionMode = .auto
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: standardSpacing / 2) {
            TextField("", text: $text, axis: .vertical)
                .focused(focused)
                .onSubmit {
                    //                        self.entry.append("\n")
                }
                //                            .onSubmit({
                //                                self.sendPrompt()
                //                            })
                //                    .padding(.vertical, 4)
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

                }
                .buttonBorderShape(.circle)
                .buttonStyle(.glassProminent)

            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            // .disabled(chatManager.isResponding)

        }
        .padding(.all, standardSpacing / 2)
        .glassEffect(
            .regular.tint(.clear),
            in: .rect(cornerRadius: standardSpacing * 2)
        )
        .padding(.horizontal, standardSpacing)
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
            $0.response
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
    var response: UserResponse? {
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
