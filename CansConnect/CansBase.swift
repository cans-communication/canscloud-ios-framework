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

    /// Step 1 of the foreground-answer audio handoff: configure AVAudioSession
    /// category/mode (.playAndRecord + .voiceChat) BEFORE accepting the call.
    /// Called from LinphoneManager.m acceptCall / acceptVideoCall right after
    /// stopForegroundRingtone deactivates the .playback session.
    /// Does NOT start Linphone's audio unit — streams don't exist yet.
    @objc public func configureLinphoneAudioSession() {
        CallManager.instance().lc?.configureAudioSession()
        NSLog("[CansBase] configureLinphoneAudioSession: AVAudioSession category/mode set (.playAndRecord + .voiceChat)")
    }

    /// Step 2 of the foreground-answer audio handoff: start Linphone's audio pipeline.
    /// Must be called AFTER RTP streams exist (i.e. at or after StreamsRunning), not
    /// before acceptWithParams. With use_callkit=1, activateAudioSession is a no-op
    /// when called before streams are created; calling it here ensures effectiveness.
    /// Also called redundantly by provider(_:didActivate:) in the background path —
    /// calling it twice is idempotent and harmless.
    @objc public func activateLinphoneAudioSession() {
        CallManager.instance().lc?.activateAudioSession(activated: true)
        NSLog("[CansBase] activateLinphoneAudioSession: audio pipeline activated (streams running)")
    }

    /// Legacy combined helper kept for callers that have not been updated.
    @objc public func configureAndActivateAudioSession() {
        configureLinphoneAudioSession()
        activateLinphoneAudioSession()
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

    /// Called from LinphoneManager.m after linphone_core_start to wire CallManager.lc.
    /// Static so ObjC can call [CansBase wireCallManagerCore:theLinphoneCore] without
    /// needing CallManager (which is internal-only) in the generated ObjC header.
    @objc public static func wireCallManagerCore(_ core: OpaquePointer) {
        CallManager.instance().setCore(core: core)
    }

    /// Called from AppDelegate's PKPushRegistryDelegate when a VoIP push arrives.
    /// Must be called synchronously on the main thread before the PushKit completion handler returns.
    /// hasVideo should be parsed from the push payload; defaults to false (audio) when absent.
    @objc public static func reportIncomingVoIPCall(callId: String, hasVideo: Bool = false) {
        CallManager.instance().displayIncomingCall(callId: callId, hasVideo: hasVideo)
    }

    /// Immediately ends the CallKit representation of a just-reported incoming call.
    /// Use this when the app is Active and you reported to CallKit only to satisfy the
    /// iOS 13+ PushKit mandate — call this right after reportIncomingVoIPCall so the
    /// banner is dismissed before it renders, letting your custom UI handle the call.
    @objc public static func endIncomingCallInCallKit(callId: String) {
        guard let uuid = CallManager.instance().providerDelegate?.uuids[callId] else { return }
        CallManager.instance().providerDelegate?.endCall(uuid: uuid, reason: .answeredElsewhere)
    }

    /// Ensures the Linphone core is initialized and processes the push callId.
    /// Call early in didFinishLaunchingWithOptions (callId = "") to pre-warm the core,
    /// and again from the PushKit handler with the real callId.
    /// LinphoneManager.+load registers the observer before main() runs, so the
    /// notification is never lost regardless of when this is called.
    @objc public static func initializeCoreForPushWakeup(callId: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("CansEarlyVoIPPushWakeup"),
            object: nil,
            userInfo: ["callId": callId]
        )
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