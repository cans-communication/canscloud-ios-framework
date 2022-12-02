/*
* Copyright (c) 2010-2020 Belledonne Communications SARL.
*
* This file is part of linphone-iphone
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with this program. If not, see <http://www.gnu.org/licenses/>.
*/

import Foundation
//import linphonesw
import UserNotifications
import os
import CallKit
import AVFoundation

@objc class CansCallAppData: NSObject {
	@objc var batteryWarningShown = false
	@objc var videoRequested = false /*set when user has requested for video*/
}

/*
* CansCallManager is a class that manages application calls and supports callkit.
* There is only one CansCallManager by calling CansCallManager.instance().
*/
@objc class CansCallManager: NSObject, CoreDelegate {
	static public var theCansCallManager: CansCallManager?
    public let providerDelegate: CansProviderDelegate! // to support callkit
	public let callController: CXCallController! // to support callkit
	var lc: Core?
	@objc public var speakerBeforePause : Bool = false
	@objc var nextCallIsTransfer: Bool = false
	@objc var alreadyRegisteredForNotification: Bool = false
	var referedFromCall: String?
	var referedToCall: String?
	var endCallkit: Bool = false
	var globalState : GlobalState = .Off
	var actionsToPerformOnceWhenCoreIsOn : [(()->Void)] = []
    var callkitAudioSessionActivated : Bool? = nil // if "nil", ignore.
    
    var backgroundContextCall : Call?
    @objc var backgroundContextCameraIsEnabled : Bool = false

    fileprivate override init() {
		providerDelegate = CansProviderDelegate()
		callController = CXCallController()
	}

	@objc public static func instance() -> CansCallManager {
		if (theCansCallManager == nil) {
			theCansCallManager = CansCallManager()
		}
		return theCansCallManager!
	}

	@objc func setCore(core: OpaquePointer) {
		lc = Core.getSwiftObject(cObject: core)
		lc?.addDelegate(delegate: self)
	}

	@objc static func getAppData(call: OpaquePointer) -> CansCallAppData? {
		let sCall = Call.getSwiftObject(cObject: call)
		return getAppData(sCall: sCall)
	}
	
	static func getAppData(sCall:Call) -> CansCallAppData? {
		if (sCall.userData == nil) {
			return nil
		}
		return Unmanaged<CansCallAppData>.fromOpaque(sCall.userData!).takeUnretainedValue()
	}

	@objc static func setAppData(call:OpaquePointer, appData: CansCallAppData) {
		let sCall = Call.getSwiftObject(cObject: call)
		setAppData(sCall: sCall, appData: appData)
	}
	
	static func setAppData(sCall:Call, appData:CansCallAppData?) {
		if (sCall.userData != nil) {
			Unmanaged<CansCallAppData>.fromOpaque(sCall.userData!).release()
		}
		if (appData == nil) {
			sCall.userData = nil
		} else {
			sCall.userData = UnsafeMutableRawPointer(Unmanaged.passRetained(appData!).toOpaque())
		}
	}

	@objc func findCall(callId: String?) -> OpaquePointer? {
		let call = callByCallId(callId: callId)
		return call?.getCobject
	}

	func callByCallId(callId: String?) -> Call? {
		if (callId == nil) {
			return nil
		}
		let calls = lc?.calls
		if let callTmp = calls?.first(where: { $0.callLog?.callId == callId }) {
			return callTmp
		}
		return nil
	}

	@objc static func callKitEnabled() -> Bool {
//		#if !targetEnvironment(simulator)
//		if ConfigManager.instance().lpConfigBoolForKey(key: "use_callkit", section: "app") {
//			return true
//		}
//		#endif
		return false
	}

	func requestTransaction(_ transaction: CXTransaction, action: String) {
		callController.request(transaction) { error in
			if let error = error {
//				Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: Requested transaction \(action) failed because: \(error)")
			} else {
//				Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: Requested transaction \(action) successfully")
			}
		}
	}
	
	@objc func updateCallId(previous: String, current: String) {
        let uuid = CansCallManager.instance().providerDelegate?.uuids["\(previous)"]
		if (uuid != nil) {
            CansCallManager.instance().providerDelegate?.uuids.removeValue(forKey: previous)
            CansCallManager.instance().providerDelegate?.uuids.updateValue(uuid!, forKey: current)
            let callInfo = providerDelegate?.callInfos[uuid!]
			if (callInfo != nil) {
				callInfo!.callId = current
                providerDelegate?.callInfos.updateValue(callInfo!, forKey: uuid!)
			}
		}
	}

	// From ios13, display the callkit view when the notification is received.
	@objc func displayIncomingCall(callId: String) {
        let uuid = CansCallManager.instance().providerDelegate?.uuids["\(callId)"]
		if (uuid != nil) {
            let callInfo = providerDelegate?.callInfos[uuid!]
			if (callInfo?.declined ?? false) {
				// This call was declined.
                providerDelegate?.reportIncomingCall(call:nil, uuid: uuid!, handle: "Calling", hasVideo: true, displayName: callInfo?.displayName ?? "Calling")
                providerDelegate?.endCall(uuid: uuid!)
			}
			return
		}

		let call = CansCallManager.instance().callByCallId(callId: callId)
		if (call != nil) {
//			let displayName = FastAddressBook.displayName(for: call?.remoteAddress?.getCobject) ?? "Unknow"
            let displayName = "Unknow"
//			let video = UIApplication.shared.applicationState == .active && (lc!.videoActivationPolicy?.automaticallyAccept ?? false) && (call!.remoteParams?.videoEnabled ?? false)
            let video = false
			displayIncomingCall(call: call, handle: (call!.remoteAddress?.asStringUriOnly())!, hasVideo: video, callId: callId, displayName: displayName)
		} else {
			displayIncomingCall(call: nil, handle: "Calling", hasVideo: true, callId: callId, displayName: "Calling")
		}
	}

	func displayIncomingCall(call:Call?, handle: String, hasVideo: Bool, callId: String, displayName:String) {
		let uuid = UUID()
		let callInfo = CansCallInfo.newIncomingCallInfo(callId: callId)

        providerDelegate?.callInfos.updateValue(callInfo, forKey: uuid)
        providerDelegate?.uuids.updateValue(uuid, forKey: callId)
        providerDelegate?.reportIncomingCall(call:call, uuid: uuid, handle: handle, hasVideo: hasVideo, displayName: displayName)
		
	}

	@objc func acceptCall(call: OpaquePointer?, hasVideo:Bool) {
		if (call == nil) {
//			Log.directLog(BCTBX_LOG_ERROR, text: "Can not accept null call!")
			return
		}
		let call = Call.getSwiftObject(cObject: call!)
		acceptCall(call: call, hasVideo: hasVideo)
	}

	func acceptCall(call: Call, hasVideo:Bool) {
		do {
			let callParams = try lc!.createCallParams(call: call)
			callParams.videoEnabled = hasVideo
//			if (ConfigManager.instance().lpConfigBoolForKey(key: "edge_opt_preference")) {
//				let low_bandwidth = (CansAppManager.network() == .network_2g)
//				if (low_bandwidth) {
//					Log.directLog(BCTBX_LOG_MESSAGE, text: "Low bandwidth mode")
//				}
//				callParams.lowBandwidthEnabled = low_bandwidth
//			}

			//We set the record file name here because we can't do it after the call is started.
			let address = call.callLog?.fromAddress
			let writablePath = CansAppManager.recordingFilePathFromCall(address: address?.username ?? "")
//			Log.directLog(BCTBX_LOG_MESSAGE, text: "Record file path: \(String(describing: writablePath))")
			callParams.recordFile = writablePath

			try call.acceptWithParams(params: callParams)
		} catch {
//			Log.directLog(BCTBX_LOG_ERROR, text: "accept call failed \(error)")
		}
	}

	// for outgoing call. There is not yet callId
	@objc func startCall(addr: OpaquePointer?, isSas: Bool) {
        guard let addr = addr else {
            print("Can not start a call with null address!")
            return
        }

		let sAddr = Address.getSwiftObject(cObject: addr)
		if (CansCallManager.callKitEnabled() && !CansCallManager.instance().nextCallIsTransfer) {
			let uuid = UUID()
//			let name = FastAddressBook.displayName(for: addr) ?? "unknow"
            let name = "unknow"
			let handle = CXHandle(type: .generic, value: sAddr.asStringUriOnly())
			let startCallAction = CXStartCallAction(call: uuid, handle: handle)
			let transaction = CXTransaction(action: startCallAction)

			let callInfo = CansCallInfo.newOutgoingCallInfo(addr: sAddr, isSas: isSas, displayName: name)
            providerDelegate?.callInfos.updateValue(callInfo, forKey: uuid)
            providerDelegate?.uuids.updateValue(uuid, forKey: "")

			setHeldOtherCalls(exceptCallid: "")
			requestTransaction(transaction, action: "startCall")
		} else {
			try? doCall(addr: sAddr, isSas: isSas)
		}
	}

	func doCall(addr: Address, isSas: Bool) throws {
//		let displayName = FastAddressBook.displayName(for: addr.getCobject)
        var displayName: String?

		let lcallParams = try CansCallManager.instance().lc!.createCallParams(call: nil)
//		if ConfigManager.instance().lpConfigBoolForKey(key: "edge_opt_preference") && CansAppManager.network() == .network_2g {
//			Log.directLog(BCTBX_LOG_MESSAGE, text: "Enabling low bandwidth mode")
//			lcallParams.lowBandwidthEnabled = true
//		}

		if (displayName != nil) {
			try addr.setDisplayname(newValue: displayName!)
		}

//		if(ConfigManager.instance().lpConfigBoolForKey(key: "override_domain_with_default_one")) {
//			try addr.setDomain(newValue: ConfigManager.instance().lpConfigStringForKey(key: "domain", section: "assistant"))
//		}

		if (CansCallManager.instance().nextCallIsTransfer) {
			let call = CansCallManager.instance().lc!.currentCall
			try call?.transferTo(referTo: addr)
			CansCallManager.instance().nextCallIsTransfer = false
		} else {
			//We set the record file name here because we can't do it after the call is started.
			let writablePath = CansAppManager.recordingFilePathFromCall(address: addr.username )
//			Log.directLog(BCTBX_LOG_DEBUG, text: "record file path: \(writablePath)")
			lcallParams.recordFile = writablePath
			if (isSas) {
				lcallParams.mediaEncryption = .ZRTP
			}
			let call = CansCallManager.instance().lc!.inviteAddressWithParams(addr: addr, params: lcallParams)
			if (call != nil) {
				// The LinphoneCansCallAppData object should be set on call creation with callback
				// - (void)onCall:StateChanged:withMessage:. If not, we are in big trouble and expect it to crash
				// We are NOT responsible for creating the AppData.
				let data = CansCallManager.getAppData(sCall: call!)
				if (data == nil) {
//					Log.directLog(BCTBX_LOG_ERROR, text: "New call instanciated but app data was not set. Expect it to crash.")
					/* will be used later to notify user if video was not activated because of the linphone core*/
				} else {
					data!.videoRequested = lcallParams.videoEnabled
					CansCallManager.setAppData(sCall: call!, appData: data)
				}
			}
		}
	}

	@objc func groupCall() {
		if (CansCallManager.callKitEnabled()) {
			let calls = lc?.calls
			if (calls == nil || calls!.isEmpty) {
				return
			}
			let firstCall = calls!.first?.callLog?.callId ?? ""
			let lastCall = (calls!.count > 1) ? calls!.last?.callLog?.callId ?? "" : ""

            let currentUuid = CansCallManager.instance().providerDelegate?.uuids["\(firstCall)"]
			if (currentUuid == nil) {
//				Log.directLog(BCTBX_LOG_ERROR, text: "Can not find correspondant call to group.")
				return
			}

            let newUuid = CansCallManager.instance().providerDelegate?.uuids["\(lastCall)"]
			let groupAction = CXSetGroupCallAction(call: currentUuid!, callUUIDToGroupWith: newUuid)
			let transcation = CXTransaction(action: groupAction)
			requestTransaction(transcation, action: "groupCall")

//			setResumeCalls()
		} else {
			try? lc?.addAllToConference()
		}
	}

	@objc func removeAllCallInfos() {
        providerDelegate?.callInfos.removeAll()
        providerDelegate?.uuids.removeAll()
	}

	@objc func terminateCall(call: OpaquePointer?) {
		if (call == nil) {
//			Log.directLog(BCTBX_LOG_ERROR, text: "Can not terminate null call!")
			return
		}
		let call = Call.getSwiftObject(cObject: call!)
		do {
			try call.terminate()
//			Log.directLog(BCTBX_LOG_DEBUG, text: "Call terminated")
		} catch {
//			Log.directLog(BCTBX_LOG_ERROR, text: "Failed to terminate call failed because \(error)")
		}
	}

	@objc func markCallAsDeclined(callId: String) {
		if !CansCallManager.callKitEnabled() {
			return
		}

        let uuid = providerDelegate?.uuids["\(callId)"]
		if (uuid == nil) {
//			Log.directLog(BCTBX_LOG_MESSAGE, text: "Mark call \(callId) as declined.")
			let uuid = UUID()
            providerDelegate?.uuids.updateValue(uuid, forKey: callId)
			let callInfo = CansCallInfo.newIncomingCallInfo(callId: callId)
			callInfo.declined = true
			callInfo.reason = Reason.Busy
            providerDelegate?.callInfos.updateValue(callInfo, forKey: uuid)
		} else {
			// end call
            providerDelegate?.endCall(uuid: uuid!)
		}
	}

	@objc func setHeld(call: OpaquePointer, hold: Bool) {
		let sCall = Call.getSwiftObject(cObject: call)
		if (!hold) {
			setHeldOtherCalls(exceptCallid: sCall.callLog?.callId ?? "")
		}
		setHeld(call: sCall, hold: hold)
	}
	
	func setHeld(call: Call, hold: Bool) {
		let callid = call.callLog?.callId ?? ""
        let uuid = providerDelegate?.uuids["\(callid)"]
		if (uuid == nil) {
//			Log.directLog(BCTBX_LOG_ERROR, text: "Can not find correspondant call to set held.")
			return
		}
		let setHeldAction = CXSetHeldCallAction(call: uuid!, onHold: hold)
		let transaction = CXTransaction(action: setHeldAction)
		requestTransaction(transaction, action: "setHeld")
	}

	@objc func setHeldOtherCalls(exceptCallid: String) {
		for call in CansCallManager.instance().lc!.calls {
			if (call.callLog?.callId != exceptCallid && call.state != .Paused && call.state != .Pausing && call.state != .PausedByRemote) {
				setHeld(call: call, hold: true)
			}
		}
	}

	func setResumeCalls() {
		for call in CansCallManager.instance().lc!.calls {
			if (call.state == .Paused || call.state == .Pausing || call.state == .PausedByRemote) {
				setHeld(call: call, hold: false)
			}
		}
	}

	@objc func performActionWhenCoreIsOn(action:  @escaping ()->Void ) {
		if (globalState == .On) {
			action()
		} else {
			actionsToPerformOnceWhenCoreIsOn.append(action)
		}
	}

	@objc func acceptVideo(call: OpaquePointer, confirm: Bool) {
		let sCall = Call.getSwiftObject(cObject: call)
		let params = try? lc?.createCallParams(call: sCall)
		params?.videoEnabled = confirm
		try? sCall.acceptUpdate(params: params)
	}

    public func onGlobalStateChanged(core: Core, state: GlobalState, message: String) {
		if (state == .On) {
			actionsToPerformOnceWhenCoreIsOn.forEach {
				$0()
			}
			actionsToPerformOnceWhenCoreIsOn.removeAll()
		}
		globalState = state
	}

    public func onRegistrationStateChanged(core: Core, proxyConfig: ProxyConfig, state: RegistrationState, message: String) {
		if core.proxyConfigList.count == 1 && (state == .Failed || state == .Cleared){
			// terminate callkit immediately when registration failed or cleared, supporting single proxy configuration
            guard let uuids = CansCallManager.instance().providerDelegate?.uuids else { return }
            for call in uuids {
                let callId = CansCallManager.instance().providerDelegate?.callInfos[call.value]?.callId
				if (callId != nil) {
					let call = CansCallManager.instance().lc?.getCallByCallid(callId: callId!)
					if (call != nil) {
						// sometimes (for example) due to network, registration failed, in this case, keep the call
						continue
					}
				}

                CansCallManager.instance().providerDelegate?.endCall(uuid: call.value)
			}
			CansCallManager.instance().endCallkit = true
		} else {
			CansCallManager.instance().endCallkit = false
		}
	}
    
    public func onAudioDevicesListUpdated(core: Core) {
        let bluetoothAvailable = isBluetoothAvailable();
        var dict = Dictionary<String, Bool>()
        dict["available"] = bluetoothAvailable
        NotificationCenter.default.post(name: Notification.Name("LinphoneBluetoothAvailabilityUpdate"), object: self, userInfo: dict)
    }

    public func onCallStateChanged(core: Core, call: Call, state cstate: Call.State, message: String) {
        let callLog = call.callLog
        let callId = callLog?.callId
        if (cstate == .PushIncomingReceived) {
            displayIncomingCall(call: call, handle: "Calling", hasVideo: false, callId: callId!, displayName: "Calling")
        } else {
            let video = (core.videoActivationPolicy?.automaticallyAccept ?? false) && (call.remoteParams?.videoEnabled ?? false)

            if (call.userData == nil) {
                let appData = CansCallAppData()
                CansCallManager.setAppData(sCall: call, appData: appData)
            }

            switch cstate {
                case .IncomingReceived:
                    let addr = call.remoteAddress;
//                    let displayName = FastAddressBook.displayName(for: addr?.getCobject) ?? "Unknown"
//                    let displayName = CansBridgingUtils.instance().getDisplayName(for: addr?.getCobject) ?? "Unknow"
                    let displayName = "Unknown"
                    if (CansCallManager.callKitEnabled()) {
                        let uuid = CansCallManager.instance().providerDelegate.uuids["\(callId!)"]
                        if (uuid != nil) {
                            // Tha app is now registered, updated the call already existed.
                            CansCallManager.instance().providerDelegate.updateCall(uuid: uuid!, handle: addr!.asStringUriOnly(), hasVideo: video, displayName: displayName)
                        } else {
                            CansCallManager.instance().displayIncomingCall(call: call, handle: addr!.asStringUriOnly(), hasVideo: video, callId: callId!, displayName: displayName)
                        }
                    }
//                    else if (UIApplication.shared.applicationState != .active) {
//                        // not support callkit , use notif
//                        let content = UNMutableNotificationContent()
//                        content.title = NSLocalizedString("Incoming call", comment: "")
//                        content.body = displayName
//                        content.sound = UNNotificationSound.init(named: UNNotificationSoundName.init("notes_of_the_optimistic.caf"))
//                        content.categoryIdentifier = "call_cat"
//                        content.userInfo = ["CallId" : callId!]
//                        let req = UNNotificationRequest.init(identifier: "call_request", content: content, trigger: nil)
//                            UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
//                    }
                    break
                case .StreamsRunning:
                    if (CansCallManager.callKitEnabled()) {
                        let uuid = CansCallManager.instance().providerDelegate.uuids["\(callId!)"]
                        if (uuid != nil) {
                            let callInfo = CansCallManager.instance().providerDelegate.callInfos[uuid!]
                            if (callInfo != nil && callInfo!.isOutgoing && !callInfo!.connected) {
//                                Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: outgoing call connected with uuid \(uuid!) and callId \(callId!)")
                                CansCallManager.instance().providerDelegate.reportOutgoingCallConnected(uuid: uuid!)
                                callInfo!.connected = true
                                CansCallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
                            }
                        }
                    }

                    if (CansCallManager.instance().speakerBeforePause) {
                        CansCallManager.instance().speakerBeforePause = false
                        CansCallManager.instance().changeRouteToSpeaker()
                    }
                    break
                case .OutgoingInit,
                     .OutgoingProgress,
                     .OutgoingRinging,
                     .OutgoingEarlyMedia:
                    if (CansCallManager.callKitEnabled()) {
                        let uuid = CansCallManager.instance().providerDelegate.uuids[""]
                        if (uuid != nil) {
                            let callInfo = CansCallManager.instance().providerDelegate.callInfos[uuid!]
                            callInfo!.callId = callId!
                            CansCallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
                            CansCallManager.instance().providerDelegate.uuids.removeValue(forKey: "")
                            CansCallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: callId!)

//                            Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: outgoing call started connecting with uuid \(uuid!) and callId \(callId!)")
                            CansCallManager.instance().providerDelegate.reportOutgoingCallStartedConnecting(uuid: uuid!)
                        } else {
                            CansCallManager.instance().referedToCall = callId
                        }
                    }
                    break
                case .End,
                     .Error:
                    var displayName = "Unknown"
//                    if let addr = call.remoteAddress, let contactName = FastAddressBook.displayName(for: addr.getCobject) {
//                        displayName = contactName
//                    }
                    
//                    UIDevice.current.isProximityMonitoringEnabled = false
                    if (CansCallManager.instance().lc!.callsNb == 0) {
                        CansCallManager.instance().changeRouteToDefault()
                        // disable this because I don't find anygood reason for it: _bluetoothAvailable = FALSE;
                        // furthermore it introduces a bug when calling multiple times since route may not be
                        // reconfigured between cause leading to bluetooth being disabled while it should not
                        //CansCallManager.instance().bluetoothEnabled = false
                    }

//                    if UIApplication.shared.applicationState != .active && (callLog == nil || callLog?.status == .Missed || callLog?.status == .Aborted || callLog?.status == .EarlyAborted)  {
//                        // Configure the notification's payload.
//                        let content = UNMutableNotificationContent()
//                        content.title = NSString.localizedUserNotificationString(forKey: NSLocalizedString("Missed call", comment: ""), arguments: nil)
//                        content.body = NSString.localizedUserNotificationString(forKey: displayName, arguments: nil)
//
//                        // Deliver the notification.
//                        let request = UNNotificationRequest(identifier: "call_request", content: content, trigger: nil) // Schedule the notification.
//                        let center = UNUserNotificationCenter.current()
//                        center.add(request) { (error : Error?) in
//                            if error != nil {
////                            Log.directLog(BCTBX_LOG_ERROR, text: "Error while adding notification request : \(error!.localizedDescription)")
//                            }
//                        }
//                    }

                    if (CansCallManager.callKitEnabled()) {
                        var uuid = CansCallManager.instance().providerDelegate.uuids["\(callId!)"]
                        if (callId == CansCallManager.instance().referedToCall) {
                            // refered call ended before connecting
//                            Log.directLog(BCTBX_LOG_MESSAGE, text: "Callkit: end refered to call :  \(String(describing: CansCallManager.instance().referedToCall))")
                            CansCallManager.instance().referedFromCall = nil
                            CansCallManager.instance().referedToCall = nil
                        }
                        if uuid == nil {
                            // the call not yet connected
                            uuid = CansCallManager.instance().providerDelegate.uuids[""]
                        }
                        if (uuid != nil) {
                            if (callId == CansCallManager.instance().referedFromCall) {
//                                Log.directLog(BCTBX_LOG_MESSAGE, text: "Callkit: end refered from call : \(String(describing: CansCallManager.instance().referedFromCall))")
                                CansCallManager.instance().referedFromCall = nil
                                let callInfo = CansCallManager.instance().providerDelegate.callInfos[uuid!]
                                callInfo!.callId = CansCallManager.instance().referedToCall ?? ""
                                CansCallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
                                CansCallManager.instance().providerDelegate.uuids.removeValue(forKey: callId!)
                                CansCallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: callInfo!.callId)
                                CansCallManager.instance().referedToCall = nil
                                break
                            }

                            let transaction = CXTransaction(action:
                            CXEndCallAction(call: uuid!))
                            CansCallManager.instance().requestTransaction(transaction, action: "endCall")
                        }
                    }
                    break
                case .Released:
                    call.userData = nil
                    break
                case .Referred:
                    CansCallManager.instance().referedFromCall = call.callLog?.callId
                    break
                default:
                    break
            }

            let readyForRoutechange = CansCallManager.instance().callkitAudioSessionActivated == nil || (CansCallManager.instance().callkitAudioSessionActivated == true)
            if (readyForRoutechange && (cstate == .IncomingReceived || cstate == .OutgoingInit || cstate == .Connected || cstate == .StreamsRunning)) {
                if ((call.currentParams?.videoEnabled ?? false) && CansCallManager.instance().isReceiverEnabled()) {
                    CansCallManager.instance().changeRouteToSpeaker()
                } else if (isBluetoothAvailable()) {
                    // Use bluetooth device by default if one is available
                    CansCallManager.instance().changeRouteToBluetooth()
                }
            }
        }
        // post Notification kLinphoneCallUpdate
        NotificationCenter.default.post(name: Notification.Name("LinphoneCallUpdate"), object: self, userInfo: [
            AnyHashable("call"): NSValue.init(pointer:UnsafeRawPointer(call.getCobject)),
            AnyHashable("state"): NSNumber(value: cstate.rawValue),
            AnyHashable("message"): message
        ])
	}
    
    @objc func terminate() {
        guard
            let lc = CansCallManager.instance().lc,
            let currentCall = lc.currentCall
        else { return }
        terminateCall(call: currentCall.getCobject)
    }
    
    @objc func getBackgroundContextCall() -> OpaquePointer? {
        return backgroundContextCall?.getCobject
    }
    
    @objc func setBackgroundContextCall(call: OpaquePointer?) {
        if (call == nil) {
            backgroundContextCall = nil
        } else {
            backgroundContextCall = Call.getSwiftObject(cObject: call!)
        }
    }
    
    @objc func changeRouteToSpeaker() {
        lc?.outputAudioDevice = lc?.audioDevices.first { $0.type == AudioDeviceType.Speaker }
//        UIDevice.current.isProximityMonitoringEnabled = false
    }
    
    @objc public func changeRouteToBluetooth() {
        lc?.outputAudioDevice = lc?.audioDevices.first { $0.type == AudioDeviceType.BluetoothA2DP || $0.type == AudioDeviceType.Bluetooth }
//        UIDevice.current.isProximityMonitoringEnabled = (lc!.callsNb > 0)
    }
    
    @objc func changeRouteToDefault() {
        lc?.outputAudioDevice = lc?.defaultOutputAudioDevice
    }
    
    @objc func isBluetoothAvailable() -> Bool {
        for device in lc!.audioDevices {
            if (device.type == AudioDeviceType.Bluetooth || device.type == AudioDeviceType.BluetoothA2DP) {
                return true;
            }
        }
        return false;
    }
    
    @objc func isSpeakerEnabled() -> Bool {
        if let outputDevice = lc!.outputAudioDevice {
            return outputDevice.type == AudioDeviceType.Speaker
        }
        return false
    }
    
    @objc public func isBluetoothEnabled() -> Bool {
        if let outputDevice = lc!.outputAudioDevice {
            return (outputDevice.type == AudioDeviceType.Bluetooth || outputDevice.type == AudioDeviceType.BluetoothA2DP)
        }
        return false
    }
    
    @objc func isReceiverEnabled() -> Bool {
        if let outputDevice = lc!.outputAudioDevice {
            return outputDevice.type == AudioDeviceType.Microphone
        }
        return false
    }

}
