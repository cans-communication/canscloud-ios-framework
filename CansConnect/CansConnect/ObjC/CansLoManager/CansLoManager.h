//
//  LinphoneManager.h
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 13/11/2565 BE.
//

#import <Foundation/Foundation.h>


@import linphone;


#define LC ([CansLoManager getLc])


extern NSString *const kLinphoneCoreUpdate;
extern NSString *const kLinphoneDisplayStatusUpdate;
extern NSString *const kLinphoneMessageReceived;
extern NSString *const kLinphoneTextComposeEvent;
extern NSString *const kLinphoneCallUpdate;
extern NSString *const kLinphoneRegistrationUpdate;
extern NSString *const kLinphoneMainViewChange;
extern NSString *const kLinphoneAddressBookUpdate;
extern NSString *const kLinphoneLogsUpdate;
extern NSString *const kLinphoneSettingsUpdate;
extern NSString *const kLinphoneBluetoothAvailabilityUpdate;
extern NSString *const kLinphoneConfiguringStateUpdate;
extern NSString *const kLinphoneGlobalStateUpdate;
extern NSString *const kLinphoneNotifyReceived;
extern NSString *const kLinphoneNotifyPresenceReceivedForUriOrTel;
extern NSString *const kLinphoneCallEncryptionChanged;
extern NSString *const kLinphoneFileTransferSendUpdate;
extern NSString *const kLinphoneFileTransferRecvUpdate;
extern NSString *const kLinphoneQRCodeFound;
extern NSString *const kLinphoneChatCreateViewChange;
extern NSString *const kLinphoneMsgNotificationAppGroupId;


@interface CansLoManager : NSObject {
    
}


@property (readonly) LpConfig *configDb;


+ (LinphoneCore*) getLc;
+ (NSString*)cacheDirectory;

- (void)createLinphoneCore;
- (void)registerSip;


@end


