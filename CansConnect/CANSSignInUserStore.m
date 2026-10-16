//
//  CANSSignInUserStore.m
//  CansConnect
//

#import "CANSSignInUserStore.h"

static NSString *const kCANSAccountPermissionsKeyPrefix = @"com.canscloud.accountPermissions.";
static NSString *const kCANSSignInUserKeyPrefix = @"com.canscloud.signInUser.";
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

/// `text` when it parses as a JSON object, otherwise `nil`.
static NSString *_Nullable CANSJSONObjectText(id _Nullable text) {
  if (![text isKindOfClass:[NSString class]] || [text length] == 0) return nil;
  NSData *data = [(NSString *)text dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [parsed isKindOfClass:[NSDictionary class]] ? text : nil;
}

@implementation CANSSignInUserStore {
  NSUserDefaults *_defaults;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
  self = [super init];
  if (self) {
    _defaults = defaults;
  }
  return self;
}

+ (NSString *)permissionsKeyForSipAddress:(NSString *)sipAddress {
  return [kCANSAccountPermissionsKeyPrefix stringByAppendingString:sipAddress];
}

+ (NSArray<NSString *> *)permissionsFromUser:(id)user {
  if (![user isKindOfClass:[NSDictionary class]]) return nil;
  return CANSStringEntries(((NSDictionary *)user)[@"permissions"]);
}

- (NSArray<NSString *> *)permissionsForSipAddress:(NSString *)sipAddress {
  if (sipAddress.length == 0) return nil;
  return CANSStringEntries(
      [_defaults objectForKey:[[self class] permissionsKeyForSipAddress:sipAddress]]);
}

- (void)setPermissions:(NSArray<NSString *> *)permissions forSipAddress:(NSString *)sipAddress {
  if (sipAddress.length == 0) return;
  NSString *key = [[self class] permissionsKeyForSipAddress:sipAddress];
  NSArray<NSString *> *strings = CANSStringEntries(permissions);
  if (strings) {
    [_defaults setObject:strings forKey:key];
  } else {
    [_defaults removeObjectForKey:key];
  }
}

+ (NSString *)signInUserJSONFromUser:(id)user {
  if (![user isKindOfClass:[NSDictionary class]] || ![NSJSONSerialization isValidJSONObject:user]) {
    return nil;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:user options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (NSString *)signInUserForSipAddress:(NSString *)sipAddress {
  if (sipAddress.length == 0) return nil;
  return CANSJSONObjectText(
      [_defaults objectForKey:[kCANSSignInUserKeyPrefix stringByAppendingString:sipAddress]]);
}

- (void)setSignInUser:(NSString *)userJSON forSipAddress:(NSString *)sipAddress {
  if (sipAddress.length == 0) return;
  NSString *key = [kCANSSignInUserKeyPrefix stringByAppendingString:sipAddress];
  NSString *text = CANSJSONObjectText(userJSON);
  if (text) {
    [_defaults setObject:text forKey:key];
  } else {
    [_defaults removeObjectForKey:key];
  }
}

- (void)setSignInAddress:(NSString *)sipAddress forIdentityAddress:(NSString *)identityAddress {
  if (sipAddress.length == 0 || identityAddress.length == 0) return;
  [_defaults setObject:sipAddress
                forKey:[kCANSSignInAddressKeyPrefix stringByAppendingString:identityAddress]];
}

- (void)removeSignInDataForIdentityAddress:(NSString *)identityAddress {
  if (identityAddress.length == 0) return;
  NSString *signInKey = [kCANSSignInAddressKeyPrefix stringByAppendingString:identityAddress];
  id recorded = [_defaults objectForKey:signInKey];
  NSString *sipAddress =
      [recorded isKindOfClass:[NSString class]] && [recorded length] > 0 ? recorded : identityAddress;
  [_defaults removeObjectForKey:[[self class] permissionsKeyForSipAddress:sipAddress]];
  [_defaults removeObjectForKey:[kCANSSignInUserKeyPrefix stringByAppendingString:sipAddress]];
  [_defaults removeObjectForKey:signInKey];
}

- (void)removeAllSignInData {
  [self removeKeysWithPrefix:kCANSAccountPermissionsKeyPrefix];
  [self removeKeysWithPrefix:kCANSSignInUserKeyPrefix];
  [self removeKeysWithPrefix:kCANSSignInAddressKeyPrefix];
}

- (void)removeKeysWithPrefix:(NSString *)prefix {
  for (NSString *key in [_defaults dictionaryRepresentation].allKeys) {
    if ([key hasPrefix:prefix]) [_defaults removeObjectForKey:key];
  }
}

@end
