//
//  CANSAccountPermissionStore.m
//  CansConnect
//

#import "CANSAccountPermissionStore.h"

static NSString *const kCANSAccountPermissionsKeyPrefix = @"com.canscloud.accountPermissions.";

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

- (void)removePermissionsForUsername:(NSString *)username {
  if (username.length == 0) return;
  [self removeKeysWithPrefix:[NSString stringWithFormat:@"%@%@@", kCANSAccountPermissionsKeyPrefix,
                                                        username]];
}

- (void)removeAllPermissions {
  [self removeKeysWithPrefix:kCANSAccountPermissionsKeyPrefix];
}

- (void)removeKeysWithPrefix:(NSString *)prefix {
  for (NSString *key in [_defaults dictionaryRepresentation].allKeys) {
    if ([key hasPrefix:prefix]) [_defaults removeObjectForKey:key];
  }
}

@end
