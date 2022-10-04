//
//  CdrApi.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation

public struct CdrHistoryApi: Decodable {
    var cdrLists: [CdrList]
    var totalPage: Int
}

public struct CdrList: Decodable {
    let answerTime: String
    let conversationTime: String
    let date: String
    let status: String
    let cdrUuid: String
    let domainUuid: String
    let isRecording: Bool
}

public struct CdrHistoryRequest {
    let domain: String
    let extensionSource: String
    let extensionDestination: String
    let page: Int
}
