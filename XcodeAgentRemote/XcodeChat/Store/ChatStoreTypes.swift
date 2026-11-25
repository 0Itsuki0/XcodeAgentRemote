//
//  ChatStoreTypes.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

nonisolated extension ChatStore {
    /// An entry of `CodingAssistantManifest.plist` (same as each chat's `metadata.plist`).
    struct ManifestEntry: Decodable {
        struct AgentModel: Decodable {
            struct Provider: Decodable {
                struct BuiltIn: Decodable {
                    struct Empty: Decodable {}
                    var _0: [String: Empty]  // {"<provider name>": {}}
                }
                var builtIn: BuiltIn?
            }
            var modelIdentifier: String?
            var providerIdentifier: Provider?
        }
        var id: String
        var name: String?
        var startDate: Date?
        var lastActivityDate: Date?
        var chatModelDefinitionIdentifier: AgentModel?
    }

    /// The part of `conversation.plist` read here.
    struct ConversationPlist: Decodable {
        var assistantConfiguration: Data?
    }

    /// `assistantConfiguration` (JSON): Swift `.agent(AgentConfiguration(sessionID:))`.
    struct AssistantConfiguration: Codable {
        struct Box: Codable {
            struct Configuration: Codable { var sessionID: String }
            var _0: Configuration
        }
        var agent: Box
    }

    /// `CodingAssistantNavigator.plist`: the navigator's groups (folders), per-chat state and order.
    struct Navigator: Decodable {
        struct Group: Decodable {
            var id: String
            var name: String
            var createdDate: Date?
            var isExpanded: Bool?
            var memberConversationIDs: [String]
        }

        struct ConversationState: Decodable {
            var isArchived: Bool?
            var isUnread: Bool?
            /// The line under the chat's name, e.g. "Editing README.md".
            var subtitle: String?
        }

        var groups: [Group]
        /// Chat UUID (lowercased: `state(of:)`) → its state.
        private var conversations: [String: ConversationState]
        /// Top-level order: group ids and ids of chats not in a group.
        var rootNodeOrder: [String]

        private enum CodingKeys: String, CodingKey {
            case groups, navigatorConversations, rootNodeOrder
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groups =
                try container.decodeIfPresent([Group].self, forKey: .groups)
                ?? []
            rootNodeOrder =
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .rootNodeOrder
                ) ?? []
            // Swift's `[UUID: State]` is written as a flat `[id, state, id, state, ...]` list.
            conversations = [:]
            if container.contains(.navigatorConversations) {
                var flat = try container.nestedUnkeyedContainer(
                    forKey: .navigatorConversations
                )
                while !flat.isAtEnd {
                    let id = try flat.decode(String.self)
                    conversations[id.lowercased()] = try flat.decode(
                        ConversationState.self
                    )
                }
            }
        }

        /// A chat's state, if the navigator has one.
        func state(of conversationID: String) -> ConversationState? {
            conversations[conversationID.lowercased()]
        }

        /// The group a chat is in, if any.
        func group(of conversationID: String) -> Group? {
            groups.first {
                $0.memberConversationIDs.contains {
                    ChatStore.sameID($0, conversationID)
                }
            }
        }
    }
    
}
