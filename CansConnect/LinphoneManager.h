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
#import <LinphoneSDK/core_utils.h>
#else
#import <linphone/linphonecore.h>
#import <linphone/core_utils.h>
#endif

NS_ASSUME_NONNULL_BEGIN

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
- (void)startCall:(NSString *)phoneNumber;
- (NSInteger)callsCount;
- (void)acceptCall;
- (NSString *)getCallingLogsJSON;
- (NSString *)getHistoryCallLogsJSON;
- (NSString *)getMissedCallLogsJSON;
- (NSString *)lastOutgoingCallLog;
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

// Audio Settings
- (BOOL)getEchoCancellation;
- (void)setEchoCancellationEnabled:(BOOL)enabled;
- (BOOL)getAdaptiveRateControl;
- (void)setAdaptiveRateControlEnabled:(BOOL)enabled;
- (float)getMicrophoneGainDb;
- (void)setMicrophoneGainDb:(float)gain;
- (float)getPlaybackGainDb;
- (int)getCodecBitrateKbps;
- (void)setCodecBitrateKbps:(int)kbps;
- (NSString *)getCodecsListJSON;
- (void)setPayLoadAtIndex:(int)index enabled:(BOOL)enabled;

// Ringtone / Vibrate
- (BOOL)getDeviceRingtone;
- (void)setDeviceRingtone:(BOOL)useDevice;
- (BOOL)getVibrateOnIncomingCall;
- (void)setVibrateOnIncomingCallEnabled:(BOOL)enabled;

// Encryption
- (NSString *)getMediaEncryptionName;
- (void)setMediaEncryption:(int)position;
- (BOOL)getEncryptionMandatory;
- (void)setEncryptionMandatory:(BOOL)mandatory;

// DTMF
- (BOOL)getSipInfoDtmf;
- (void)setSipInfoDtmf:(BOOL)enabled;
- (BOOL)getUseRfc2833ForDtmf;
- (void)setUseRfc2833ForDtmf:(BOOL)enabled;

// Call Behaviour
- (int)getIncomingTimeout;
- (void)setIncomingTimeout:(int)seconds;

// Network
- (BOOL)getWifiOnly;
- (void)setWifiOnly:(BOOL)enabled;
- (BOOL)getAllowIpv6;
- (void)setAllowIpv6:(BOOL)enabled;
- (BOOL)getRandomPorts;
- (void)setRandomPorts:(BOOL)random;
- (int)getJitterBuffer;
- (void)setJitterBuffer:(int)ms;

// Logging
- (NSString *)getLogsUploadServerURL;
- (void)setLogsUploadServerURL:(NSString *)url;
- (void)uploadLogCollection;
- (void)resetLogCollection;

// Echo Calibration / Tester
- (void)startEchoCancellerCalibration;
- (void)toggleEchoTester;

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
- (BOOL)isRemoteVideoEnabled;
- (NSDictionary *)getRemoteVideoStats;
- (void)switchCamera;
- (void)makeVideoCall:(NSString *)phoneNumber;
- (void)acceptVideoCall;
- (void)setVideoWindowsWithRemoteView:(UIView *)remoteView
                            localView:(UIView *)localView;
- (void)setVideoEnabled:(BOOL)enabled;
- (NSString *)destinationUsername;
- (int)missedCallsCount;
- (BOOL)transferCallNow:(NSString *)phoneNumber;
- (BOOL)transferCallAskFirst:(NSString *)phoneNumber;

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
- (void)chatCleanupAll;
- (void)setDefaultAccount:(NSInteger)index phoneNumber:(NSString *)phoneNumber;
- (void)setDefaultAccountSync:(NSInteger)index phoneNumber:(NSString *)phoneNumber;
- (NSString *)updateCurrentLoginTypeFromAccount;

// FCM Push Notification (replaces built-in Linphone push)
- (void)injectFCMToken:(NSString *)fcmToken
            forAccount:(nullable LinphoneAccount *)account
     completionHandler:(nullable void (^)(BOOL success))completion;
- (void)removeFCMTokenForAccount:(nullable LinphoneAccount *)account;
- (void)processPushNotification:(NSString *)callId;

- (void)setExpire:(int)seconds;
- (BOOL)getPushNotification;
- (int)getExpires;
- (NSString *)getPrefix;
- (BOOL)getReplaceBy00;
- (NSString *)getUsername;
- (NSString *)getPassword;
- (NSString *)getDisplayName;
- (NSString *)getDomain;
- (NSString *)getSipProxy;
- (BOOL)getOutboundProxy;
- (NSString *)getStunServer;
- (BOOL)getEnableICE;
- (int)getAVPF;
- (int)getAvpfRrInterval;
- (NSString *)getTransport;
- (BOOL)checkSessionCansLogin;

@end

NS_ASSUME_NONNULL_END