//
//  CANSSignInUserStore.h
//  CansConnect
//
// Per-account `data.user` from `POST api/v3/sign-in/cc` in `NSUserDefaults`, keyed by sign-in address (matching accessToken).
// Stores full user JSON under `com.canscloud.signInUser.<sipAddress>` and legacy permissions under `com.canscloud.accountPermissions.<sipAddress>`.
// Legacy keys must be preserved for existing installs. SDK treats values opaquely (host defines semantics); pure Foundation, no Linphone dependency.
// Distinguishes unknown/unstored (`nil`) from zero permissions (`[]`).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CANSSignInUserStore : NSObject

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (NSString *)permissionsKeyForSipAddress:(NSString *)sipAddress;

/// Extracts string permissions from `user["permissions"]` in a sign-in response. 
/// Returns `nil` if missing, `NSNull`, or not an array; drops non-string elements.
+ (nullable NSArray<NSString *> *)permissionsFromUser:(nullable id)user;

/// The stored list, or `nil` when nothing (or nothing readable) is stored for `sipAddress`.
- (nullable NSArray<NSString *> *)permissionsForSipAddress:(NSString *)sipAddress;

/// Replaces the stored list. `nil` removes it, leaving the account's permissions unknown.
- (void)setPermissions:(nullable NSArray<NSString *> *)permissions
         forSipAddress:(NSString *)sipAddress;

+ (nullable NSString *)signInUserJSONFromUser:(nullable id)user;

- (nullable NSString *)signInUserForSipAddress:(NSString *)sipAddress;

- (void)setSignInUser:(nullable NSString *)userJSON forSipAddress:(NSString *)sipAddress;

/// Maps a SIP `identityAddress` to its designated sign-in storage address. 
/// Required because domains can differ, leaving only the identity as a reference upon account removal.
- (void)setSignInAddress:(NSString *)sipAddress forIdentityAddress:(NSString *)identityAddress;

/// Removes the permission list and user data for the account matching `identityAddress`
- (void)removeSignInDataForIdentityAddress:(NSString *)identityAddress;

/// Removes every stored list, every stored `user` and every recorded sign-in address.
- (void)removeAllSignInData;

@end

NS_ASSUME_NONNULL_END
