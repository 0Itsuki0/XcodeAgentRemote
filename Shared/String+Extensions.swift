//
//  String+Extensions.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/24.
//

import Foundation

extension String {
    var trimmed: String {
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
