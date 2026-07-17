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
import linphonesw
import UserNotifications
import os
import CallKit
import AVFoundation

@objc class CallAppData: NSObject {
	@objc var batteryWarningShown = false
	@objc var videoRequested = false /*set when user has requested for video*/
}

/*
* CallManager is a class that manages application calls and supports callkit.
* There is only one CallManager by calling CallManager.instance().
*/
@objc class CallManager: NSObject, CoreDelegate {
	static public var theCallManager: CallManager?
    public let providerDelegate: ProviderDelegate! // to support callkit
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
		providerDelegate = ProviderDelegate()
		callController = CXCallController()
	}

	@objc public static func instance() -> CallManager {
		if (theCallManager == nil) {
			theCallManager = CallManager()
		}
		return theCallManager!
	}

	@objc func setCore(core: OpaquePointer) {
		lc = Core.getSwiftObject(cObject: core)
		lc?.addDelegate(delegate: self)
	}

	@objc static func getAppData(call: OpaquePointer) -> CallAppData? {
		let sCall = Call.getSwiftObject(cObject: call)
		return CallManager.getAppData(sCall: sCall)
	}

	static func getAppData(sCall:Call) -> CallAppData? {
		if (sCall.userData == nil) {
			return nil
		}
		return Unmanaged<CallAppData>.fromOpaque(sCall.userData!).takeUnretainedValue()
	}

	@objc static func setAppData(call:OpaquePointer, appData: CallAppData) {
		let sCall = Call.getSwiftObject(cObject: call)
		CallManager.setAppData(sCall: sCall, appData: appData)
	}

	static func setAppData(sCall:Call, appData:CallAppData?) {
		if (sCall.userData != nil) {
			Unmanaged<CallAppData>.fromOpaque(sCall.userData!).release()
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
		#if !targetEnvironment(simulator)
		return true
		#else
		return false
		#endif
	}

	func requestTransaction(_ transaction: CXTransaction, action: String) {
		callController.request(transaction) { error in
			if error != nil {
//				Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: Requested transaction \(action) failed because: \(error!)")
			} else {
//				Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: Requested transaction \(action) successfully")
			}
		}
	}

	@objc func updateCallId(previous: String, current: String) {
        let uuid = CallManager.instance().providerDelegate?.uuids["\(previous)"]
		if (uuid != nil) {
            CallManager.instance().providerDelegate?.uuids.removeValue(forKey: previous)
            CallManager.instance().providerDelegate?.uuids.updateValue(uuid!, forKey: current)
            let callInfo = providerDelegate?.callInfos[uuid!]
			if (callInfo != nil) {
				callInfo!.callId = current
                providerDelegate?.callInfos.updateValue(callInfo!, forKey: uuid!)
			}
		}
	}

	// From ios13, display the callkit view when the notification is received.
    // hasVideo: initial value from push payload (default false); overridden by
    // onCallStateChanged(.IncomingReceived) → updateCall once the INVITE arrives.
    // silenceUI=true satisfies the iOS 13+ PushKit reportNewIncomingCall mandate
    // without letting the CallKit banner render — used when the app is Active and
    // its own RN screen is the only UI.
	@objc func displayIncomingCall(callId: String, hasVideo: Bool = false, silenceUI: Bool = false) {
        let uuid = CallManager.instance().providerDelegate?.uuids["\(callId)"]
		if (uuid != nil) {
            let callInfo = providerDelegate?.callInfos[uuid!]
			if (callInfo?.declined ?? false) {
				// This call was declined.
                providerDelegate?.reportIncomingCall(call:nil, uuid: uuid!, handle: "Calling", hasVideo: false, displayName: callInfo?.displayName ?? "Calling")
                providerDelegate?.endCall(uuid: uuid!)
			}
			return
		}

		let call = CallManager.instance().callByCallId(callId: callId)
		if (call != nil) {
            let addr = call!.remoteAddress
            let displayName = addr?.displayName?.isEmpty == false ? addr!.displayName! : (addr?.username ?? "Unknown")
            // Call is already in Linphone — use actual remote params instead of push hint.
            // videoEnabled is true even when the video m= line has a=inactive, so also
            // check direction: only treat the call as video when direction is not Inactive.
            let rp = call!.remoteParams
            let video = (rp?.videoEnabled ?? false) && (rp?.videoDirection ?? .Inactive) != .Inactive
			displayIncomingCall(call: call, handle: addr?.asStringUriOnly() ?? "Unknown", hasVideo: video, callId: callId, displayName: displayName, silenceUI: silenceUI)
		} else {
            // Call not yet in Linphone (push arrived before INVITE processed).
            // Use hasVideo from push payload; updateCall will correct it on IncomingReceived.
			displayIncomingCall(call: nil, handle: "Calling", hasVideo: hasVideo, callId: callId, displayName: "Calling", silenceUI: silenceUI)
		}
	}

	func displayIncomingCall(call:Call?, handle: String, hasVideo: Bool, callId: String, displayName:String, silenceUI: Bool = false) {
		let uuid = UUID()
		let callInfo = CallInfo.newIncomingCallInfo(callId: callId)
		callInfo.silenceCallKitUI = silenceUI

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
//				let low_bandwidth = (AppManager.network() == .network_2g)
//				if (low_bandwidth) {
//					Log.directLog(BCTBX_LOG_MESSAGE, text: "Low bandwidth mode")
//				}
//				callParams.lowBandwidthEnabled = low_bandwidth
//			}

			//We set the record file name here because we can't do it after the call is started.
			let address = call.callLog?.fromAddress
            let writablePath = AppManager.recordingFilePathFromCall(address: address?.username ?? "")
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
		if (CallManager.callKitEnabled() && !CallManager.instance().nextCallIsTransfer) {
			let uuid = UUID()
//			let name = FastAddressBook.displayName(for: addr) ?? "unknow"
            let name = "unknow"
			let handle = CXHandle(type: .generic, value: sAddr.asStringUriOnly())
			let startCallAction = CXStartCallAction(call: uuid, handle: handle)
			let transaction = CXTransaction(action: startCallAction)

			let callInfo = CallInfo.newOutgoingCallInfo(addr: sAddr, isSas: isSas, displayName: name)
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
        let displayName: String? = nil

		let lcallParams = try CallManager.instance().lc!.createCallParams(call: nil)
		// Force audio-only for outgoing calls regardless of the core's video settings.
		// createCallParams(call: nil) can inherit videoEnabled=true from the core config,
		// so we explicitly disable it here. Video calls go through makeVideoCall (ObjC),
		// which creates call params with video explicitly enabled.
		lcallParams.videoEnabled = false
//		if ConfigManager.instance().lpConfigBoolForKey(key: "edge_opt_preference") && AppManager.network() == .network_2g {
//			Log.directLog(BCTBX_LOG_MESSAGE, text: "Enabling low bandwidth mode")
//			lcallParams.lowBandwidthEnabled = true
//		}

		if (displayName != nil) {
			try addr.setDisplayname(newValue: displayName!)
		}

//		if(ConfigManager.instance().lpConfigBoolForKey(key: "override_domain_with_default_one")) {
//			try addr.setDomain(newValue: ConfigManager.instance().lpConfigStringForKey(key: "domain", section: "assistant"))
//		}

		if (CallManager.instance().nextCallIsTransfer) {
			let call = CallManager.instance().lc!.currentCall
			try call?.transferTo(referTo: addr)
			CallManager.instance().nextCallIsTransfer = false
		} else {
			//We set the record file name here because we can't do it after the call is started.
			let writablePath = AppManager.recordingFilePathFromCall(address: addr.username ?? "")
//			Log.directLog(BCTBX_LOG_DEBUG, text: "record file path: \(writablePath)")
			lcallParams.recordFile = writablePath
			if (isSas) {
				lcallParams.mediaEncryption = .ZRTP
			}
			let call = CallManager.instance().lc!.inviteAddressWithParams(addr: addr, params: lcallParams)
			if (call != nil) {
				// The LinphoneCallAppData object should be set on call creation with callback
				// - (void)onCall:StateChanged:withMessage:. If not, we are in big trouble and expect it to crash
				// We are NOT responsible for creating the AppData.
				let data = CallManager.getAppData(sCall: call!)
				if (data == nil) {
//					Log.directLog(BCTBX_LOG_ERROR, text: "New call instanciated but app data was not set. Expect it to crash.")
					/* will be used later to notify user if video was not activated because of the linphone core*/
				} else {
					data!.videoRequested = lcallParams.videoEnabled
					CallManager.setAppData(sCall: call!, appData: data)
				}
			}
		}
	}

	@objc func groupCall() {
		if (CallManager.callKitEnabled()) {
			let calls = lc?.calls
			if (calls == nil || calls!.isEmpty) {
				return
			}
			let firstCall = calls!.first?.callLog?.callId ?? ""
			let lastCall = (calls!.count > 1) ? calls!.last?.callLog?.callId ?? "" : ""

            let currentUuid = CallManager.instance().providerDelegate?.uuids["\(firstCall)"]
			if (currentUuid == nil) {
//				Log.directLog(BCTBX_LOG_ERROR, text: "Can not find correspondant call to group.")
				return
			}

            let newUuid = CallManager.instance().providerDelegate?.uuids["\(lastCall)"]
			let groupAction = CXSetGroupCallAction(call: currentUuid!, callUUIDToGroupWith: newUuid)
			let transcation = CXTransaction(action: groupAction)
			requestTransaction(transcation, action: "groupCall")

//			setResumeCalls()
		}
		// Conference grouping not supported — addAllToConference deprecated in SDK 5.x
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
		if !CallManager.callKitEnabled() {
			return
		}

        let uuid = providerDelegate?.uuids["\(callId)"]
		if (uuid == nil) {
//			Log.directLog(BCTBX_LOG_MESSAGE, text: "Mark call \(callId) as declined.")
			let uuid = UUID()
            providerDelegate?.uuids.updateValue(uuid, forKey: callId)
			let callInfo = CallInfo.newIncomingCallInfo(callId: callId)
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
		for call in CallManager.instance().lc!.calls {
			if (call.callLog?.callId != exceptCallid && call.state != .Paused && call.state != .Pausing && call.state != .PausedByRemote) {
				setHeld(call: call, hold: true)
			}
		}
	}

	func setResumeCalls() {
		for call in CallManager.instance().lc!.calls {
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
		if core.accountList.count == 1 && (state == .Failed || state == .Cleared){
			// terminate callkit immediately when registration failed or cleared, supporting single proxy configuration
            guard let uuids = CallManager.instance().providerDelegate?.uuids else { return }
            for call in uuids {
                let callId = CallManager.instance().providerDelegate?.callInfos[call.value]?.callId
				if (callId != nil) {
					let call = CallManager.instance().lc?.getCallByCallid(callId: callId!)
					if (call != nil) {
						// sometimes (for example) due to network, registration failed, in this case, keep the call
						continue
					}
				}

                CallManager.instance().providerDelegate?.endCall(uuid: call.value)
			}
			CallManager.instance().endCallkit = true
		} else {
			CallManager.instance().endCallkit = false
		}
	}

    public func onAudioDevicesListUpdated(core: Core) {
        let bluetoothAvailable = isBluetoothAvailable();
        var dict = [String: Bool]()
        dict["available"] = bluetoothAvailable
        NotificationCenter.default.post(name: Notification.Name("LinphoneBluetoothAvailabilityUpdate"), object: self, userInfo: dict)
    }

    public func onCallStateChanged(core: Core, call: Call, state cstate: Call.State, message: String) {
        let callLog = call.callLog
        let callId = callLog?.callId
        if (cstate == .PushIncomingReceived) {
            // Only report to CallKit if PushKit hasn't already registered a UUID for this
            // callId.  Without this guard, PushIncomingReceived creates a duplicate UUID
            // (a second "Calling" banner) alongside the one PushKit already reported.
            if CallManager.callKitEnabled(), let cid = callId {
                if providerDelegate?.uuids[cid] == nil {
                    NSLog("[CallManager] PushIncomingReceived: callId=%@, no UUID yet — reporting to CallKit", cid)
                    displayIncomingCall(call: call, handle: "Calling", hasVideo: false, callId: cid, displayName: "Calling")
                } else {
                    NSLog("[CallManager] PushIncomingReceived: callId=%@, PushKit already registered UUID — skipping duplicate", cid)
                }
            }
        } else {
            // Reflect what the remote party is offering, regardless of local auto-accept policy.
            // The banner should say "Video" only when the caller sends an active video stream.
            // videoEnabled is true even for a=inactive video m= lines, so check direction too.
            let remoteParams = call.remoteParams
            let video = (remoteParams?.videoEnabled ?? false) && (remoteParams?.videoDirection ?? .Inactive) != .Inactive

            if (call.userData == nil) {
                let appData = CallAppData()
                CallManager.setAppData(sCall: call, appData: appData)
            }

            switch cstate {
                case .IncomingReceived:
                    let addr = call.remoteAddress
                    // Use SIP display name if set, otherwise fall back to the username (extension number).
                    let displayName = addr?.displayName?.isEmpty == false ? addr!.displayName! : (addr?.username ?? "Unknown")
                    NSLog("[CallManager] IncomingReceived: callId=%@, videoEnabled=%d, videoDirection=%d, hasVideo=%d, displayName=%@",
                          callId ?? "nil",
                          remoteParams?.videoEnabled ?? false ? 1 : 0,
                          remoteParams?.videoDirection.rawValue ?? -1,
                          video ? 1 : 0,
                          displayName)
                    // Busy-decline: reject second incoming INVITE while a call is active.
                    // max_calls=1 would trigger a SIP-level 486 before IncomingReceived, starving
                    // the "busyDeclined" event JS needs for missed-call history.
                    let otherActiveCalls = core.calls.filter { c in
                        c !== call && c.state != .Released && c.state != .End && c.state != .Error
                    }
                    if !otherActiveCalls.isEmpty {
                        NSLog("[CallManager] Busy-declining incoming call — \(otherActiveCalls.count) active call(s) exist")
                        // Capture identity before decline() — remoteAddress is nil after .End.
                        // CansBusyDeclinedCall lets JS write a missed-call entry to chat history.
                        let callerNumber = call.remoteAddress?.username ?? ""
                        let hasVideo = (call.remoteParams?.videoEnabled ?? false) && (call.remoteParams?.videoDirection ?? .Inactive) != .Inactive
                        try? call.decline(reason: .Busy)
                        if !callerNumber.isEmpty {
                            NotificationCenter.default.post(
                                name: NSNotification.Name("CansBusyDeclinedCall"),
                                object: nil,
                                userInfo: [
                                    "phoneNumber": callerNumber,
                                    "isVideo": hasVideo,
                                    "timestamp": Date().timeIntervalSince1970 * 1000
                                ]
                            )
                        }
                        return
                    }
                    if (CallManager.callKitEnabled()) {
                        let uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
                        if (uuid != nil) {
                            // UUID already registered (push wakeup path). Sync callId in case the
                            // initial push report used "" as a placeholder before Linphone had the call.
                            if let callInfo = providerDelegate.callInfos[uuid!], callInfo.callId.isEmpty {
                                callInfo.callId = callId!
                                providerDelegate.callInfos.updateValue(callInfo, forKey: uuid!)
                                providerDelegate.uuids.removeValue(forKey: "")
                                providerDelegate.uuids.updateValue(uuid!, forKey: callId!)
                            }
                            CallManager.instance().providerDelegate.updateCall(uuid: uuid!, handle: addr!.asStringUriOnly(), hasVideo: video, displayName: displayName)
                        } else {
                            // Only register with CallKit when app is NOT in the active foreground.
                            // When active, NativeModuleiOS emits dataFromCall to RN which shows
                            // IncomingCallScreen instead — showing both simultaneously is wrong UX.
                            if UIApplication.shared.applicationState != .active {
                                CallManager.instance().displayIncomingCall(call: call, handle: addr!.asStringUriOnly(), hasVideo: video, callId: callId!, displayName: displayName)
                            }
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
                    if (CallManager.callKitEnabled()) {
                        let uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
                        if (uuid != nil) {
                            let callInfo = CallManager.instance().providerDelegate.callInfos[uuid!]
                            if (callInfo != nil && callInfo!.isOutgoing && !callInfo!.connected) {
//                                Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: outgoing call connected with uuid \(uuid!) and callId \(callId!)")
                                CallManager.instance().providerDelegate.reportOutgoingCallConnected(uuid: uuid!)
                                callInfo!.connected = true
                                CallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
                            }
                        }
                    }

                    if (CallManager.instance().speakerBeforePause) {
                        CallManager.instance().speakerBeforePause = false
                        CallManager.instance().changeRouteToSpeaker()
                    }
                    break
                case .OutgoingInit,
                     .OutgoingProgress,
                     .OutgoingRinging,
                     .OutgoingEarlyMedia:
                    if (CallManager.callKitEnabled()) {
                        let uuid = CallManager.instance().providerDelegate.uuids[""]
                        if (uuid != nil) {
                            // callId may be nil at OutgoingInit (SIP Call-ID not assigned until
                            // the INVITE is sent at OutgoingProgress). Guard both to retry on
                            // the next state transition instead of crashing.
                            // callId is nil at OutgoingInit (assigned when INVITE is sent); retry on next state.
                            if let callInfo = CallManager.instance().providerDelegate.callInfos[uuid!],
                               let resolvedCallId = callId {
                                callInfo.callId = resolvedCallId
                                CallManager.instance().providerDelegate.callInfos.updateValue(callInfo, forKey: uuid!)
                                CallManager.instance().providerDelegate.uuids.removeValue(forKey: "")
                                CallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: resolvedCallId)
                                CallManager.instance().providerDelegate.reportOutgoingCallStartedConnecting(uuid: uuid!)
                            }
                        } else {
                            CallManager.instance().referedToCall = callId
                        }
                    }
                    break
                case .End,
                     .Error:
//                    if let addr = call.remoteAddress, let contactName = FastAddressBook.displayName(for: addr.getCobject) {

//                    UIDevice.current.isProximityMonitoringEnabled = false
                    if (CallManager.instance().lc!.callsNb == 0) {
                        CallManager.instance().changeRouteToDefault()
                        // disable this because I don't find anygood reason for it: _bluetoothAvailable = FALSE;
                        // furthermore it introduces a bug when calling multiple times since route may not be
                        // reconfigured between cause leading to bluetooth being disabled while it should not
                        //CallManager.instance().bluetoothEnabled = false
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

                    if (CallManager.callKitEnabled()) {
                        var uuid = CallManager.instance().providerDelegate.uuids["\(callId!)"]
                        if (callId == CallManager.instance().referedToCall) {
                            // refered call ended before connecting
//                            Log.directLog(BCTBX_LOG_MESSAGE, text: "Callkit: end refered to call :  \(String(describing: CallManager.instance().referedToCall))")
                            CallManager.instance().referedFromCall = nil
                            CallManager.instance().referedToCall = nil
                        }
                        if uuid == nil {
                            // the call not yet connected
                            uuid = CallManager.instance().providerDelegate.uuids[""]
                        }
                        if (uuid != nil) {
                            if (callId == CallManager.instance().referedFromCall) {
//                                Log.directLog(BCTBX_LOG_MESSAGE, text: "Callkit: end refered from call : \(String(describing: CallManager.instance().referedFromCall))")
                                CallManager.instance().referedFromCall = nil
                                let callInfo = CallManager.instance().providerDelegate.callInfos[uuid!]
                                callInfo!.callId = CallManager.instance().referedToCall ?? ""
                                CallManager.instance().providerDelegate.callInfos.updateValue(callInfo!, forKey: uuid!)
                                CallManager.instance().providerDelegate.uuids.removeValue(forKey: callId!)
                                CallManager.instance().providerDelegate.uuids.updateValue(uuid!, forKey: callInfo!.callId)
                                CallManager.instance().referedToCall = nil
                                break
                            }

                            // Map Linphone end reason to CXCallEndedReason so CallKit shows the
                            // correct label in Recent Calls instead of always "Call Failed".
                            // Using reportCall(with:endedAt:reason:) directly so the reason is
                            // communicated; no CXEndCallAction cycle needed when Linphone itself
                            // has already ended the call.
                            let ckReason: CXCallEndedReason
                            if cstate == .Error {
                                ckReason = .failed
                            } else {
                                switch call.reason {
                                case .Busy, .NotAnswered:
                                    ckReason = .unanswered
                                default: // .None, .Normal, .Declined, etc.
                                    ckReason = .remoteEnded
                                }
                            }
                            NSLog("[CallManager] Call end: callId=%@, linphoneReason=%@, ckReason=%@",
                                  callId!, "\(call.reason)", ckReason == .remoteEnded ? "remoteEnded" : ckReason == .failed ? "failed" : "unanswered")
                            CallManager.instance().providerDelegate.endCall(uuid: uuid!, reason: ckReason)
                        }
                    }
                    break
                case .Released:
                    call.userData = nil
                    break
                case .Referred:
                    CallManager.instance().referedFromCall = call.callLog?.callId
                    break
                default:
                    break
            }

                // Audio route: only update while a call is connecting or active.
                // Skip terminal/transfer states and when CallKit deferred audio session
                // activation (callkitAudioSessionActivated == false) — didActivate handles
                // route setup once the session is live.
                let isTerminalState = cstate == .End || cstate == .Error || cstate == .Released || cstate == .Referred
                if !isTerminalState && CallManager.instance().callkitAudioSessionActivated != false {
                    // `currentParams` is nil/false until .Connected; also check `params` (offered)
                    // so outgoing video is detected at .OutgoingInit on the first route pass.
                    let isVideoCall = (call.currentParams?.videoEnabled ?? false) || (call.params?.videoEnabled ?? false)
                    if isVideoCall {
                        // Linphone device state and OS AVAudioSession route can diverge.
                        // Bluetooth takes precedence; otherwise force speaker for video.
                        if isBluetoothAvailable() {
                            CallManager.instance().changeRouteToBluetooth()
                        } else {
                            CallManager.instance().changeRouteToSpeaker()
                        }
                    } else if (isBluetoothAvailable()) {
                        // Audio call: use bluetooth device by default if one is available
                        CallManager.instance().changeRouteToBluetooth()
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
            let lc = CallManager.instance().lc,
            let currentCall = lc.currentCall
        else { return }
        try? currentCall.terminate()
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
        applySpeakerRoute()
        // Linphone's StreamsRunning → configureAudioSession resets overrideOutputAudioPort
        // before the pipeline settles. Re-apply at 300ms to survive that window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.applySpeakerRoute()
        }
    }

    private func applySpeakerRoute() {
        guard let lc = lc else { return }
        let speaker = lc.audioDevices.first(where: { $0.type == .Speaker })
        if let speaker = speaker {
            if let call = lc.currentCall {
                call.outputAudioDevice = speaker
            } else {
                lc.outputAudioDevice = speaker
            }
        }
        // Linphone's outputAudioDevice alone doesn't change the OS route — `.voiceChat`
        // keeps the earpiece. AVAudioSession override is authoritative; always apply.
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
        } catch {
            NSLog("[CallManager] applySpeakerRoute: overrideOutputAudioPort failed: %@", "\(error)")
        }
    }

    @objc public func changeRouteToBluetooth() {
        guard let lc = lc else { return }
        let bt = lc.audioDevices.first(where: { $0.type == .Bluetooth || $0.type == .BluetoothA2DP })
        guard let bt = bt else {
            return
        }
        if let call = lc.currentCall {
            call.outputAudioDevice = bt
        } else {
            lc.outputAudioDevice = bt
        }
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }

    @objc func changeRouteToDefault() {
        lc?.outputAudioDevice = lc?.defaultOutputAudioDevice
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }

    @objc func isBluetoothAvailable() -> Bool {
        guard let lc = lc else { return false }
        for device in lc.audioDevices {
            if device.type == .Bluetooth || device.type == .BluetoothA2DP {
                return true
            }
        }
        return false
    }

    @objc func isSpeakerEnabled() -> Bool {
        guard let lc = lc else { return false }
        if let call = lc.currentCall, let out = call.outputAudioDevice {
            return out.type == .Speaker
        }
        if let out = lc.outputAudioDevice {
            return out.type == .Speaker
        }
        return false
    }

    @objc public func isBluetoothEnabled() -> Bool {
        guard let lc = lc else { return false }
        if let call = lc.currentCall, let out = call.outputAudioDevice {
            return out.type == .Bluetooth || out.type == .BluetoothA2DP
        }
        if let out = lc.outputAudioDevice {
            return out.type == .Bluetooth || out.type == .BluetoothA2DP
        }
        return false
    }

    /// True when the *current* output route is the earpiece/receiver. Used by the video-call
    /// auto-route branch in onCallStateChanged — video calls should never default to the receiver.
    @objc func isReceiverEnabled() -> Bool {
        guard let lc = lc else { return true }
        if let call = lc.currentCall, let out = call.outputAudioDevice {
            // Linphone reports the receiver route under either .Earpiece or .Microphone (the "default" iPhone card).
            return out.type == .Earpiece || out.type == .Microphone
        }
        if let out = lc.outputAudioDevice {
            return out.type == .Earpiece || out.type == .Microphone
        }
        // Nothing set yet — treat as receiver so the video branch upgrades it to Speaker.
        return true
    }

}
