//
//  CdrHistoryWorker.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation
import linphone

@objc public class CansBase: NSObject {
    
    private let linphoneManager = CansLoManager()
    
    public override init() {
        
    }
    
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
        
        public init(domain: String, extensionSource: String, extensionDestination: String, page: Int) {
            self.domain = domain
            self.extensionSource = extensionSource
            self.extensionDestination = extensionDestination
            self.page = page
        }
    }
    
    public func fetchCdrHistory(request: CdrHistoryRequest, completion: @escaping (CdrHistoryApi?) -> Void) {
        let worker = CdrHistoryWorker()
        worker.fetchCdrHistory(request: request, completion: completion)
    }
    
    @objc public func startCall(addr: OpaquePointer?, isSas: Bool) {
        CallManager.instance().startCall(addr: addr, isSas: isSas)
    }
    
    @objc public func terminateCall(call: OpaquePointer?) {
        CallManager.instance().terminateCall(call: call)
    }
    
    @objc public func acceptCall(call: OpaquePointer?, hasVideo:Bool) {
        CallManager.instance().acceptCall(call: call, hasVideo: hasVideo)
    }
    
    @objc public func setCore(core: OpaquePointer) {
        CallManager.instance().setCore(core: core)
        CoreManager.instance().setCore(core: core)
    }
    
    @objc public func configure() {
        linphoneManager.createLinphoneCore()
        setCore(core: CansLoManager.getLc())
    }
    
    @objc public func registerWithObjC() {
        linphoneManager.registerSip()
    }
    
}

extension String {
    func fileName() -> String {
        return URL(fileURLWithPath: self).deletingPathExtension().lastPathComponent
    }
    
    func fileExtension() -> String {
        return URL(fileURLWithPath: self).pathExtension
    }
}
