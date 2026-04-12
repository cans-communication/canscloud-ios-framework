//
//  LinphoneManager.h
//  CansConnect
//

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <linphone/linphonecore.h>

extern NSString *const kLinphoneRegistrationUpdate;
extern NSString *const kLinphoneCallStateUpdate;

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
- (void)configureChatSettings:(NSString *)username;
- (void)startCall:(NSString *)phoneNumber;
- (NSInteger)callsCount;
// Method สำหรับ Call Management และ Audio
- (NSString *)getCallingLogsJSON;
- (int)getDurationTime;
- (int)getDurationByAddress:(NSString *)address;
- (BOOL)isInConference;
- (void)hangUp;
- (void)hangUpAll;
- (void)terminateCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone;
- (void)resumeCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone;
- (void)startConference;
- (void)splitConference;
- (void)dtmfKeypad:(NSString *)numberDtmf key:(NSString *)key;
- (void)applySmartPlaybackGain:(BOOL)isExtension;
- (void)setPlaybackGain:(NSString *)gain;

// Audio Routing
- (BOOL)isSpeakerEnabled;
- (void)toggleSpeaker;
- (BOOL)isMicMuted;
- (BOOL)toggleMute;
- (BOOL)isBluetoothAudioRouteAvailable;
- (BOOL)isBluetoothState;

// Helper Convert
- (NSString *)convertCallStateToString:(LinphoneCallState)state;

@end