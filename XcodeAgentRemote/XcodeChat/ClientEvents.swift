//
//  ClientEvents.swift
//  XcodeAgentRemote
//
//  Which of a turn's events go to the caller.
//

import Foundation

/// Which of a turn's events go to the caller. The provider streams them all (the turn's cards are built from all of
/// them); the caller doesn't get what it has already or what stands for something it has:
/// - a tool use that always waits for the user (a question, a plan): its `.userRequest` stands for it;
/// - the agent's repeat of the earlier tool use being answered (resuming a chat): its tool use and request (the caller
///   has the earlier one, and answered it);
/// - `.userResponse`: the caller sent the answer;
/// - the result of a tool use the user answered, unless it allowed a permission: the answer is its result. An allowed
///   permission's result is the tool's output.
nonisolated struct ClientEvents {
    let provider: any AgentProvider.Type
    /// The earlier tool use being answered, until the agent repeats it.
    var repeatedToolUse: ChatEvent.ToolUse?
    private var repeatID: String?
    private var answers: [String: ChatEvent.UserResponse] = [:]

    init(provider: any AgentProvider.Type, repeatedToolUse: ChatEvent.ToolUse?)
    {
        self.provider = provider
        self.repeatedToolUse = repeatedToolUse
    }

    /// Whether the caller gets this event (call it for every event, in order).
    mutating func passes(_ event: ChatEvent) -> Bool {
        switch event {
        case .toolUse(let toolUse):
            if let earlier = repeatedToolUse,
                provider.isSameCall(earlier, toolUse)
            {
                repeatedToolUse = nil
                repeatID = toolUse.id
                return false
            }
            return !provider.alwaysWaitsForUser(toolUse)
        case .userRequest(let request):
            return request.toolUseID != repeatID
        case .userResponse(let answer):
            answers[answer.toolUseID] = answer
            return false
        case .toolResult(let result):
            return answers[result.toolUseID]?.isAllowedPermission ?? true
        default:
            return true
        }
    }
}
