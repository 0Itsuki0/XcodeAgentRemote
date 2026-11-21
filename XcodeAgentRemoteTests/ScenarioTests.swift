//
//  ScenarioTests.swift
//  XcodeAgentRemoteTests
//
///  The end-to-end scenarios (`TestScenarios`), as tests: real agent turns against the chats of `project`.
///  - directly with the Mac app's functions (`runDirect`);
///  - through the Mac app's server (`APIServer`, started on a free port) with the iOS app's client (`runThroughServer`).
///  Each turn closes the project in Xcode first (`closeProject`). They take minutes.
///
/// `xcodebuild test -only-testing:XcodeAgentRemoteTests/ScenarioTests`

import Foundation
import Testing

@testable import XcodeAgentRemote

@Suite(.serialized)
struct ScenarioTests {

    /// The project whose chats the scenarios use (and close in Xcode).
    static let project = URL(
        filePath:
            "/Users/itsuki/Desktop/Swift/***General/Demo10/Demo10.xcodeproj"
    )

    @Test func direct() async {
        let results = await TestScenarios.runDirect(project: Self.project)
        #expect(!results.isEmpty)
        for result in results {
            #expect(result.passed, "\(result)")
        }
    }

    
    // TODO: - create a test target for iOS and move it there
    //        @Test func throughServer() async throws {
    //            let server = APIServer()
    //            let port = try await server.start(port: 0)
    //            guard let client = APIServerClient(host: "127.0.0.1", port: port) else {
    //                return
    //            }
    //            let results = await TestScenarios.runThroughServer(
    //                client: client,
    //                project: Self.project
    //            )
    //            await server.stop()
    //            #expect(!results.isEmpty)
    //            for result in results {
    //                #expect(result.passed, "\(result)")
    //            }
    //        }
}
