//
//  CansCallKitPolicy.swift
//  CansConnect
//
//  Decides whether CallKit may be used at all, for this install, on this device.
//
//  Background: the Chinese Ministry of Industry and Information Technology (MIIT)
//  requires CallKit to be deactivated in every app distributed on the China App
//  Store. Apple enforces this in review (Guideline 5 - Legal) for any app that
//  lists China as an available territory. VoIP itself stays allowed — only
//  CallKit's system call UI has to go.
//
//  When `isDisabled` is true the SDK must behave as if CallKit did not exist:
//    * no CXProvider is created            (ProviderDelegate.init)
//    * no CXStartCallAction is requested   (CallManager.startCall)
//    * no reportNewIncomingCall is made    (CansBase.reportIncomingVoIPCall*)
//    * linphone's "app"/"use_callkit" is 0 (LinphoneManager.createLinphoneCore)
//
//  The host app is then responsible for its own incoming-call presentation
//  (in-app ringing screen + a local notification when backgrounded), and must
//  NOT register for PushKit — iOS requires every PushKit VoIP push to be
//  answered with reportNewIncomingCall, which is exactly what we can no longer do.
//

import CoreTelephony
import Foundation
import StoreKit

@objc(CansCallKitPolicy)
public final class CansCallKitPolicy: NSObject {

    /// ISO 3166-1 alpha-3, the form `SKStorefront.countryCode` uses.
    private static let chinaStorefront = "CHN"
    /// ISO 3166-1 alpha-2, the form `Locale` uses.
    private static let chinaRegion = "CN"
    /// Mobile Country Code shared by China Mobile / Unicom / Telecom.
    private static let chinaMCC = "460"

    /// Set by the host app (or by QA) to force the answer either way.
    /// Absent means "decide from the device".
    private static let overrideDefaultsKey = "cans_callkit_disabled_override"

    private static let lock = NSLock()
    private static var cachedDecision: Bool?
    private static var cachedReason: String = "not-evaluated"

    // MARK: - Public API

    /// True when CallKit must not be used. Evaluated once per process and cached —
    /// the storefront and SIM region do not change while the app is running, and a
    /// stable answer matters more than a fresh one: flipping mid-session would
    /// leave half the call stack on each side of the gate.
    @objc public static var isDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedDecision { return cached }
        let (decision, why) = evaluate()
        cachedDecision = decision
        cachedReason = why
        NSLog("[CansCallKitPolicy] CallKit %@ (%@)", decision ? "DISABLED" : "enabled", why)
        return decision
    }

    /// Why `isDisabled` returned what it did. For logging / support diagnostics.
    @objc public static var reason: String {
        _ = isDisabled
        lock.lock()
        defer { lock.unlock() }
        return cachedReason
    }

    /// Force the answer, overriding device detection. Persisted, so it also
    /// survives the next launch. Pass `nil` to go back to automatic detection.
    /// Must be called before the Linphone core is created to take full effect.
    @objc(setOverride:)
    public static func setOverride(_ disabled: NSNumber?) {
        let defaults = UserDefaults.standard
        if let disabled = disabled {
            defaults.set(disabled.boolValue, forKey: overrideDefaultsKey)
        } else {
            defaults.removeObject(forKey: overrideDefaultsKey)
        }
        lock.lock()
        cachedDecision = nil
        cachedReason = "not-evaluated"
        lock.unlock()
    }

    // MARK: - Detection

    private static func evaluate() -> (Bool, String) {
        // 1. Explicit override always wins.
        if let override = UserDefaults.standard.object(forKey: overrideDefaultsKey) as? Bool {
            return (override, "override=\(override)")
        }

        // 2. App Store storefront — the signal that actually matches Apple's rule,
        //    which is about the store the app was downloaded from, not where the
        //    device happens to be right now. Can be nil very early in launch.
        if let storefront = SKPaymentQueue.default().storefront?.countryCode.uppercased() {
            if storefront == chinaStorefront {
                return (true, "storefront=\(storefront)")
            }
            // A known non-China storefront is authoritative: a Chinese SIM roaming
            // on a US-storefront install is not subject to the MIIT rule.
            return (false, "storefront=\(storefront)")
        }

        // 3. Storefront unavailable — fall back to device signals, erring towards
        //    disabling. A false positive costs a nicer call UI; a false negative
        //    costs an App Store rejection.
        if let mcc = currentMobileCountryCode() {
            return (true, "mcc=\(mcc)")
        }
        if let region = currentRegionCode(), region == chinaRegion {
            return (true, "region=\(region)")
        }
        return (false, "no-china-signal")
    }

    /// Best-effort MCC, returned only when it is China's. CoreTelephony's carrier
    /// APIs are deprecated and hand back a placeholder ("65535") from iOS 16 on,
    /// so this is only ever used as a positive signal — never to prove the device
    /// is *outside* China.
    private static func currentMobileCountryCode() -> String? {
        let info = CTTelephonyNetworkInfo()
        guard let carriers = info.serviceSubscriberCellularProviders else { return nil }
        for (_, carrier) in carriers {
            if let mcc = carrier.mobileCountryCode, mcc == chinaMCC {
                return mcc
            }
        }
        return nil
    }

    private static func currentRegionCode() -> String? {
        if #available(iOS 16.0, *) {
            return Locale.current.region?.identifier.uppercased()
        }
        return Locale.current.regionCode?.uppercased()
    }
}
