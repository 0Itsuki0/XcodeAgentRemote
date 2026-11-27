//
//  URLs.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/25.
//

import Foundation

nonisolated extension String {
    static let gitHub = "https://github.com/0Itsuki0/XcodeAgentRemote"
}

nonisolated extension URL {
    static let gitHub: URL? = URL(string: .gitHub)
    static let privacy: URL? = URL(
        string: "https://0itsuki0.github.io/XcodeAgentRemote/privacy"
    )
}
