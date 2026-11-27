//
//  ClaudeRequestTypes.swift
//  XcodeAgentRemote
//
//  What a transcript says about how the user settled a request (only the fields read).
//

import Foundation

nonisolated extension ClaudeProvider {

    /// How the user settled a request.
    enum Settled {
        /// Allowed (answered, approved) or not.
        case answered(allowed: Bool)
        /// Not answered in time: the app denied it.
        case timedOut
    }

    /// What a result line says about the decision.
    struct UserDecision {
        /// `permissionDecision.source`.
        var source: String
        /// `permissionDecision.decision`: "accept" or "reject".
        var decision: String?
        /// The answers to questions (`toolUseResult.answers`, `{"<question>": "<label>, <label>"}`), by question.
        var answers: [String: [String]]
        /// The plan of an ExitPlanMode (`toolUseResult.plan`).
        var plan: String?
    }

    /// A transcript line's tool results, its `permissionDecision` and `toolUseResult` (only the fields read here).
    struct DecidedResultLine: Decodable {
        struct Decision: Decodable {
            var source: String?
            var decision: String?
        }
        struct Message: Decodable {
            struct Block: Decodable {
                var toolUseID: String?
                enum CodingKeys: String, CodingKey {
                    case toolUseID = "tool_use_id"
                }
            }
            var content: [Block]?

            init(from decoder: Decoder) throws {
                // `content` is a string for a prompt: no tool results.
                content = try? decoder.container(keyedBy: CodingKeys.self)
                    .decode([Block].self, forKey: .content)
            }
            enum CodingKeys: String, CodingKey { case content }
        }
        var permissionDecision: Decision?
        var message: Message?
        var toolUseResult: JSONValue?
    }
}
