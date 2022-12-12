//
//  LinphoneManager.swift
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 7/12/2565 BE.
//

import Foundation
import linphone

var answerCall: Bool = false

struct theLinphone {
    static var lc: OpaquePointer?
    static var lct: LinphoneCoreVTable?
    static var manager: SwiftLinphoneManager?
}

let registrationStateChanged: LinphoneCoreRegistrationStateChangedCb  = {
    (lc: Optional<OpaquePointer>, proxyConfig: Optional<OpaquePointer>, state: _LinphoneRegistrationState, message: Optional<UnsafePointer<Int8>>) in
    
    switch state{
    case LinphoneRegistrationNone: /**<Initial state for registrations */
        NSLog("LinphoneRegistrationNone")
        
    case LinphoneRegistrationProgress:
        NSLog("LinphoneRegistrationProgress")
        
    case LinphoneRegistrationOk:
        NSLog("LinphoneRegistrationOk")
        
    case LinphoneRegistrationCleared:
        NSLog("LinphoneRegistrationCleared")
        
    case LinphoneRegistrationFailed:
        NSLog("LinphoneRegistrationFailed")
        
    default:
        NSLog("Unkown registration state")
    }
} as LinphoneCoreRegistrationStateChangedCb

let callStateChanged: LinphoneCoreCallStateChangedCb = {
    (lc: Optional<OpaquePointer>, call: Optional<OpaquePointer>, callSate: LinphoneCallState,  message: Optional<UnsafePointer<Int8>>) in
    
    switch callSate {
    case LinphoneCallStateIncomingReceived: /**<This is a new incoming call */
        NSLog("callStateChanged: LinphoneCallIncomingReceived")

        if answerCall {
            ms_usleep(3 * 1000 * 1000); // Wait 3 seconds to pickup
            linphone_core_accept_call(lc, call)
        }
    case LinphoneCallStateStreamsRunning: /**<The media streams are established and running*/
        NSLog("callStateChanged: LinphoneCallStreamsRunning")
    case LinphoneCallStateError:  /**<The call encountered an error*/
        NSLog("callStateChanged: LinphoneCallError")
    default:
        NSLog("Default call state")
    }
}


class SwiftLinphoneManager {
    static var iterateTimer: Timer?
    
    init() {
        theLinphone.lct = LinphoneCoreVTable()
        
        // Enable debug log to stdout
        linphone_core_set_log_file(nil)
        linphone_core_set_log_level(BCTBX_LOG_DEBUG)
        
        // Load config
        let configFilename = documentFile("linphonerc")
        let factoryConfigFilename = bundleFile("linphonerc-factory")
        
        let configFilenamePtr: UnsafePointer<Int8> = configFilename.cString(using: String.Encoding.utf8.rawValue)!
        let factoryConfigFilenamePtr: UnsafePointer<Int8> = factoryConfigFilename.cString(using: String.Encoding.utf8.rawValue)!
//        let lpConfig = lp_config_new_with_factory(configFilenamePtr, factoryConfigFilenamePtr)
    }
    
    fileprivate func bundleFile(_ file: NSString) -> NSString{
        return Bundle.main.path(forResource: file.deletingPathExtension, ofType: file.pathExtension)! as NSString
    }
    
    fileprivate func documentFile(_ file: NSString) -> NSString {
        let paths = NSSearchPathForDirectoriesInDomains(FileManager.SearchPathDirectory.documentDirectory, FileManager.SearchPathDomainMask.userDomainMask, true)
        
        let documentsPath: NSString = paths[0] as NSString
        return documentsPath.appendingPathComponent(file as String) as NSString
    }
}
