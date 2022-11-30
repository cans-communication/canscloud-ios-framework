//
//  CansLinphoneManager.h
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 13/11/2565 BE.
//

#import <Foundation/Foundation.h>

#import "TestManager.h"

#include "linphone/factory.h"
//#include "linphone/linphonecore.h"

//#import "linphone-sdk/apple-darwin/Frameworks/linphone.framework/Headers/linphonecore.h"

//#import "<linphone/linphonecore.h>"

//#define LC ([CansLinphoneManager getLc])



//static LinphoneCore *theLinphoneCore = nil;

NSString *const kLinphoneCoreUpdate = @"LinphoneCoreUpdate";
NSString *const kLinphoneDisplayStatusUpdate = @"LinphoneDisplayStatusUpdate";
NSString *const kLinphoneMessageReceived = @"LinphoneMessageReceived";
NSString *const kLinphoneTextComposeEvent = @"LinphoneTextComposeStarted";
NSString *const kLinphoneCallUpdate = @"LinphoneCallUpdate";
NSString *const kLinphoneRegistrationUpdate = @"LinphoneRegistrationUpdate";
NSString *const kLinphoneAddressBookUpdate = @"LinphoneAddressBookUpdate";
NSString *const kLinphoneMainViewChange = @"LinphoneMainViewChange";
NSString *const kLinphoneLogsUpdate = @"LinphoneLogsUpdate";
NSString *const kLinphoneSettingsUpdate = @"LinphoneSettingsUpdate";
NSString *const kLinphoneBluetoothAvailabilityUpdate = @"LinphoneBluetoothAvailabilityUpdate";
NSString *const kLinphoneConfiguringStateUpdate = @"LinphoneConfiguringStateUpdate";
NSString *const kLinphoneGlobalStateUpdate = @"LinphoneGlobalStateUpdate";
NSString *const kLinphoneNotifyReceived = @"LinphoneNotifyReceived";
NSString *const kLinphoneNotifyPresenceReceivedForUriOrTel = @"LinphoneNotifyPresenceReceivedForUriOrTel";
NSString *const kLinphoneCallEncryptionChanged = @"LinphoneCallEncryptionChanged";
NSString *const kLinphoneFileTransferSendUpdate = @"LinphoneFileTransferSendUpdate";
NSString *const kLinphoneFileTransferRecvUpdate = @"LinphoneFileTransferRecvUpdate";
NSString *const kLinphoneQRCodeFound = @"LinphoneQRCodeFound";
NSString *const kLinphoneChatCreateViewChange = @"LinphoneChatCreateViewChange";
NSString *const kLinphoneMsgNotificationAppGroupId = @"group.cc.cans.canscloud.msgNotification";

@interface CansLinphoneManager : NSObject {
    
}


//@property (readonly) LpConfig *configDb;
//
//+ (LinphoneCore*) getLc;
//- (void)createLinphoneCore;
//- (void)registerSip;


@end


