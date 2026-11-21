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

    @State private var entry: String = ""
//    @State private var scrollPosition: ScrollPosition = .init(idType: UUID.self)
    @State private var scrollPositionID: UUID? = nil

    @State private var entryHeight: CGFloat = 24

    private let streamingMessageID = UUID()

    private let standardSpacing: CGFloat = 16

    private let bottomSpacer = UUID()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: standardSpacing) {
                // TODO: - add `ContentUnavailableView`
                /// 1. unsupported agent type
                /// 2. empty history
                /// 3. request error

                ForEach(history) { event in
                    switch event.event {
                    case .userMessage(let text):
                        self.userMessage(text)
                    default:
                        Text("Event: \(event.event)")
                    }
                }

                EmptyView()
                    .id(bottomSpacer)

                //                        Section {

                //                            ForEach(chatManager.messages) { message in
                //                                let isUser: Bool = message.isUserMessage
                //                                let messageContent: String = message.messageContent
                //                                self.messageView(messageContent, isUser: isUser)
                //                                    .id(message.id)
                //
                //                            }
                //
                //                            if let message = chatManager.streamingMessage {
                //                                self.messageView(message.isEmpty || message == "null" ? "..." : message, isUser: false)
                //                                    .id(streamingMessageID)
                //                            }

                //                        }
                //                        .listSectionMargins(.vertical, 0)
                //                        .listSectionMargins(.horizontal, 8)

            }
            .contentMargins(.top, 0)
            .scrollTargetLayout()
            .background(.background)
            .onChange(of: history, initial: true) {
                //                    if let last = history.last {
                //                        proxy.scrollTo(last.id, anchor: .bottom)
                //                    }
                //                    proxy.scrollTo(bottomSpacer, anchor: .bottom)
                scrollPositionID = bottomSpacer
            }
            .padding(.all, standardSpacing)
            .padding(.bottom, standardSpacing)
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .top
            )
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
            VStack(spacing: standardSpacing) {
                HStack(spacing: standardSpacing) {
                    TextField("", text: $entry, axis: .vertical)
                        .focused($focused)
                        //                            .onSubmit({
                        //                                self.sendPrompt()
                        //                            })
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.gray, style: .init(lineWidth: 1))
                                .fill(.white.opacity(0.8))
                        )

                    Button(
                        action: {
                            //                            self.sendPrompt()
                        },
                        label: {
                            Image(systemName: "paperplane.fill")
                        }
                    )
                    //                        .disabled(chatManager.isResponding)

                }
                .padding(.all, 4)
                .glassEffect()
                .padding(.horizontal, standardSpacing)

            }
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
        //                .foregroundStyle(.black.opacity(0.8))
        //                .onTapGesture(perform:  {
        //                    self.focused.wrappedValue = false
        //                })

    }

    @ViewBuilder
    private func eventView(_ event: ChatEvent) -> some View {
        //        Text(text)
        //            .listRowBackground(Color.clear)
        //            .frame(maxWidth: .infinity, alignment: .leading)
        //            .padding(.horizontal, 16)
        //            .padding(.vertical, 8)
        //            .background(
        //                RoundedRectangle(cornerRadius: 8).fill(
        //                    isUser ? .yellow.opacity(0.3) : .green.opacity(0.3)
        //                )
        //            )
        //            .padding(isUser ? .leading : .trailing, 64)
        //            .padding(.vertical, 8)
        //            .listRowInsets(.vertical, 0)
        //            .listRowInsets(.horizontal, 8)
        //            .listRowSeparator(.hidden)

    }

    @ContentBuilder
    private func userMessage(_ text: String) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.all, standardSpacing / 2)
            .background(
                RoundedRectangle(cornerRadius: standardSpacing / 2).fill(
                    .secondary.opacity(0.5)
                )
            )
            .padding(.leading, standardSpacing * 3)
    }
    
    @ContentBuilder
    private func toolUse(_ text: String) -> some View {
        Text(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.all, standardSpacing / 2)
            .background(
                RoundedRectangle(cornerRadius: standardSpacing / 2).fill(
                    .secondary.opacity(0.5)
                )
            )
            .padding(.leading, standardSpacing * 3)
    }

    //    private func sendPrompt() {
    //        self.focused.wrappedValue = false
    //        let entry = self.entry.trimmingCharacters(in: .whitespacesAndNewlines)
    //        guard !entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
