//
//  LinphoneManager.h
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 13/11/2565 BE.
//

#import <Foundation/Foundation.h>
#import <Photos/Photos.h>

#import "Log.h"
#import "FastAddressBook.h"


@import linphone;


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

extern const int kLinphoneAudioVbrCodecDefaultBitrate;


@interface LinphoneManager : NSObject {
    
}

+ (LinphoneManager*)instance;
+ (LinphoneCore*) getLc;
+ (NSString *)cacheDirectory;
+ (NSString *)bundleFile:(NSString *)file;
+ (NSString*)dataFile:(NSString*)file;
+ (NSString *)preferenceFile:(NSString *)file;

- (void)createLinphoneCore;
- (void)registerSip;

- (void)configurePushTokenForProxyConfig: (LinphoneProxyConfig*)cfg;

- (void)lpConfigSetString:(NSString*)value forKey:(NSString*)key;
- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key inSection:(NSString *)section;

- (void)lpConfigSetInt:(int)value forKey:(NSString *)key;
- (void)lpConfigSetInt:(int)value forKey:(NSString *)key inSection:(NSString *)section;

- (void)lpConfigSetBool:(BOOL)value forKey:(NSString*)key;
- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key inSection:(NSString *)section;

- (NSString *)lpConfigStringForKey:(NSString *)key;
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section;
- (NSString *)lpConfigStringForKey:(NSString *)key withDefault:(NSString *)value;
- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section withDefault:(NSString *)value;

- (int)lpConfigIntForKey:(NSString *)key;
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section;
- (int)lpConfigIntForKey:(NSString *)key withDefault:(int)value;
- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section withDefault:(int)value;

- (BOOL)lpConfigBoolForKey:(NSString *)key;
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section;
- (BOOL)lpConfigBoolForKey:(NSString *)key withDefault:(BOOL)value;
- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section withDefault:(BOOL)value;

+ (BOOL)copyFile:(NSString*)src destination:(NSString*)dst override:(BOOL)override ignore:(BOOL)ignore;

@property(nonatomic, strong) NSData *pushKitToken;
@property(nonatomic, strong) NSData *remoteNotificationToken;
@property (readonly) BOOL wasRemoteProvisioned;
@property (readonly) LpConfig *configDb;
@property UIImage *avatar;
//@property(readonly, strong) FastAddressBook *fastAddressBook;

@end


