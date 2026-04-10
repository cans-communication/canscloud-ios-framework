//
//  LinphoneManager.m
//  CansConnect
//

#import "LinphoneManager.h"
#import <CommonCrypto/CommonDigest.h>

static LinphoneCore *theLinphoneCore = nil;
NSString *const kLinphoneRegistrationUpdate = @"LinphoneRegistrationUpdate";

@interface LinphoneManager () {
  NSTimer *iterateTimer;
}
@end

@implementation LinphoneManager

+ (instancetype)sharedInstance {
  static LinphoneManager *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[self alloc] init];
  });
  return sharedInstance;
}

- (void)startIterateTimer {
  if (iterateTimer)
    [iterateTimer invalidate];
  iterateTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                  target:self
                                                selector:@selector(iterate)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)iterate {
  if (theLinphoneCore)
    linphone_core_iterate(theLinphoneCore);
}

// 🚀 สร้าง Core บน Main Thread และใช้ Core ธรรมดาเพื่อ Bypass ปัญหา Apple Developer
// 🚀 สร้าง Core บน Main Thread และแก้บั๊ก Config เก่าพัง
- (void)createLinphoneCore {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (theLinphoneCore) {
      NSLog(@"[LinphoneManager] createLinphoneCore: Core already exists.");
      return;
    }
    NSLog(@"[LinphoneManager] createLinphoneCore: Started on Main Thread");

    LinphoneFactory *factory = linphone_factory_get();
    if (!factory) {
      NSLog(@"[LinphoneManager] FATAL ERROR: linphone_factory_get() returned NULL!");
      return;
    }
    NSLog(@"[LinphoneManager] Factory initialized at: %p", factory);

    // 🛡️ Initialize logging service early to set up global SDK state
    LinphoneLoggingService *logService = linphone_logging_service_get();
    if (logService) {
      linphone_logging_service_set_log_level(logService, LinphoneLogLevelMessage);
      NSLog(@"[LinphoneManager] Logging service initialized at: %p", logService);
    }

    NSBundle *frameworkBundle = [NSBundle bundleForClass:[self class]];
    NSString *factoryPath = [frameworkBundle pathForResource:@"linphonerc-factory" ofType:nil];
    if (!factoryPath) {
      factoryPath = [[NSBundle mainBundle] pathForResource:@"linphonerc-factory" ofType:nil];
    }
    NSLog(@"[LinphoneManager] Factory path: %@", factoryPath ?: @"MISSING");

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *configPath = [documentsDirectory stringByAppendingPathComponent:@"linphonerc_standalone"];
    NSLog(@"[LinphoneManager] Config path: %@", configPath);

    const char *c_configPath = configPath.UTF8String;
    const char *c_factoryPath = factoryPath ? factoryPath.UTF8String : NULL;

    LinphoneConfig *config = NULL;
    if (c_factoryPath != NULL) {
      NSLog(@"[LinphoneManager] Creating config with factory path...");
      config = linphone_factory_create_config_with_factory(factory, c_configPath, c_factoryPath);
    } else {
      NSLog(@"[LinphoneManager] Warning: Factory path missing, creating standard config");
      config = linphone_factory_create_config(factory, c_configPath);
    }

    if (!config) {
      NSLog(@"[LinphoneManager] FATAL ERROR: Failed to create LinphoneConfig object.");
      return;
    }
    NSLog(@"[LinphoneManager] Config created at: %p", config);

    linphone_config_set_int(config, "misc", "max_calls", 1);
    
    // 🛡️ 0x138 Crash Fix: Disable specs and features that might trigger internal friend list notifications early
    NSLog(@"[LinphoneManager] Overriding config to disable LIME and Presence...");
    linphone_config_set_string(config, "sip", "linphone_specs", "groupchat");
    linphone_config_set_int(config, "app", "publish_presence", 0);
    linphone_config_set_int(config, "sip", "publish_presence", 0);
    
    // 🛡️ API Fix: linphone_factory_create_core_with_config_3 is the correct modern API.
    // Argument 3 is the system context (void *), which is NULL for generic platform iterate.
    NSLog(@"[LinphoneManager] Attempting to create core with correct API (v3)...");
    theLinphoneCore = linphone_factory_create_core_with_config_3(factory, config, NULL);

    if (theLinphoneCore) {
      NSLog(@"[LinphoneManager] Core created successfully at: %p", theLinphoneCore);
      
      LinphoneCoreCbs *cbs = linphone_factory_create_core_cbs(factory);
      linphone_core_cbs_set_registration_state_changed(cbs, linphone_iphone_registration_state);
      linphone_core_cbs_set_user_data(cbs, (__bridge void *)(self));

      linphone_core_add_callbacks(theLinphoneCore, cbs);
      
      NSLog(@"[LinphoneManager] Starting core...");
      linphone_core_start(theLinphoneCore);
      
      [self startIterateTimer];
      NSLog(@"[LinphoneManager] Core started and timer running!");
    } else {
      NSLog(@"[LinphoneManager] FATAL ERROR: linphone_factory_create_core_with_config returned NULL!");
    }

    if (config) linphone_config_unref(config);
  });
}

+ (LinphoneCore *)getLc {
  return theLinphoneCore;
}

- (void)onRegister:(LinphoneCore *)lc
               cfg:(LinphoneProxyConfig *)cfg
             state:(LinphoneRegistrationState)state
           message:(const char *)cmessage {
  NSDictionary *dict = @{
    @"state" : @(state),
    @"message" : cmessage ? [NSString stringWithUTF8String:cmessage] : @""
  };
  [NSNotificationCenter.defaultCenter
      postNotificationName:kLinphoneRegistrationUpdate
                    object:self
                  userInfo:dict];
}

static void linphone_iphone_registration_state(LinphoneCore *lc,
                                               LinphoneProxyConfig *cfg,
                                               LinphoneRegistrationState state,
                                               const char *message) {
  LinphoneManager *manager =
      (__bridge LinphoneManager *)linphone_core_cbs_get_user_data(
          linphone_core_get_current_callbacks(lc));
  [manager onRegister:lc cfg:cfg state:state message:message];
}

- (NSString *)md5:(NSString *)input {
  const char *cStr = [input UTF8String];
  unsigned char digest[16];
  CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
  NSMutableString *output = [NSMutableString stringWithCapacity:32];
  for (int i = 0; i < 16; i++)
    [output appendFormat:@"%02x", digest[i]];
  return output;
}

// 🚀 ฟังก์ชัน Login เข้าระบบ SIP
- (void)registerSipWithUsername:(NSString *)username
                       password:(NSString *)password
                         domain:(NSString *)domain
                      transport:(NSString *)transport {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore) {
      NSLog(@"[LinphoneManager] Cannot register, Core is NULL");
      return;
    }

    NSLog(@"[LinphoneManager] Start Registering SIP: %@ @ %@ via %@", username,
          domain, transport);

    LinphoneProxyConfig *proxyCfg =
        linphone_core_create_proxy_config(theLinphoneCore);

    NSString *identityStr =
        [NSString stringWithFormat:@"sip:%@@%@", username, domain];
    NSString *serverStr =
        [NSString stringWithFormat:@"sip:%@;transport=%@", domain, transport];

    LinphoneAddress *identity = linphone_address_new(identityStr.UTF8String);
    LinphoneAddress *server = linphone_address_new(serverStr.UTF8String);

    linphone_proxy_config_set_identity_address(proxyCfg, identity);
    linphone_proxy_config_set_server_addr(proxyCfg, server);
    linphone_proxy_config_enable_register(proxyCfg, TRUE);

    LinphoneAuthInfo *info =
        linphone_auth_info_new(username.UTF8String, NULL, password.UTF8String,
                               NULL, NULL, domain.UTF8String);

    linphone_core_add_auth_info(theLinphoneCore, info);
    linphone_core_add_proxy_config(theLinphoneCore, proxyCfg);
    linphone_core_set_default_proxy_config(theLinphoneCore, proxyCfg);

    if (identity)
      linphone_address_unref(identity);
    if (server)
      linphone_address_unref(server);
    if (info)
      linphone_auth_info_unref(info);
    if (proxyCfg)
      linphone_proxy_config_unref(proxyCfg);
  });
}

// ฟังก์ชันเดิมสำหรับดึงข้อมูลบัญชี
- (NSString *)accountList {
  return @"[]"; // หรือใส่ logic ดึง account ตามที่เคยเขียนไว้
}

// ฟังก์ชันเดิมสำหรับลบบัญชี
- (void)removeAccountAtIndex:(NSInteger)index {
  const bctbx_list_t *accounts =
      linphone_core_get_account_list(theLinphoneCore);
  NSInteger currentIndex = 0;

  for (const bctbx_list_t *it = accounts; it != NULL; it = it->next) {
    if (currentIndex == index) {
      LinphoneAccount *account = (LinphoneAccount *)it->data;
      const LinphoneAccountParams *params =
          linphone_account_get_params(account);
      const LinphoneAddress *identity =
          linphone_account_params_get_identity_address(params);
      if (identity) {
        const char *username = linphone_address_get_username(identity);
        const char *domain = linphone_address_get_domain(identity);
        const LinphoneAuthInfo *authInfo = linphone_core_find_auth_info(
            theLinphoneCore, NULL, username, domain);
        if (authInfo) {
          linphone_core_remove_auth_info(theLinphoneCore, authInfo);
        }
      }
      linphone_core_remove_account(theLinphoneCore, account);
      NSLog(@"[CansConnect] Removed account at index: %ld", (long)index);
      break;
    }
    currentIndex++;
  }
}

// ฟังก์ชันเดิมสำหรับการตั้งค่าแชท
- (void)configureChatSettings:(NSString *)username {
  NSLog(@"[LinphoneManager] Configure chat settings for %@", username);
}

@end