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


@objc class CoreManager: NSObject {
	static var theCansCoreManager: CoreManager?
	var lc: Core?
	private var mIterateTimer: Timer?

	@objc static func instance() -> CoreManager {
		if (theCansCoreManager == nil) {
			theCansCoreManager = CoreManager()
		}
		return theCansCoreManager!
	}

	@objc func setCore(core: OpaquePointer) {
		lc = Core.getSwiftObject(cObject: core)
	}

	@objc private func iterate() {
		lc?.iterate()
	}

	@objc func startIterateTimer() {
		if (mIterateTimer?.isValid ?? false) {
//			Log.directLog(BCTBX_LOG_DEBUG, text: "Iterate timer is already started, skipping ...")
			return
		}
		mIterateTimer = Timer.scheduledTimer(timeInterval: 0.02, target: self, selector: #selector(self.iterate), userInfo: nil, repeats: true)
//		Log.directLog(BCTBX_LOG_DEBUG, text: "start iterate timer")

	}

	@objc func stopIterateTimer() {
		if let timer = mIterateTimer {
//			Log.directLog(BCTBX_LOG_DEBUG, text: "stop iterate timer")
			timer.invalidate()
		}
	}
	
	@objc func stopLinphoneCore() {
		if (lc?.callsNb == 0) {
			//stop iterate when core is off
			lc?.stopAsync()
		}
	}
    
    @objc func resetMissedCallsCount() {
        lc?.resetMissedCallsCount()
    }
    
    @objc var audioAdaptiveJittcompEnabled: Bool {
        return lc?.audioAdaptiveJittcompEnabled ?? false
    }
    
    @objc func setAudioAdaptiveJittcompEnabled(value: Bool) {
        lc?.audioAdaptiveJittcompEnabled = value
    }
    
    @objc var audioJittcomp: Int {
        return lc?.audioJittcomp ?? 0
    }
    
    @objc func setAudioJittcomp(value: Int) {
        lc?.audioJittcomp = value
    }
    
    /// - Returns: The current number of calls
    @objc var callsNb: Int {
        return lc?.callsNb ?? 0
    }
    
    var currentCall: Call? {
        return lc?.currentCall
    }
    
    @objc var isCurrentCall: Bool {
        return currentCall != nil ? true : false
    }
    
    /// - Returns: the call's duration in seconds.
    @objc var duration: Int {
        return currentCall?.duration ?? 0
    }
    
    @objc var videoCaptureEnabled: Bool {
        return lc?.videoCaptureEnabled ?? false
    }
    
    @objc var durationTheMost: Int {
        var duration: Int = 0
        guard let calls = lc?.calls else { return 0 }
        calls.forEach {
            if duration < $0.duration {
                duration = $0.duration
            }
        }
        return duration
    }
    
    @objc var isInConference: Bool {
        return lc?.conference?.isIn ?? false
    }
    
    @objc var isHoldingAll: Bool {
        return currentCall == nil && !isInConference
    }
    
    @objc func refreshRegisters() {
        lc?.refreshRegisters()
    }
    
    var defaultProxyConfig: ProxyConfig? {
        get {
            return lc?.defaultProxyConfig
        }
        set {
            lc?.defaultProxyConfig = newValue
        }
    }
    
    var defaultAccount: Account? {
        get {
            return lc?.defaultAccount
        }
        set {
            lc?.defaultAccount = newValue
        }
    }
    
    @objc var domain: String {
        return defaultAccount?.params?.domain ?? ""
    }
    
    @objc var username: String {
        return defaultAccount?.contactAddress?.username ?? ""
    }
    
    @objc var password: String {
        return defaultAccount?.contactAddress?.password ?? ""
    }
    
    var proxyConfigList: [ProxyConfig] {
        return lc?.proxyConfigList ?? []
    }
    
    @objc var isDefaultProxyConfig: Bool {
        return defaultProxyConfig != nil ? true : false
    }
    
    @objc var isProxyConfigList: Bool {
        let proxyConfigList = lc?.proxyConfigList ?? []
        return proxyConfigList.count > 0
    }
    
    @objc var missedCallsCount: Int {
        return lc?.missedCallsCount ?? 0
    }

    @objc var micEnabled: Bool {
        get {
            return lc?.micEnabled ?? false
        }
        set {
            lc?.micEnabled = newValue
        }
    }
    
    @objc func enableMic() {
        micEnabled = true
    }
    
    @objc func disableMic() {
        micEnabled = false
    }
    
    func createAccountParams() -> AccountParams? {
        do {
            return try lc?.createAccountParams()
        } catch {
            print(error)
            return nil
        }
    }
    
    func createAccount(params: AccountParams) -> Account? {
        do {
            return try lc?.createAccount(params: params)
        } catch {
            print(error)
            return nil
        }
    }
    
    func addAccount(account: Account) -> Bool {
        do {
            try lc?.addAccount(account: account)
            return true
        } catch {
            print(error)
            return false
        }
    }
    
}
