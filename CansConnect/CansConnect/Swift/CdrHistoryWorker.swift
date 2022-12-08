//
//  CdrHistoryWorker.swift
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 8/12/2565 BE.
//

import Foundation


class CdrHistoryWorker: NSObject, URLSessionDelegate {
    
    func fetchCdrHistory(request: CansBase.CdrHistoryRequest, completion: @escaping (CansBase.CdrHistoryApi?) -> Void) {
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
                    
                    let cdrHistoryApi = try decoder.decode(CansBase.CdrHistoryApi.self, from: data)
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
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "test.cans.cc" {
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
