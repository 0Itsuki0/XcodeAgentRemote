//
//  ClaudeTranscriptEntry.swift
//  XcodeAgentRemote
//
//  Lines of a session `.jsonl` transcript (only the fields read).
//

import Foundation

nonisolated extension ClaudeProvider {

    // MARK: - Transcript (.jsonl) entries

    /// One line of a session `.jsonl` transcript. Only the fields needed to rebuild the conversation are decoded.
    nonisolated struct TranscriptEntry: Decodable, Sendable {
        var type: String
        var uuid: String?
        var parentUUID: String?
        var sessionID: String?
        var isSidechain: Bool
        var isMeta: Bool
        var teamName: String?
        /// `attachment.type` for `attachment` entries.
        var attachmentType: String?
        /// `nil` for entries without an API message, or whose message could not be decoded.
        var message: APIMessage?

        private enum CodingKeys: String, CodingKey {
            case type, uuid, isSidechain, isMeta, teamName, attachment, message
            case parentUUID = "parentUuid"
            case sessionID = "sessionId"
        }

        private enum AttachmentKeys: String, CodingKey { case type }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
            parentUUID = try? container.decodeIfPresent(
                String.self,
                forKey: .parentUUID
            )
            sessionID = try? container.decodeIfPresent(
                String.self,
                forKey: .sessionID
            )
            isSidechain =
                (try? container.decodeIfPresent(Bool.self, forKey: .isSidechain))
                ?? false
            isMeta =
                (try? container.decodeIfPresent(Bool.self, forKey: .isMeta))
                ?? false
            teamName = try? container.decodeIfPresent(
                String.self,
                forKey: .teamName
            )
            attachmentType = try? container.nestedContainer(
                keyedBy: AttachmentKeys.self,
                forKey: .attachment
            )
            .decodeIfPresent(String.self, forKey: .type)
            message = try? container.decodeIfPresent(
                APIMessage.self,
                forKey: .message
            )
        }

        var toolUseIDs: [String] {
            message?.content.compactMap {
                if case .toolUse(let block) = $0 { block.id } else { nil }
            } ?? []
        }

        var toolResultIDs: [String] {
            message?.content.compactMap {
                if case .toolResult(let block) = $0 {
                    block.toolUseID
                } else {
                    nil
                }
            } ?? []
        }
    }

    /// A transcript line's `cwd`.
    struct TranscriptCWD: Decodable {
        var cwd: String?
    }
}
