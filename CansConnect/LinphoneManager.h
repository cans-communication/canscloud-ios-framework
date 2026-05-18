//
//  LinphoneManager.h
//  CansConnect
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#else
// Fallback for indexing or macOS targets
@class UIView;
#endif

// Note: If you get a 'file not found' error here, ensure you have the Linphone
// SDK installed in CansConnect/linphone-sdk or via CocoaPods.
#if __has_include(<LinphoneSDK/linphonecore.h>)
#import <LinphoneSDK/linphonecore.h>
#else
#import <linphone/linphonecore.h>
#endif

extern NSString *const kLinphoneRegistrationUpdate;
extern NSString *const kLinphoneCallStateUpdate;
extern NSString *const kLinphoneAudioDeviceUpdate;
extern NSString *const kLinphoneRemoteVideoStateUpdate;
extern NSString *const kCansCustomRegistrationEvent;

@interface LinphoneManager : NSObject

+ (instancetype)sharedInstance;
+ (LinphoneCore *)getLc;

- (void)createLinphoneCore;

- (void)registerSipWithUsername:(NSString *)username
                       password:(NSString *)password
                         domain:(NSString *)domain
                      transport:(NSString *)transport;
- (NSString *)accountList;
- (void)removeAccountAtIndex:(NSInteger)index;
- (void)removeAccountAll;
- (void)configureChatSettings:(NSString *)username;
- (void)startCall:(NSString *)phoneNumber;
- (NSInteger)callsCount;
// Method สำหรับ Call Management และ Audio
- (void)acceptCall;
- (NSString *)getCallingLogsJSON;
- (NSString *)getHistoryCallLogsJSON;
- (NSString *)getMissedCallLogsJSON;
- (int)getDurationTime;
- (int)getDurationByAddress:(NSString *)address;
- (BOOL)isInConference;
- (void)hangUp;
- (void)hangUpAll;
- (void)terminateAllCalls;
- (void)terminateCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone;
- (void)resumeCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone;
- (void)pauseCall;
- (void)pauseCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone;
- (void)startConference;
- (void)splitConference;
- (void)dtmfKeypad:(NSString *)numberDtmf key:(NSString *)key;
- (void)applySmartPlaybackGain:(BOOL)isExtension;
- (void)setPlaybackGain:(NSString *)gain;

// Audio Routing
- (BOOL)isSpeakerEnabled;
- (void)toggleSpeaker;
- (void)routeAudioToSpeaker;
- (void)routeAudioToEarpiece;
- (void)routeAudioToBluetooth;
- (BOOL)isMicMuted;
- (BOOL)toggleMute;
- (BOOL)isBluetoothAudioRouteAvailable;
- (BOOL)isBluetoothState;

// Helper Convert
- (NSString *)convertCallStateToString:(LinphoneCallState)state;
- (void)registerCansAccountWithUsername:(NSString *)username
                               password:(NSString *)password
                                 domain:(NSString *)domain
                                 apiURL:(NSString *)apiURL;

// Video Call Methods
- (BOOL)isVideoCall;
- (void)switchCamera;
- (void)makeVideoCall:(NSString *)phoneNumber;
- (void)acceptVideoCall;
- (void)setVideoWindowsWithRemoteView:(UIView *)remoteView
                            localView:(UIView *)localView;
- (void)setVideoEnabled:(BOOL)enabled;
- (NSString *)destinationUsername;
- (int)missedCallsCount;
- (void)transferCallNow:(NSString *)phoneNumber;
- (void)transferCallAskFirst:(NSString *)phoneNumber;

// Messaging & Chat
- (void)configureChatSettings:(NSString *)username;
- (NSString *)getChatRoomsJSON;
- (NSString *)getChatHistoryJSON:(NSString *)peerUri;
- (void)sendTextMessage:(NSString *)peerUri
                   text:(NSString *)text
              requestId:(NSString *)requestId;
- (void)sendImageMessage:(NSString *)peerUri
                filePath:(NSString *)filePath
               requestId:(NSString *)requestId;
- (void)deleteMessage:(NSString *)peerUri msgId:(NSString *)msgId;
- (void)markAsRead:(NSString *)peerUri;
- (void)setDefaultAccount:(NSInteger)index phoneNumber:(NSString *)phoneNumber;

@end