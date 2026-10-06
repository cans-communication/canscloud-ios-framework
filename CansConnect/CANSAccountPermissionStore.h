//
//  CANSAccountPermissionStore.h
//  CansConnect
//
// Per-account `permissions` array from `POST api/v3/sign-in/cc`, stored raw (NSArray of NSString)
// in NSUserDefaults under `com.canscloud.accountPermissions.<sipAddress>` (matching accessToken keying).
// SDK treats values opaquely; host app defines semantics. Pure Foundation, no Linphone dependency.
// `nil` ("unknown/unstored") differs from an empty array ("known: zero permissions").

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CANSAccountPermissionStore : NSObject

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (NSString *)keyForSipAddress:(NSString *)sipAddress;

/// `user[@"permissions"]` from a sign-in response. `nil` when the field is missing, `NSNull` or not
/// an array; otherwise its string entries, unchanged (other entries are dropped).
+ (nullable NSArray<NSString *> *)permissionsFromUser:(nullable id)user;

/// The stored list, or `nil` when nothing (or nothing readable) is stored for `sipAddress`.
- (nullable NSArray<NSString *> *)permissionsForSipAddress:(NSString *)sipAddress;

/// Replaces the stored list. `nil` removes it, leaving the account's permissions unknown.
- (void)setPermissions:(nullable NSArray<NSString *> *)permissions
         forSipAddress:(NSString *)sipAddress;

/// Records which sign-in address (`<extension>@<sign-in domain>`) the account with SIP identity
/// `identityAddress` (`<username>@<identity domain>`, no port) stores its list under. The two
/// domains can differ, and an account's identity is all that is left to go by when it is removed.
- (void)setSignInAddress:(NSString *)sipAddress forIdentityAddress:(NSString *)identityAddress;

/// Removes the list of the account with SIP identity `identityAddress`, and only that one: the
/// list under its recorded sign-in address, or under `identityAddress` itself when none is recorded.
- (void)removePermissionsForIdentityAddress:(NSString *)identityAddress;

/// Removes every stored list and every recorded sign-in address.
- (void)removeAllPermissions;

@end

NS_ASSUME_NONNULL_END
