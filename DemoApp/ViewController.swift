//
//  ViewController.swift
//  DemoApp
//
//  Created by Siraphop Chaisirikul on 17/10/2565 BE.
//

import UIKit
import canscloud_ios_framework

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        let cdrHistoryRequest = CansConnect.CdrHistoryRequest(
            domain: "test.cans.cc",
            extensionSource: "50101",
            extensionDestination: "50102",
            page: 1
        )
        
        let cansConnect = CansConnect()
        cansConnect.fetchCdrHistory(request: cdrHistoryRequest) { cdrHistoryApi in
            print(cdrHistoryApi)
        }
    }

}

