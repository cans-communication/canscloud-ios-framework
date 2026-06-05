//
//  CansBase.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation
import linphonesw

@objc public class CansBase: NSObject {

    private var cdrUsername: String = ""
    private var cdrPassword: String = ""

    public override init() {
    }

    /// Call once before `fetchCdrHistory`. Credentials are stored on this instance only — never globally.
    @objc public func configureCdr(username: String, password: String) {
        self.cdrUsername = username
        self.cdrPassword = password
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
        guard !cdrUsername.isEmpty else {
            print("[CansBase] fetchCdrHistory: call configureCdr(username:password:) before fetching.")
            completion(nil)
            return
        }

        let extensionSource = "extension_source=\(request.extensionSource)"
        let extension_destination = "extension_destination=\(request.extensionDestination)"
        let page = "page=\(String(request.page))"

        if let url = URL(string: "https://\(request.domain)/history?\(extensionSource)&\(extension_destination)&\(page)") {

            let credentialData = "\(cdrUsername):\(cdrPassword)".data(using: .utf8)!
            let base64Credentials = credentialData.base64EncodedString(options: [])
            
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "GET"
            urlRequest.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let configuration = URLSessionConfiguration.default
            let session = URLSession(configuration: configuration)
            
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
    
    @objc public func startCall(addr: OpaquePointer?, isSas: Bool) {
        CallManager.instance().startCall(addr: addr, isSas: isSas)
    }
    
    @objc public func terminateCall(call: OpaquePointer?) {
        CallManager.instance().terminateCall(call: call)
    }
    
    @objc public func acceptCall(call: OpaquePointer?, hasVideo:Bool) {
        CallManager.instance().acceptCall(call: call, hasVideo: hasVideo)
    }
    
    public func configureSwift() {
        // 🛑 temporary fix Bypass Problem App Group from Apple Developer
        /*
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
        */
        print("[CansBase] configureSwift bypassed due to App Group limitations.")
    }
    
    @objc public func setCore(core: OpaquePointer) {
        CallManager.instance().setCore(core: core)
        CoreManager.instance().setCore(core: core)
    }
    
    @objc public func configure() {
    }
    
    @objc public func registerWithObjC() {
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