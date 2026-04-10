//
//  LinphoneManager.h
//  CansConnect
//

#import <Foundation/Foundation.h>
#import <linphone/linphonecore.h>

extern NSString *const kLinphoneRegistrationUpdate;

@interface LinphoneManager : NSObject

+ (instancetype)sharedInstance;
+ (LinphoneCore *)getLc;

- (void)createLinphoneCore;

// ฟังก์ชันสำหรับ Login/Register
- (void)registerSipWithUsername:(NSString *)username
                       password:(NSString *)password
                         domain:(NSString *)domain
                      transport:(NSString *)transport;

// ฟังก์ชันจัดการ Account ตามที่มีในโค้ดเดิม
- (NSString *)accountList;
- (void)removeAccountAtIndex:(NSInteger)index;
- (void)configureChatSettings:(NSString *)username;

@end