//
//  PlanWithoutPlanTests.swift
//  XcodeAgentRemoteTests
//
//  An ExitPlanMode whose tool use has no `plan` (the agent wrote the plan file in the same message): its request is
//  still a plan, with the plan taken from the result line (answered) or the plan file's `Write` (waiting).
//  Live, the plan comes from the permission request. An ExitPlanMode with `plan` keeps its own.
//

#if os(macOS)
import Foundation
import Testing
@testable import XcodeAgentRemote

struct PlanWithoutPlanTests {
    private let planID = "toolu_plan"
    private let writeID = "toolu_write"
    private let planFile = ClaudeProvider.configDirectory.appending(path: "plans/test-plan.md").path

    private var writePlanFile: ChatEvent {
        .toolUse(ChatEvent.ToolUse(
            id: writeID, name: "Write", input: ["file_path": .string(planFile), "content": .string("# Written plan")]))
    }

    private func exitPlanMode(_ input: [String: JSONValue]) -> ChatEvent {
        .toolUse(ChatEvent.ToolUse(id: planID, name: "ExitPlanMode", input: input))
    }

    /// The result line of the approved plan, as Claude writes it.
    private func approvedLine(plan: String) throws -> Data {
        let line: [String: JSONValue] = [
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string(planID),
                "content": .string("User has approved your plan."),
            ])])]),
            "permissionDecision": .object(["decision": .string("accept"), "source": .string("user_temporary")]),
            "toolUseResult": .object(["plan": .string(plan)]),
        ]
        return try JSONEncoder().encode(line)
    }

    private func requests(_ events: [ChatEvent], transcript: Data = Data()) -> [ChatEvent.UserRequest] {
        ClaudeProvider.addingUserRequests(to: events, transcript: transcript, sessionID: UUID().uuidString)
            .compactMap { if case .userRequest(let request) = $0 { request } else { nil } }
    }

    @Test func answeredPlanTakesResultPlan() throws {
        let events: [ChatEvent] = [
            writePlanFile,
            exitPlanMode([:]),
            .toolResult(ChatEvent.ToolResult(toolUseID: planID, output: "User has approved your plan.", isError: false)),
        ]
        let requests = requests(events, transcript: try approvedLine(plan: "# Approved plan"))
        #expect(requests == [.planApproval(toolUseID: planID, plan: "# Approved plan")])
    }

    @Test func waitingPlanTakesWrittenPlan() {
        #expect(requests([writePlanFile, exitPlanMode([:])]) == [.planApproval(toolUseID: planID, plan: "# Written plan")])
    }

    @Test func planInInputIsKept() throws {
        let events: [ChatEvent] = [
            writePlanFile,
            exitPlanMode(["plan": .string("# Own plan")]),
            .toolResult(ChatEvent.ToolResult(toolUseID: planID, output: "User has approved your plan.", isError: false)),
        ]
        #expect(requests(events, transcript: try approvedLine(plan: "# Approved plan"))
            == [.planApproval(toolUseID: planID, plan: "# Own plan")])
        #expect(requests([writePlanFile, exitPlanMode(["plan": .string("# Own plan")])])
            == [.planApproval(toolUseID: planID, plan: "# Own plan")])
    }

    /// Live: the permission request (`can_use_tool`) has the plan the tool use lacks.
    @Test func liveRequestTakesRequestPlan() {
        let requestInput: [String: JSONValue] = ["plan": .string("# Requested plan"), "planFilePath": .string(planFile)]
        let asked = ClaudeProvider.askedToolUse(
            ChatEvent.ToolUse(id: planID, name: "ExitPlanMode", input: [:]), requestInput: requestInput)
        #expect(asked.input["plan"] == .string("# Requested plan"))
        #expect(ClaudeProvider.userRequest(for: asked, decidedByUser: nil, isLastMessage: true)
            == .planApproval(toolUseID: planID, plan: "# Requested plan"))
    }

    /// Live: an ExitPlanMode with its plan, or any other tool use, is asked as it is.
    @Test func liveRequestKeepsOwnInput() {
        let requestInput: [String: JSONValue] = ["plan": .string("# Requested plan")]
        let withPlan = ChatEvent.ToolUse(id: planID, name: "ExitPlanMode", input: ["plan": .string("# Own plan")])
        #expect(ClaudeProvider.askedToolUse(withPlan, requestInput: requestInput) == withPlan)
        let bash = ChatEvent.ToolUse(id: "toolu_bash", name: "Bash", input: ["command": .string("ls")])
        #expect(ClaudeProvider.askedToolUse(bash, requestInput: requestInput) == bash)
    }

    /// Its tool use isn't streamed to the caller (only its request), like any plan.
    @Test func alwaysWaitsForUser() {
        let toolUse = ChatEvent.ToolUse(id: planID, name: "ExitPlanMode", input: [:])
        #expect(ClaudeProvider.isPlanWithoutPlan(toolUse))
        #expect(ClaudeProvider.alwaysWaitsForUser(toolUse))
    }
}
#endif
