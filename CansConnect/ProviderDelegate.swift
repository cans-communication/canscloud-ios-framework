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
import CallKit
import UIKit
import linphonesw
import AVFoundation
import os

@objc class CallInfo: NSObject {
	var callId: String = ""
	var accepted = false
	var toAddr: Address?
	var isOutgoing = false
	var sasEnabled = false
	var declined = false
	var connected = false
	var reason: Reason = Reason.None
	var displayName: String?
	// Set when the app is in the foreground and is drawing its own incoming-call UI
	// (RN IncomingCallScreen). We still must call reportNewIncomingCall to satisfy the
	// iOS 13+ PushKit mandate, but end the call inside the completion handler so the
	// banner never renders. Reset per-call (fresh CallInfo per incoming push).
	var silenceCallKitUI = false

	static func newIncomingCallInfo(callId: String) -> CallInfo {
		let callInfo = CallInfo()
		callInfo.callId = callId
		return callInfo
	}
	
	static func newOutgoingCallInfo(addr: Address, isSas: Bool, displayName: String) -> CallInfo {
		let callInfo = CallInfo()
		callInfo.isOutgoing = true
		callInfo.sasEnabled = isSas
		callInfo.toAddr = addr
		callInfo.displayName = displayName
		return callInfo
	}
}

/*
* A delegate to support callkit.
*/
class ProviderDelegate: NSObject {
    private var provider: CXProvider?
	var uuids: [String : UUID] = [:]
	var callInfos: [UUID : CallInfo] = [:]

	override init() {
        provider = CXProvider(configuration: ProviderDelegate.providerConfiguration)
//        provider = nil
		super.init()
        provider?.setDelegate(self, queue: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
	}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // When the user answers a video call from the lock screen (or any non-active
    // state), `provider(_:perform:CXAnswerCallAction)` disables the local camera
    // capture pipeline (iOS restricts camera access from background). Restore it
    // once the app foregrounds — otherwise the SDP negotiates video sendrecv but
    // iOS never pushes frames, so the remote peer sees a black stream.
    @objc private func handleApplicationDidBecomeActive() {
        guard let call = CallManager.instance().backgroundContextCall else { return }
        if CallManager.instance().backgroundContextCameraIsEnabled {
            call.cameraEnabled = true
        }
        CallManager.instance().backgroundContextCall = nil
        CallManager.instance().backgroundContextCameraIsEnabled = false
    }

	static var providerConfiguration: CXProviderConfiguration = {
		let providerConfiguration = CXProviderConfiguration()
		// nil → iOS uses the user's system ringtone (the safe default).
		// A filename that doesn't exist in the main bundle causes complete silence
		// with no vibration and no fallback — do NOT set a custom name until the
		// .caf file is confirmed present in Copy Bundle Resources.
		providerConfiguration.ringtoneSound = nil
		providerConfiguration.supportsVideo = true
//        providerConfiguration.iconTemplateImageData = ImageAsset.load(asset: .callkitLogo).pngData()
		providerConfiguration.supportedHandleTypes = [.generic, .phoneNumber, .emailAddress]

		providerConfiguration.maximumCallsPerCallGroup = 10
		providerConfiguration.maximumCallGroups = 10

		//not show app's calls in tel's history
//        if #available(iOS 11.0, *) {
//            providerConfiguration.includesCallsInRecents = true
//        } else {
//            // Fallback on earlier versions
//        }
		
		return providerConfiguration
	}()

	func reportIncomingCall(call:Call?, uuid: UUID, handle: String, hasVideo: Bool, displayName:String) {
		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type:.generic, value: handle)
		update.hasVideo = hasVideo
		update.localizedCallerName = displayName

		let callInfo = callInfos[uuid]

        provider?.reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
            if error == nil {
                // Foreground path: silence the CallKit banner ONLY AFTER it has finished
                // rendering. On iOS 16/17 the banner appears ~150–400ms after completion
                // fires; if we call endCall immediately from the completion, CallKit
                // accepts the "ended" state into its model BEFORE the banner presents,
                // then the banner presents and stays stuck for the full 45s ringing timeout
                // (the observed bug). A 600ms delay pushes endCall past the render window.
                //
                // Multiple sequential ends are scheduled (600ms, 1000ms) as belt-and-
                // suspenders: if the first misses the render window, the second catches it.
                if callInfo?.silenceCallKitUI ?? false {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        CallManager.instance().providerDelegate?.endCall(uuid: uuid, reason: .remoteEnded)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        CallManager.instance().providerDelegate?.endCall(uuid: uuid, reason: .remoteEnded)
                    }
                    return
                }
                if CallManager.instance().endCallkit {
                    CallManager.instance().providerDelegate?.endCall(uuid: uuid)
                } else {
                    CallManager.instance().providerDelegate?.endCallNotExist(uuid: uuid, timeout: .now() + 10)
                }
            } else {
                let code = (error as NSError?)?.code
                switch code {
                case CXErrorCodeIncomingCallError.filteredByDoNotDisturb.rawValue:
                    callInfo?.reason = Reason.DoNotDisturb
                case CXErrorCodeIncomingCallError.filteredByBlockList.rawValue:
                    callInfo?.reason = Reason.DoNotDisturb
                default:
                    callInfo?.reason = Reason.Unknown
                }
                guard let callInfo = callInfo else { return }
                callInfo.declined = true
                self?.callInfos.updateValue(callInfo, forKey: uuid)
                try? call?.decline(reason: callInfo.reason)
            }
        }
	}

	func updateCall(uuid: UUID, handle: String, hasVideo: Bool = false, displayName:String) {
		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type:.generic, value:handle)
		update.localizedCallerName = displayName
		update.hasVideo = hasVideo
        provider?.reportCall(with:uuid, updated:update);
	}

	func reportOutgoingCallStartedConnecting(uuid:UUID) {
        provider?.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
	}

	func reportOutgoingCallConnected(uuid:UUID) {
        provider?.reportOutgoingCall(with: uuid, connectedAt: nil)
	}
	
	func endCall(uuid: UUID, reason: CXCallEndedReason = .failed) {
        provider?.reportCall(with: uuid, endedAt: .init(), reason: reason)
		let callId = callInfos[uuid]?.callId
		if (callId != nil) {
			uuids.removeValue(forKey: callId!)
		}
		callInfos.removeValue(forKey: uuid)
	}

	func endCallNotExist(uuid: UUID, timeout: DispatchTime) {
		DispatchQueue.main.asyncAfter(deadline: timeout) {
            let callId = CallManager.instance().providerDelegate?.callInfos[uuid]?.callId
			if (callId == nil) {
				// callkit already ended
				return
			}
			let call = CallManager.instance().callByCallId(callId: callId)
			if (call == nil) {
                CallManager.instance().providerDelegate?.endCall(uuid: uuid, reason: .unanswered)
			}
		}
	}
}

// MARK: - CXProviderDelegate
extension ProviderDelegate: CXProviderDelegate {
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
		let uuid = action.callUUID
		let callId = callInfos[uuid]?.callId

		// remove call infos first, otherwise CXEndCallAction will be called more than onece
		if (callId != nil) {
			uuids.removeValue(forKey: callId!)
		}
		callInfos.removeValue(forKey: uuid)

		let call = CallManager.instance().callByCallId(callId: callId)
		if let call = call {
			CallManager.instance().terminateCall(call: call.getCobject);
//			Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: Call ended with call-id: \(String(describing: callId)) an UUID: \(uuid.description).")
		}
		action.fulfill()
	}

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuid = action.callUUID
        let callInfo = callInfos[uuid]
        let callId = callInfo?.callId

        // Primary lookup: match by callId stored in callInfo.
        // Fallback: if callId is empty or stale (push wakeup before INVITE arrived),
        // find the first incoming call directly from the core.
        var call = CallManager.instance().callByCallId(callId: callId)
        if call == nil {
            call = CallManager.instance().lc?.calls.first(where: {
                $0.state == .IncomingReceived || $0.state == .IncomingEarlyMedia
            })
            // Sync the stored callId so End/other actions can find the call later.
            if let resolvedCall = call, let realCallId = resolvedCall.callLog?.callId {
                callInfo?.callId = realCallId
                if let info = callInfo {
                    callInfos.updateValue(info, forKey: uuid)
                    uuids.removeValue(forKey: callId ?? "")
                    uuids.updateValue(uuid, forKey: realCallId)
                }
            }
        }

        guard let call = call else {
            action.fail()
            return
        }

        // Stop the foreground ringtone before reconfiguring the audio session.
        // This fires when the user answers via either the native CallKit banner or
        // the RN IncomingCallScreen (NativeModuleiOS.answer also posts this, but
        // posting twice is idempotent — stopForegroundRingtone is a no-op if not ringing).
        NotificationCenter.default.post(name: NSNotification.Name("CansCallAnsweredByUser"), object: nil)

        if UIApplication.shared.applicationState != .active {
            CallManager.instance().backgroundContextCall = call
            CallManager.instance().backgroundContextCameraIsEnabled = call.params?.videoEnabled ?? false
            call.cameraEnabled = false // Disable camera while app is not on foreground
        }
        CallManager.instance().callkitAudioSessionActivated = false
        CallManager.instance().lc?.configureAudioSession()
        CallManager.instance().acceptCall(call: call, hasVideo: call.params?.videoEnabled ?? false)
        action.fulfill()
	}

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
		let uuid = action.callUUID
		let callId = callInfos[uuid]?.callId
		let call = CallManager.instance().callByCallId(callId: callId)
		action.fulfill()
		if (call == nil) {
			return
		}

		do {
			if (action.isOnHold) {
				if (call!.params?.localConferenceMode ?? false) {
					return
				}
                CallManager.instance().speakerBeforePause = CallManager.instance().isSpeakerEnabled()
				try call!.pause()
			} else {
				// Conference enter (enterConference) removed in Linphone SDK 5.x — resume call directly
				try call!.resume()
			}
		} catch {
//			Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: Call set held (paused or resumed) \(uuid) failed because \(error)")
		}
	}

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
		let uuid = action.callUUID
		let callInfo = callInfos[uuid]
		let update = CXCallUpdate()
		update.remoteHandle = action.handle
		update.localizedCallerName = callInfo?.displayName
		self.provider?.reportCall(with: uuid, updated: update)

		guard let addr = callInfo?.toAddr else {
//			Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: can not call a null address!")
			action.fail()
			return
		}

		CallManager.instance().lc?.configureAudioSession()
		do {
			try CallManager.instance().doCall(addr: addr, isSas: callInfo?.sasEnabled ?? false)
			action.fulfill()
		} catch {
//			Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: Call started failed because \(error)")
			action.fail()
		}
	}

    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
//		Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: Call grouped callUUid : \(action.callUUID) with callUUID: \(String(describing: action.callUUIDToGroupWith)).")
		// addAllToConference removed in Linphone SDK 5.x — conference grouping not supported
		action.fulfill()
	}

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
		CallManager.instance().lc?.micEnabled = !action.isMuted
		action.fulfill()
	}

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
		let uuid = action.callUUID
		let callId = callInfos[uuid]?.callId
//		Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: Call send dtmf with call-id: \(String(describing: callId)) an UUID: \(uuid.description).")
		let call = CallManager.instance().callByCallId(callId: callId)
		if (call != nil) {
			let digit = (action.digits.cString(using: String.Encoding.utf8)?[0])!
			do {
				try call!.sendDtmf(dtmf: digit)
			} catch {
//				Log.directLog(BCTBX_LOG_ERROR, text: "CallKit: Call send dtmf \(uuid) failed because \(error)")
			}
		}
		action.fulfill()
	}

    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
		action.fulfill()
	}

    public func providerDidReset(_ provider: CXProvider) {
//		Log.directLog(BCTBX_LOG_MESSAGE, text: "CallKit: did reset.")
	}

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        CallManager.instance().lc?.activateAudioSession(activated: true)
        CallManager.instance().callkitAudioSessionActivated = true

        // Video calls must default to the loudspeaker. AVAudioSession `.voiceChat` mode
        // routes to the earpiece by default; without an explicit override, the user has
        // to press the CallKit "speaker" button after every video call answer. This override
        // runs at the exact moment iOS hands the audio session to us, which is the only
        // moment Linphone's `.voiceChat` default won't immediately overwrite our choice.
        if let lc = CallManager.instance().lc,
           let call = lc.currentCall,
           call.currentParams?.videoEnabled ?? false || call.params?.videoEnabled ?? false {
            CallManager.instance().changeRouteToSpeaker()
        }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Guard: didDeactivate can be triggered for unrelated reasons (e.g. another audio
        // client briefly claiming the session). If any Linphone call is still active, skip
        // deactivation — the audio pipeline must stay live until the call ends.
        let activeCalls = CallManager.instance().lc?.callsNb ?? 0
        if activeCalls > 0 {
            CallManager.instance().callkitAudioSessionActivated = nil
            return
        }
        CallManager.instance().lc?.activateAudioSession(activated: false)
        CallManager.instance().callkitAudioSessionActivated = nil
    }
}

