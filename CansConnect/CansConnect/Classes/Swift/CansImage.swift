//
//  CansImage.swift
//  cansconnect
//
//  Created by Siraphop Chaisirikul on 26/11/2564 BE.
//

import UIKit

enum RawImageAsset: String, CaseIterable {
//    case launchScreenBackground = "LaunchScreenBackground"
//    case allowNotification = "AllowNotification"
//    case allowContacts = "AllowContacts"
//    case cansCloudLogo = "CANSCloudLogo"
//    case call = "Call"
//    case message = "Message"
//    case video = "Video"
//    case voiceMail = "VoiceMail"
//    case arrowGrayBack = "ArrowGrayBack"
//    case arrowLightGrayBack = "ArrowLightGrayBack"
//    case play = "Play"
//    case pause = "Pause"
//    case transferDefault = "ongoing_transfer_default"
//    case transferDisabled = "ongoing_transfer_disabled"
//    case ongoingAddDefault = "ongoing_add_default"
//    case ongoingAddDisabled = "ongoing_add_disabled"
//    case keypadCallDefault = "keypad_call_default"
//    case keypadCallDisabled = "keypad_call_disabled"
    case callkitLogo = "callkit_logo"
//    case avatar = "avatar"
//    case audioRouteDefault = "ongoing_audio_route_default"
//    case audioRouteOver = "ongoing_audio_route_over"
//    case routeSpeakerDefault = "ongoing_route_speaker_default"
//    case routeSpeakerOver = "ongoing_route_speaker_over"
//    case routeEarpieceDefault = "ongoing_route_earpiece_default"
//    case routeEarpieceOver = "ongoing_route_earpiece_over"
//    case routeBluetoothDefault = "ongoing_route_bluetooth_default"
//    case routeBluetoothOver = "ongoing_route_bluetooth_over"
//    case routeCancel = "ongoing_route_cancel"
//    case callStatusIncoming = "call_status_incoming"
//    case callStatusMissed = "call_status_missed"
//    case callStatusOutgoing = "call_status_outgoing"
    
    func load() -> UIImage? {
        return UIImage(named: self.rawValue)
    }
}

// MARK: - For Swift

struct ImageAsset {
    static func load(asset: RawImageAsset) -> UIImage {
        return asset.load() ?? UIImage()
    }
}

// MARK: - For Obj-C

//@objc class CansImage: UIImage {
//    @objc static let shared = CansImage()
//    
//    @objc var launchScreenBackground: UIImage {
//        return ImageAsset.load(asset: .launchScreenBackground)
//    }
//    @objc var transferDefault: UIImage {
//        return ImageAsset.load(asset: .transferDefault)
//    }
//    @objc var avatar: UIImage {
//        return ImageAsset.load(asset: .avatar)
//    }
//    @objc var transferDisabled: UIImage {
//        return ImageAsset.load(asset: .transferDisabled)
//    }
//    @objc var ongoingAddDefault: UIImage {
//        return ImageAsset.load(asset: .ongoingAddDefault)
//    }
//    @objc var ongoingAddDisabled: UIImage {
//        return ImageAsset.load(asset: .ongoingAddDisabled)
//    }
//    @objc var keypadCallDefault: UIImage {
//        return ImageAsset.load(asset: .keypadCallDefault)
//    }
//    @objc var keypadCallDisabled: UIImage {
//        return ImageAsset.load(asset: .keypadCallDisabled)
//    }
//    @objc var routeSpeakerDefault: UIImage {
//        return ImageAsset.load(asset: .routeSpeakerDefault)
//    }
//    @objc var routeSpeakerOver: UIImage {
//        return ImageAsset.load(asset: .routeSpeakerOver)
//    }
//    @objc var routeEarpieceDefault: UIImage {
//        return ImageAsset.load(asset: .routeEarpieceDefault)
//    }
//    @objc var routeEarpieceOver: UIImage {
//        return ImageAsset.load(asset: .routeEarpieceOver)
//    }
//    @objc var routeBluetoothDefault: UIImage {
//        return ImageAsset.load(asset: .routeBluetoothDefault)
//    }
//    @objc var routeBluetoothOver: UIImage {
//        return ImageAsset.load(asset: .routeBluetoothOver)
//    }
//    @objc var routeCancel: UIImage {
//        return ImageAsset.load(asset: .routeCancel)
//    }
//    @objc var callStatusIncoming: UIImage {
//        return ImageAsset.load(asset: .callStatusIncoming)
//    }
//    @objc var callStatusMissed: UIImage {
//        return ImageAsset.load(asset: .callStatusMissed)
//    }
//    @objc var callStatusOutgoing: UIImage {
//        return ImageAsset.load(asset: .callStatusOutgoing)
//    }
//}
