//
//  ResponseEncodable.swift
//  XcodeAgentRemote
//
//  Created by Itsuki on 2026/11/26.
//

import Hummingbird

extension SuccessResponse: ResponseEncodable {}
extension XcodeProject: ResponseEncodable {}
extension XcodeConversationDetail: ResponseEncodable {}
extension AgentProviderInfo: ResponseEncodable {}
extension ChatEvent: ResponseEncodable {}
