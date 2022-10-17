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
    
    private let defaultManager: Session = {
        let manager = ServerTrustManager(allHostsMustBeEvaluated: false, evaluators: [
            "test.cans.cc": DisabledTrustEvaluator()
        ])
        let configuration = URLSessionConfiguration.af.default
        return Session(configuration: configuration, serverTrustManager: manager)
    }()

    public func fetchCdrHistoryWithAlamofire(request: CdrHistoryRequest, completion: @escaping (CdrHistoryApi?) -> Void) {
        let user = "cdr"
        let password = "***REMOVED***"
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
    
    func fetchCdrHistory(request: CdrHistoryRequest, completion: @escaping (CdrHistoryApi?) -> Void) {
        let json = [
            "extension_source": request.extensionSource,
            "extension_destination": request.extensionDestination,
            "page": String(request.page)
        ] as [String : Any]
        
        let jsonData = try? JSONSerialization.data(withJSONObject: json)
        
        let user = "cdr"
        let password = "***REMOVED***"
        let credentialData = "\(user):\(password)".data(using: String.Encoding.utf8)!
        let base64Credentials = credentialData.base64EncodedString(options: [])
        
        if let url = URL(string: "https://\(request.domain)/history") {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Basic \(base64Credentials)", forHTTPHeaderField: "Authorization")
            request.httpBody = jsonData
            
            let task = URLSession.shared.dataTask(with: url, completionHandler: { (data, response, error) in
                guard let data = data, error == nil else {
                    print(error?.localizedDescription ?? "No data")
                    return
                }
                
                do {
                    let cdrHistoryApi = try JSONDecoder().decode(CdrHistoryApi.self, from: data)
                    print(cdrHistoryApi)
                } catch {
                    print(error)
                }
            })
            task.resume()
        } else {
            completion(nil)
        }
      }

}
