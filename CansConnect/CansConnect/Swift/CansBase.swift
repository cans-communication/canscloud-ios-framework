//
//  CdrHistoryWorker.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation

@objc public class CansBase: NSObject, URLSessionDelegate {
    
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
        let extensionSource = "extension_source=\(request.extensionSource)"
        let extension_destination = "extension_destination=\(request.extensionDestination)"
        let page = "page=\(String(request.page))"
        
        if let url = URL(string: "https://\(request.domain)/history?\(extensionSource)&\(extension_destination)&\(page)") {
            
            let user = "cdr"
            let password = "AIzaSyC2ZpuUWO0QjkJXYpIXmxROuIdWPhY9Ub0"
            let credentialData = "\(user):\(password)".data(using: String.Encoding.utf8)!
            let base64Credentials = credentialData.base64EncodedString(options: [])
            
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let configuration = URLSessionConfiguration.default
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: OperationQueue.main)
            
            let task = session.dataTask(with: urlRequest, completionHandler: { (data, response, error) in
                guard let data = data, error == nil else {
                    print(error?.localizedDescription ?? "No data")
                    completion(nil)
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.keyDecodingStrategy = .convertFromSnakeCase

                    let cdrHistoryApi = try decoder.decode(CdrHistoryApi.self, from: data)
                    completion(cdrHistoryApi)
                } catch {
                    print(error)
                    completion(nil)
                }
            })
            task.resume()
        } else {
            completion(nil)
        }
      }
    
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "test.cans.cc" {
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    @objc public func startCall(addr: OpaquePointer?, isSas: Bool) {
        CansCallManager.instance().startCall(addr: addr, isSas: isSas)
    }
    
    @objc public func terminateCall(call: OpaquePointer?) {
        CansCallManager.instance().terminateCall(call: call)
    }
    
    @objc public func acceptCall(call: OpaquePointer?, hasVideo:Bool) {
        CansCallManager.instance().acceptCall(call: call, hasVideo: hasVideo)
    }
    
    public func configureSwift() {
        let filename = "linphonerc-factory"
        guard
            let path = Bundle.main.path(forResource: filename.fileName(), ofType: filename.fileExtension())
        else { return }
        do {
            let factoryConfigFilename = try String(contentsOfFile: path, encoding: String.Encoding.utf8)

            guard let config = Config.newForSharedCore(
                appGroupId: "group.cc.cans.canscloud.msgNotification",
                configFilename: "linphonerc",
                factoryConfigFilename: factoryConfigFilename
            ) else { return }

            let _ = try Factory.Instance.createSharedCoreWithConfig(
                config: config,
                systemContext: nil,
                appGroupId: "group.cc.cans.canscloud.msgNotification",
                mainCore: true
            )
        } catch {
            print(error)
        }
    }
    
    @objc public func setCore(core: OpaquePointer) {
        CansCallManager.instance().setCore(core: core)
        CansCoreManager.instance().setCore(core: core)
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
