//
//  CdrHistoryWorker.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation
import Alamofire

public class CansConnect {
    
    public init() {
        
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
    
    private let defaultManager: Session = {
        let manager = ServerTrustManager(allHostsMustBeEvaluated: false, evaluators: [
            "test.cans.cc": DisabledTrustEvaluator()
        ])
        let configuration = URLSessionConfiguration.af.default
        return Session(configuration: configuration, serverTrustManager: manager)
    }()

    public func fetchCdrHistory(request: CdrHistoryRequest, completion: @escaping (CdrHistoryApi?) -> Void) {
        let user = "cdr"
        let password = "AIzaSyC2ZpuUWO0QjkJXYpIXmxROuIdWPhY9Ub0"
        let credentialData = "\(user):\(password)".data(using: String.Encoding.utf8)!
        let base64Credentials = credentialData.base64EncodedString(options: [])
        let headers: HTTPHeaders = ["Authorization": "Basic \(base64Credentials)"]

        let parameters = [
            "extension_source": request.extensionSource,
            "extension_destination": request.extensionDestination,
            "page": String(request.page)
        ] as [String : Any]

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        defaultManager
            .request(
                "https://\(request.domain)/history",
                method: .get,
                parameters: parameters,
                encoding: URLEncoding.default,
                headers: headers
            )
            .validate()
            .responseDecodable(of: CdrHistoryApi.self, decoder: decoder) { response in
                    switch response.result {
                    case .failure(let error):
                        print(error)
                        completion(nil)
                    case .success(let data):
                        completion(data)
                    }
            }
    }

}
