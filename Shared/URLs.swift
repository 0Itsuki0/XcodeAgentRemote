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
    // TODO: - add privacy url
    static let privacy: URL? = URL(string: "")
}
