//
//  TestAccess.swift
//  canscloud-ios-framework
//
//  Created by Siraphop Chaisirikul on 3/10/2565 BE.
//

import Foundation

public class AllowAccess {
    public func display() {
        print("Can Access")
    }
    
    private func doNotDisplay() {
        print("Can not Access")
    }
}

class NotAllowAccess {
    func display() {
        print("Can Access")
    }
    
    private func doNotDisplay() {
        print("Can not Access")
    }
}


