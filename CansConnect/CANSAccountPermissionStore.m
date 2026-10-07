//
//  CANSAccountPermissionStore.m
//  CansConnect
//

#import "CANSAccountPermissionStore.h"

static NSString *const kCANSAccountPermissionsKeyPrefix = @"com.canscloud.accountPermissions.";
static NSString *const kCANSSignInAddressKeyPrefix =
    @"com.canscloud.accountPermissionsSignInAddress.";

/// String entries of `value` when it is an array, otherwise `nil`.
static NSArray<NSString *> *_Nullable CANSStringEntries(id _Nullable value) {
  if (![value isKindOfClass:[NSArray class]]) return nil;
  NSMutableArray<NSString *> *strings = [NSMutableArray array];
  for (id entry in (NSArray *)value) {
    if ([entry isKindOfClass:[NSString class]]) [strings addObject:entry];
  }
  return [strings copy];
}

@implementation CANSAccountPermissionStore {
  NSUserDefaults *_defaults;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
  self = [super init];
  if (self) {
    _defaults = defaults;
  }
  return self;
}

+ (NSString *)keyForSipAddress:(NSString *)sipAddress {
  return [kCANSAccountPermissionsKeyPrefix stringByAppendingString:sipAddress];
}

+ (NSArray<NSString *> *)permissionsFromUser:(id)user {
  if (![user isKindOfClass:[NSDictionary class]]) return nil;
  return CANSStringEntries(((NSDictionary *)user)[@"permissions"]);
}

- (NSArray<NSString *> *)permissionsForSipAddress:(NSString *)sipAddress {
  if (sipAddress.length == 0) return nil;
  return CANSStringEntries([_defaults objectForKey:[[self class] keyForSipAddress:sipAddress]]);
}

- (void)setPermissions:(NSArray<NSString *> *)permissions forSipAddress:(NSString *)sipAddress {
  if (sipAddress.length == 0) return;
  NSString *key = [[self class] keyForSipAddress:sipAddress];
  NSArray<NSString *> *strings = CANSStringEntries(permissions);
  if (strings) {
    [_defaults setObject:strings forKey:key];
  } else {
    [_defaults removeObjectForKey:key];
  }
}

- (void)setSignInAddress:(NSString *)sipAddress forIdentityAddress:(NSString *)identityAddress {
  if (sipAddress.length == 0 || identityAddress.length == 0) return;
  [_defaults setObject:sipAddress
                forKey:[kCANSSignInAddressKeyPrefix stringByAppendingString:identityAddress]];
}

- (void)removePermissionsForIdentityAddress:(NSString *)identityAddress {
  if (identityAddress.length == 0) return;
  NSString *signInKey = [kCANSSignInAddressKeyPrefix stringByAppendingString:identityAddress];
  id recorded = [_defaults objectForKey:signInKey];
  NSString *sipAddress =
      [recorded isKindOfClass:[NSString class]] && [recorded length] > 0 ? recorded : identityAddress;
  [_defaults removeObjectForKey:[[self class] keyForSipAddress:sipAddress]];
  [_defaults removeObjectForKey:signInKey];
}

- (void)removeAllPermissions {
  [self removeKeysWithPrefix:kCANSAccountPermissionsKeyPrefix];
  [self removeKeysWithPrefix:kCANSSignInAddressKeyPrefix];
}

- (void)removeKeysWithPrefix:(NSString *)prefix {
  for (NSString *key in [_defaults dictionaryRepresentation].allKeys) {
    if ([key hasPrefix:prefix]) [_defaults removeObjectForKey:key];
  }
}

@end
