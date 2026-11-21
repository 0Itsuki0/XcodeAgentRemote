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
            forResource: "sample",
            withExtension: "json"
        )
    }
#endif
