//
//  CANSSignInUserStore.h
//  CansConnect
//
// Per-account `data.user` from `POST api/v3/sign-in/cc` in `NSUserDefaults`, keyed by sign-in address (matching accessToken).
// Stores full user JSON under `com.canscloud.signInUser.<sipAddress>`; the host reads `permissions` and every other field from it.
// The identity → sign-in address map keeps its `1.0.15` key name (`com.canscloud.accountPermissionsSignInAddress.*`) so existing installs still sign out cleanly.
// SDK treats values opaquely (host defines semantics); pure Foundation, no Linphone dependency.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CANSSignInUserStore : NSObject

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (nullable NSString *)signInUserJSONFromUser:(nullable id)user;

- (nullable NSString *)signInUserForSipAddress:(NSString *)sipAddress;

- (void)setSignInUser:(nullable NSString *)userJSON forSipAddress:(NSString *)sipAddress;

/// Maps a SIP `identityAddress` to its designated sign-in storage address. 
/// Required because domains can differ, leaving only the identity as a reference upon account removal.
- (void)setSignInAddress:(NSString *)sipAddress forIdentityAddress:(NSString *)identityAddress;

/// Removes the stored user and recorded sign-in address for the account matching `identityAddress`.
- (void)removeSignInDataForIdentityAddress:(NSString *)identityAddress;

/// Removes every stored `user` and every recorded sign-in address.
- (void)removeAllSignInData;

/// Purges legacy `1.0.15` `com.canscloud.accountPermissions.<sipAddress>` entries on sign-out 
/// to prevent persistence, as these keys are no longer read or cleared.
- (void)removeLegacyAccountPermissions;

@end

NS_ASSUME_NONNULL_END
