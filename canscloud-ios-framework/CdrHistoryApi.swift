//
//  CdrApi.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation

public struct CdrHistoryApi: Decodable {
    public var cdrLists: [CdrList]
    public var totalPage: Int
}

public struct CdrList: Decodable {
    public let answerTime: String
    public let conversationTime: String
    public let date: String
    public let status: String
    public let cdrUuid: String
    public let domainUuid: String
    public let isRecording: Bool
}

public struct CdrHistoryRequest {
    public let domain: String
    public let extensionSource: String
    public let extensionDestination: String
    public let page: Int
}
