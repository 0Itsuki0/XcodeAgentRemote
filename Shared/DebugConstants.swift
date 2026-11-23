//
//  Debug.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/21.
//

#if DEBUG

    import Foundation
    nonisolated enum DebugConstants {
        static let conversationId: String =
            "1170A351-FBFE-4317-8FA7-4F65AC6F3B64"
        static let chatStore: String = "Demo10-edhhiszqgddxcwajapbakukmrdhy"

        static let chatEventJsonURL: URL? = Bundle.main.url(
            forResource: "sampleHistory",
            withExtension: "json"
        )

        static let conversations: [XcodeChatConversation] = [
            .init(
                id: conversationId,
                name: "Debug1",
                isArchived: false,
                isUnread: false,
                subtitle: "With subtitle",
                lastActivityDate: Date()
            ),
            .init(
                id: UUID().uuidString,
                name: "Debug2",
                isArchived: false,
                isUnread: true,
                lastActivityDate: nil
            ),
            .init(
                id: UUID().uuidString,
                name: "Debug3",
                isArchived: false,
                isUnread: false,
                lastActivityDate: Date().addingTimeInterval(-100)
            ),
        ]

        static let project: XcodeProject = .init(
            name: "Dummy Project",
            projectFile: URL.temporaryDirectory.appending(
                path: "dummy.xcodeproj"
            ),
            store: URL.temporaryDirectory.appending(path: chatStore),
            conversations: conversations
        )

        static let permissionRequest: ChatEvent.UserRequest = .permission(
            .init(
                id: "toolu_01XM4UtqUgebxvwvh7TqFB5G",
                name: "Bash",
                input: [
                    "command": .string("touch /tmp/demo10-allowed"),
                    "description": .string("Create an empty marker file"),
                ]
            )
        )

        static let questionsRequest: ChatEvent.UserRequest = .questions(
            toolUseID: "toolu_01Vc9YGcckK53ukLeVZU7ZWu",
            [
                .init(
                    question: "Which color do you prefer?",
                    header: "Color",
                    options: [
                        .init(label: "Red", description: "The color red"),
                        .init(label: "Green", description: "The color green"),
                        .init(label: "Blue", description: "The color blue"),
                    ],
                    multiSelect: false
                ),
                .init(
                    question: "Which sizes do you want?",
                    header: "Sizes",
                    options: [
                        .init(label: "Small", description: "Small size"),
                        .init(label: "Large", description: nil),
                    ],
                    multiSelect: true
                ),
            ]
        )

        static let planApprovalRequest: ChatEvent.UserRequest = .planApproval(
            toolUseID: "toolu_01GLzYd2WyCBDLKrrCatbS9R",
            plan: """
                # Plan

                ## Context
                You asked for a one-step plan that runs `echo planned`.

                ## Steps
                1. Run `echo planned` with the Bash tool.

                ## Verification
                The output should be `planned`.
                """
        )
    }
#endif
