//
//  Item.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
