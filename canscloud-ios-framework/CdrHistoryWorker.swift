//
//  CdrHistoryWorker.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 16/2/2565 BE.
//

import Foundation
//import Alamofire

public class CdrHistoryWorker {
    
    public init() {
        
    }
    
//    let defaultManager: Session = {
//        let manager = ServerTrustManager(allHostsMustBeEvaluated: false, evaluators: [
//            "test.cans.cc": DisabledTrustEvaluator()
//        ])
//        let configuration = URLSessionConfiguration.af.default
//        return Session(configuration: configuration, serverTrustManager: manager)
//    }()
//
//    public func fetch(request: CdrHistoryRequest, completion: @escaping (CdrHistoryApi?) -> Void) {
//        let user = "cdr"
//        let password = "AIzaSyC2ZpuUWO0QjkJXYpIXmxROuIdWPhY9Ub0"
//        let credentialData = "\(user):\(password)".data(using: String.Encoding.utf8)!
//        let base64Credentials = credentialData.base64EncodedString(options: [])
//        let headers: HTTPHeaders = ["Authorization": "Basic \(base64Credentials)"]
//
//        let parameters = [
//            "extension_source": request.extensionSource,
//            "extension_destination": request.extensionDestination,
//            "page": String(request.page)
//        ] as [String : Any]
//
//        let decoder = JSONDecoder()
//        decoder.keyDecodingStrategy = .convertFromSnakeCase
//
//        defaultManager
//            .request(
//                "https://\(request.domain)/history",
//                method: .get,
//                parameters: parameters,
//                encoding: URLEncoding.default,
//                headers: headers
//            )
//            .validate()
//            .responseDecodable(of: CdrHistoryApi.self, decoder: decoder) { response in
//                    switch response.result {
//                    case .failure(let error):
//                        print(error)
//                        completion(nil)
//                    case .success(let data):
//                        completion(data)
//                    }
//            }
//    }
//
}
