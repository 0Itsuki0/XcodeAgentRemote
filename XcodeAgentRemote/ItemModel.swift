//
//  Item.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/14.
//

import Foundation
import SwiftData

@Model
final class ItemModel {
    var timestamp: Date = Date()
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
