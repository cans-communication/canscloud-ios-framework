//
//  ViewController.swift
//  DemoSwiftStoryboardApp
//
//  Created by Siraphop Chaisirikul on 6/12/2565 BE.
//

import UIKit
import CansConnect

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
        let cansBase = CansBase()
        cansBase.configure()
    }


}

