//
//  LinphoneManager.m
//  CansConnect
//

#import "LinphoneManager.h"
#import <CommonCrypto/CommonDigest.h>

static LinphoneCore *theLinphoneCore = nil;
static NSString *const kCANSApiLoginURL = @"com.canscloud.apiLoginURL";
NSString *const kLinphoneRegistrationUpdate = @"LinphoneRegistrationUpdate";
NSString *const kLinphoneCallStateUpdate = @"LinphoneCallStateUpdate";
NSString *const kLinphoneAudioDeviceUpdate = @"LinphoneAudioDeviceUpdate";
NSString *const kLinphoneRemoteVideoStateUpdate = @"LinphoneRemoteVideoStateUpdate";
NSString *const kCansCustomRegistrationEvent = @"CansCustomRegistrationEvent";

// Prototypes for C callbacks
static void linphone_iphone_registration_state(LinphoneCore *lc,
                                               LinphoneProxyConfig *cfg,
                                               LinphoneRegistrationState state,
                                               const char *message);

static void linphone_iphone_global_state_changed(LinphoneCore *lc,
                                                 LinphoneGlobalState state,
                                                 const char *message);

static void linphone_iphone_popup_password_request(LinphoneCore *lc,
                                                   LinphoneAuthInfo *auth_info,
                                                   LinphoneAuthMethod method);

static void linphone_iphone_call_state(LinphoneCore *lc, LinphoneCall *call,
                                        LinphoneCallState state,
                                        const char *message);

static void linphone_iphone_audio_device_changed(LinphoneCore *lc,
                                                 LinphoneAudioDevice *device);

static void linphone_iphone_audio_devices_list_updated(LinphoneCore *lc);

static void linphone_iphone_message_received(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatMessage *message);

static void linphone_iphone_chat_message_state_changed(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatMessage *message, LinphoneChatMessageState state);

static void linphone_iphone_info_received(LinphoneCore *lc, LinphoneCall *call, const LinphoneInfoMessage *msg);

@interface LinphoneManager () {
  NSTimer *iterateTimer;
  BOOL _echoTesterRunning;
  // Tracks last-known remote camera state to suppress duplicate/spurious events
  // (mirrors Android's lastRemoteCameraOnState). Reset to -1 (unknown) on End/Error/Released.
  int _lastRemoteCameraOnState; // -1=unknown, 0=off, 1=on
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

- (void)lpConfigSetString:(LinphoneConfig *)config
                    value:(NSString *)value
                   forKey:(NSString *)key
                inSection:(NSString *)section {
  if (!key || !config)
    return;
  linphone_config_set_string(config, [section UTF8String], [key UTF8String],
                             value ? [value UTF8String] : NULL);
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

+ (NSString *)documentFile:(NSString *)file {
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES);
  NSString *documentsPath = [paths objectAtIndex:0];
  return [documentsPath stringByAppendingPathComponent:file];
}

+ (NSString *)dataFile:(NSString *)file {
  // For non-shared core, we use the standard data directory
  LinphoneFactory *factory = linphone_factory_get();
  const char *dataDir = linphone_factory_get_data_dir(factory, NULL);
  NSString *fullPath = [NSString stringWithUTF8String:dataDir];

  // Ensure directory exists
  [[NSFileManager defaultManager] createDirectoryAtPath:fullPath
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

  return [fullPath stringByAppendingPathComponent:file];
}

// 🚀 สร้าง Core บน Main Thread และใช้ Core ธรรมดาเพื่อ Bypass ปัญหา Apple Developer
// 🚀 สร้าง Core บน Main Thread และแก้บั๊ก Config เก่าพัง
- (void)createLinphoneCore {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (theLinphoneCore) {
      NSLog(@"[LinphoneManager] createLinphoneCore: Core already exists. (Timer status: %@)", iterateTimer ? @"Running" : @"Stopped");
      if (!iterateTimer) [self startIterateTimer];
      return;
    }
    NSLog(@"[LinphoneManager] createLinphoneCore: Started on Main Thread");

    LinphoneFactory *factory = linphone_factory_get();
    if (!factory) {
      NSLog(@"[LinphoneManager] FATAL ERROR: linphone_factory_get() returned "
            @"NULL!");
      return;
    }
    NSLog(@"[LinphoneManager] Factory initialized at: %p", factory);

    // 🛡️ Initialize logging service early to set up global SDK state
    LinphoneLoggingService *logService = linphone_logging_service_get();
    if (logService) {
      linphone_logging_service_set_log_level(logService,
                                             LinphoneLogLevelMessage);
      NSLog(@"[LinphoneManager] Logging service initialized at: %p",
            logService);
    }

    NSBundle *frameworkBundle = [NSBundle bundleForClass:[self class]];
    NSString *factoryPath =
        [frameworkBundle pathForResource:@"linphonerc-factory" ofType:nil];
    if (!factoryPath) {
      factoryPath = [[NSBundle mainBundle] pathForResource:@"linphonerc-factory"
                                                    ofType:nil];
    }
    NSLog(@"[LinphoneManager] Factory path: %@", factoryPath ?: @"MISSING");

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *configPath = [documentsDirectory
        stringByAppendingPathComponent:@"linphonerc_standalone"];
    NSLog(@"[LinphoneManager] Config path: %@", configPath);

    const char *c_configPath = configPath.UTF8String;
    const char *c_factoryPath = factoryPath ? factoryPath.UTF8String : NULL;

    LinphoneConfig *config = NULL;
    if (c_factoryPath != NULL) {
      NSLog(@"[LinphoneManager] Creating config with factory path...");
      config = linphone_factory_create_config_with_factory(
          factory, c_configPath, c_factoryPath);
    } else {
      NSLog(@"[LinphoneManager] Warning: Factory path missing, creating "
            @"standard config");
      config = linphone_factory_create_config(factory, c_configPath);
    }

    if (!config) {
      NSLog(@"[LinphoneManager] FATAL ERROR: Failed to create LinphoneConfig "
            @"object.");
      return;
    }
    NSLog(@"[LinphoneManager] Config created at: %p", config);

    linphone_config_set_int(config, "misc", "max_calls", 1);

    // Align with native app storage paths
    [self lpConfigSetString:config
                      value:[LinphoneManager dataFile:@"linphone.db"]
                     forKey:@"uri"
                  inSection:@"storage"];
    [self lpConfigSetString:config
                      value:[LinphoneManager dataFile:@"x3dh.c25519.sqlite3"]
                     forKey:@"x3dh_db_path"
                  inSection:@"lime"];

    linphone_config_set_string(config, "sip", "linphone_specs", "groupchat");
    linphone_config_set_int(config, "app", "publish_presence", 0);
    linphone_config_set_int(config, "sip", "publish_presence", 0);
    linphone_config_set_string(config, "sip", "save_headers", "To, Diversion, Contact, X-Voicemail");


    // 🛡️ API Fix: linphone_factory_create_core_with_config_3 is the correct
    // modern API.
    NSLog(@"[LinphoneManager] Attempting to create core with correct API "
          @"(v3)...");
    theLinphoneCore =
        linphone_factory_create_core_with_config_3(factory, config, NULL);

    if (theLinphoneCore) {
      NSLog(@"[LinphoneManager] Core created successfully at: %p",
            theLinphoneCore);

      linphone_core_enable_video_capture(theLinphoneCore, TRUE);
      linphone_core_enable_video_display(theLinphoneCore, TRUE);

      LinphoneVideoActivationPolicy *videoPolicy =
          linphone_factory_create_video_activation_policy(factory);
      linphone_video_activation_policy_set_automatically_initiate(videoPolicy,
                                                                  TRUE);
      linphone_video_activation_policy_set_automatically_accept(videoPolicy,
                                                                TRUE);
      linphone_core_set_video_activation_policy(theLinphoneCore, videoPolicy);
      linphone_video_activation_policy_unref(videoPolicy);
      // ==========================================================

      // Keep alive is essential for background stability
      linphone_core_enable_keep_alive(theLinphoneCore, true);

      LinphoneCoreCbs *cbs = linphone_factory_create_core_cbs(factory);
      linphone_core_cbs_set_registration_state_changed(
          cbs, linphone_iphone_registration_state);
      linphone_core_cbs_set_global_state_changed(
          cbs, linphone_iphone_global_state_changed);
      linphone_core_cbs_set_authentication_requested(
          cbs, linphone_iphone_popup_password_request);
      linphone_core_cbs_set_user_data(cbs, (__bridge void *)(self));
      linphone_core_cbs_set_call_state_changed(cbs, linphone_iphone_call_state);
      linphone_core_cbs_set_audio_device_changed(cbs, linphone_iphone_audio_device_changed);
      linphone_core_cbs_set_audio_devices_list_updated(cbs, linphone_iphone_audio_devices_list_updated);
      linphone_core_cbs_set_message_received(cbs, linphone_iphone_message_received);
      linphone_core_cbs_set_info_received(cbs, linphone_iphone_info_received);
      // Note: linphone_core_cbs_set_chat_message_state_changed does not exist on CoreCbs.
      // Message state changes are typically set on individual LinphoneChatMessage objects.
      // linphone_core_cbs_set_chat_message_state_changed(cbs, linphone_iphone_chat_message_state_changed);

      linphone_core_add_callbacks(theLinphoneCore, cbs);

      NSLog(@"[LinphoneManager] Starting core...");
      linphone_core_start(theLinphoneCore);

      [self startIterateTimer];
      NSLog(@"[LinphoneManager] Core started and timer running!");
    } else {
      NSLog(@"[LinphoneManager] FATAL ERROR: "
            @"linphone_factory_create_core_with_config returned NULL!");
    }

    if (config)
      linphone_config_unref(config);
  });
}

+ (LinphoneCore *)getLc {
  return theLinphoneCore;
}

- (void)onRegister:(LinphoneCore *)lc
               cfg:(LinphoneProxyConfig *)cfg
             state:(LinphoneRegistrationState)state
           message:(const char *)cmessage {
  NSLog(@"[LinphoneManager] onRegister state: %s, message: %s",
        linphone_registration_state_to_string(state), cmessage ?: "");

  LinphoneReason reason = linphone_proxy_config_get_error(cfg);
  NSString *errorMessage = @"";

  if (state == LinphoneRegistrationFailed) {
    switch (reason) {
    case LinphoneReasonBadCredentials:
      errorMessage = @"Bad credentials, check your account settings";
      break;
    case LinphoneReasonNoResponse:
      errorMessage = @"No response received from remote";
      break;
    case LinphoneReasonIOError:
      errorMessage =
          @"Cannot reach the server. Check your internet connection.";
      break;
    case LinphoneReasonUnauthorized:
      errorMessage = @"Operation is unauthorized";
      break;
    case LinphoneReasonNotFound:
      errorMessage = @"User not found on the server";
      break;
    default:
      errorMessage = [NSString
          stringWithUTF8String:cmessage ?: "Unknown registration error"];
      break;
    }
    NSLog(@"[LinphoneManager] Registration FAILED with reason: %d (%@)", reason,
          errorMessage);
  }

  NSDictionary *dict = @{
    @"state" : @(state),
    @"reason" : @(reason),
    @"message" : errorMessage
        ?: (cmessage ? [NSString stringWithUTF8String:cmessage] : @"")
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

static void linphone_iphone_global_state_changed(LinphoneCore *lc,
                                                 LinphoneGlobalState state,
                                                 const char *message) {
  NSLog(@"[LinphoneManager] Global state changed: %d (%s)", state,
        message ?: "");
}

static void linphone_iphone_popup_password_request(LinphoneCore *lc,
                                                   LinphoneAuthInfo *auth_info,
                                                   LinphoneAuthMethod method) {
  const char *username = linphone_auth_info_get_username(auth_info);
  const char *domain = linphone_auth_info_get_domain(auth_info);
  NSLog(@"[LinphoneManager] Authentication requested (password rejected) for "
        @"%s@%s",
        username, domain);

  // In a bridge context, we notify the JS layer that authentication failed
  LinphoneManager *manager =
      (__bridge LinphoneManager *)linphone_core_cbs_get_user_data(
          linphone_core_get_current_callbacks(lc));
  [manager onRegister:lc
                  cfg:NULL
                state:LinphoneRegistrationFailed
              message:"Bad Credentials/Authentication Requested"];
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

- (void)registerSipWithUsername:(NSString *)username
                       password:(NSString *)password
                         domain:(NSString *)domain
                      transport:(NSString *)transport {
  NSLog(@"[LinphoneManager] Incoming Register Request (Modern API): "
        @"username=%@, domain=%@, transport=%@",
        username, domain, transport);

  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore) {
      NSLog(@"[LinphoneManager] CRITICAL: Cannot register, theLinphoneCore is NULL. Attempting to initialize...");
      [self createLinphoneCore];
      // We can't proceed immediately because createLinphoneCore is async on main queue
      return;
    }

    NSLog(@"[LinphoneManager] Starting Modern Account Registration on Main "
          @"Thread");

    // 1. Create Account Params
    LinphoneAccountParams *params =
        linphone_core_create_account_params(theLinphoneCore);

    // 2. Set Identity (sip:user@domain)
    NSString *identityStr =
        [NSString stringWithFormat:@"sip:%@@%@", username, domain];
    LinphoneAddress *identity = linphone_address_new(identityStr.UTF8String);
    if (!identity) {
      NSLog(@"[LinphoneManager] FAILED: Could not create identity address: %@",
            identityStr);
      linphone_account_params_unref(params);
      return;
    }
    linphone_account_params_set_identity_address(params, identity);
    NSLog(@"[LinphoneManager] Identity set: %@", identityStr);

    // 3. Set Server Address (sip:domain)
    LinphoneAddress *server = linphone_address_new(
        [NSString stringWithFormat:@"sip:%@", domain].UTF8String);
    if (server) {
      linphone_account_params_set_server_address(params, server);
      NSLog(@"[LinphoneManager] Server address set: %@", domain);
      linphone_address_unref(server);
    }

    // 4. Handle Transport
    LinphoneTransportType transportType = LinphoneTransportUdp;
    NSString *tStr = [transport lowercaseString];
    if ([tStr isEqualToString:@"tcp"])
      transportType = LinphoneTransportTcp;
    else if ([tStr isEqualToString:@"tls"])
      transportType = LinphoneTransportTls;

    linphone_account_params_set_transport(params, transportType);
    linphone_account_params_enable_register(params, TRUE);

    // 5. Create Auth Info
    NSString *host = domain;
    if ([domain containsString:@":"]) {
      host = [domain componentsSeparatedByString:@":"][0];
    }

    LinphoneAuthInfo *info =
        linphone_auth_info_new(username.UTF8String, NULL, password.UTF8String,
                               NULL, NULL, host.UTF8String);
    if (info) {
      linphone_core_add_auth_info(theLinphoneCore, info);
      NSLog(@"[LinphoneManager] Auth info added for user: %@, realm: %@",
            username, host);
      linphone_auth_info_unref(info);
    }

    // 6. Create and Add Account
    LinphoneAccount *account =
        linphone_core_create_account(theLinphoneCore, params);
    if (account) {
      linphone_core_add_account(theLinphoneCore, account);
      linphone_core_set_default_account(theLinphoneCore, account);
      NSLog(@"[LinphoneManager] SUCCESS: Modern Account created and set as "
            @"default");
    } else {
      NSLog(@"[LinphoneManager] FAILED: Could not create account from params");
    }

    // Clean up
    linphone_address_unref(identity);
    linphone_account_params_unref(params);
  });
}

- (NSString *)accountList {
  if (!theLinphoneCore) return @"[]";
  NSMutableArray *usernames = [NSMutableArray array];
  const bctbx_list_t *accounts = linphone_core_get_account_list(theLinphoneCore);
  for (const bctbx_list_t *it = accounts; it != NULL; it = it->next) {
    LinphoneAccount *acc = (LinphoneAccount *)it->data;
    const LinphoneAddress *addr = linphone_account_params_get_identity_address(
        linphone_account_get_params(acc));
    const char *user = addr ? linphone_address_get_username(addr) : NULL;
    [usernames addObject:user ? [NSString stringWithUTF8String:user] : @""];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:usernames options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
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



// ==========================================
- (void)setDefaultAccountSync:(NSInteger)index phoneNumber:(NSString *)phoneNumber {
    const bctbx_list_t *accounts = linphone_core_get_account_list(theLinphoneCore);
    LinphoneAccount *acc = (LinphoneAccount *)bctbx_list_nth_data(accounts, (int)index);
    if (acc) {
        const LinphoneAddress *addr = linphone_account_params_get_identity_address(linphone_account_get_params(acc));
        if (addr) {
            NSString *username = [NSString stringWithUTF8String:linphone_address_get_username(addr)];
            if ([username isEqualToString:phoneNumber]) {
                linphone_core_set_default_account(theLinphoneCore, acc);
                NSLog(@"[LinphoneManager] setDefaultAccountSync: %@", phoneNumber);
            }
        }
    }
}

- (void)setDefaultAccount:(NSInteger)index phoneNumber:(NSString *)phoneNumber {
    if (!theLinphoneCore) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setDefaultAccountSync:index phoneNumber:phoneNumber];
    });
}
- (NSString *)updateCurrentLoginTypeFromAccount {
  if (!theLinphoneCore) return @"";
  
  LinphoneAccount *defaultAccount = linphone_core_get_default_account(theLinphoneCore);
  if (defaultAccount) {
    LinphoneAccountParams *params = (LinphoneAccountParams *)linphone_account_get_params(defaultAccount);
    const char *contactParams = linphone_account_params_get_contact_uri_parameters(params);
    
    NSString *type = @"";
    if (contactParams) {
      NSString *paramsStr = [NSString stringWithUTF8String:contactParams];
      NSArray *parts = [paramsStr componentsSeparatedByString:@";"];
      for (NSString *part in parts) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"app-login-type="]) {
          type = [[trimmed componentsSeparatedByString:@"="] lastObject];
          break;
        }
      }
    }
    
    NSLog(@"[LinphoneManager] updateCurrentLoginTypeFromAccount: type=%@", type);
    return type;
  }
  return @"";
}

// MARK: - Call Management & History
// ==========================================

- (void)startCall:(NSString *)phoneNumber {
  NSLog(@"[LinphoneManager] 📞 กำลังเตรียมโทรหา: %@", phoneNumber);

  if (!theLinphoneCore) {
    NSLog(@"[LinphoneManager] ❌ theLinphoneCore is NULL! (โทรไม่ได้)");
    return;
  }

  LinphoneAddress *address =
      linphone_core_interpret_url(theLinphoneCore, [phoneNumber UTF8String]);
  if (!address) {
    NSLog(
        @"[LinphoneManager] ❌ FATAL: แปลงเบอร์/URL ไม่สำเร็จ! เบอร์อาจจะผิดฟอร์แมต");
    return;
  }

  char *addrStr = linphone_address_as_string(address);
  NSLog(@"[LinphoneManager] ✅ SIP Address ที่จะได้โทรออกคือ: %s", addrStr);
  ms_free(addrStr);

  LinphoneCallParams *params =
      linphone_core_create_call_params(theLinphoneCore, NULL);
  linphone_call_params_enable_video(params, FALSE);

  LinphoneCall *call = linphone_core_invite_address_with_params(
      theLinphoneCore, address, params);

  if (call) {
    NSLog(@"[LinphoneManager] 🚀 สร้าง Call Object สำเร็จ! ส่ง INVITE แล้ว");
  } else {
    NSLog(@"[LinphoneManager] ❌ FATAL: "
          @"linphone_core_invite_address_with_params ล้มเหลว!");
  }

  linphone_address_unref(address);
  linphone_call_params_unref(params);
}

- (NSInteger)callsCount {
  if (!theLinphoneCore)
    return 0;
  return bctbx_list_size(linphone_core_get_calls(theLinphoneCore));
}

- (NSString *)convertCallStateToString:(LinphoneCallState)state {
  switch (state) {
  case LinphoneCallIdle:
    return @"Idle";
  case LinphoneCallIncomingReceived:
  case LinphoneCallIncomingEarlyMedia:
    return @"IncomingCall";
  case LinphoneCallOutgoingInit:
    return @"CallOutgoing";
  case LinphoneCallOutgoingProgress:
    return @"StartCall";
  case LinphoneCallOutgoingRinging:
    return @"StartCall";
  case LinphoneCallOutgoingEarlyMedia:
    return @"StartCall";
  case LinphoneCallConnected:
    return @"Connected";
  case LinphoneCallStreamsRunning:
    return @"StreamsRunning";
  case LinphoneCallPausing:
    return @"Pause";
  case LinphoneCallPaused:
    return @"Pause";
  case LinphoneCallResuming:
    return @"Resuming";
  case LinphoneCallError:
    return @"Error";
  case LinphoneCallEnd:
    return @"CallEnd";
  case LinphoneCallReleased:
    return @"CallEnd";
  default:
    return @"Unknown";
  }
}

- (NSString *)getCallingLogsJSON {
  if (!theLinphoneCore)
    return @"[]";
  NSMutableArray *logs = [NSMutableArray array];
  const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);

  for (const bctbx_list_t *it = calls; it != NULL; it = it->next) {
    LinphoneCall *call = (LinphoneCall *)it->data;
    const LinphoneAddress *addr = linphone_call_get_remote_address(call);
    NSString *phone =
        addr
            ? [NSString stringWithUTF8String:linphone_address_get_username(addr)
                                                 ?: ""]
            : @"";
    NSString *name =
        addr ? [NSString
                   stringWithUTF8String:linphone_address_get_display_name(addr)
                                            ?: ""]
             : @"";
    int duration = linphone_call_get_duration(call);
    LinphoneCallState state = linphone_call_get_state(call);
    BOOL isPaused =
        (state == LinphoneCallPaused || state == LinphoneCallPausing ||
         state == LinphoneCallPausedByRemote);
    NSString *jsState = [self convertCallStateToString:state];

    [logs addObject:@{
      @"callID" : phone,
      @"phoneNumber" : phone,
      @"name" : name,
      @"isPaused" : isPaused ? @YES : @NO,
      @"duration" : [@(duration) stringValue],
      @"status" : jsState ? jsState : @"Unknown"
    }];
  }
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:logs
                                                     options:0
                                                       error:nil];
  return jsonData ? [[NSString alloc] initWithData:jsonData
                                          encoding:NSUTF8StringEncoding]
                   : @"[]";
}

- (NSString *)getHistoryCallLogsJSON {
    if (!theLinphoneCore) return @"[]";
    NSMutableArray *logs = [NSMutableArray array];
    const bctbx_list_t *history = linphone_core_get_call_logs(theLinphoneCore);
    
    for (const bctbx_list_t *it = history; it != NULL; it = it->next) {
        LinphoneCallLog *log = (LinphoneCallLog *)it->data;
        const LinphoneAddress *addr = linphone_call_log_get_remote_address(log);
        NSString *phone = addr ? [NSString stringWithUTF8String:linphone_address_get_username(addr) ?: ""] : @"";
        NSString *name = addr ? [NSString stringWithUTF8String:linphone_address_get_display_name(addr) ?: ""] : @"";
        
        [logs addObject:@{
            @"callID": linphone_call_log_get_call_id(log) ? [NSString stringWithUTF8String:linphone_call_log_get_call_id(log)] : @"",
            @"phoneNumber": phone,
            @"name": name,
            @"duration": [@(linphone_call_log_get_duration(log)) stringValue],
            @"status": [self convertCallStateToString:linphone_call_log_get_status(log)] ?: @"Unknown",
            @"timestamp": @(linphone_call_log_get_start_date(log))
        }];
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:logs options:0 error:nil];
    return jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[]";
}

- (NSString *)getMissedCallLogsJSON {
    if (!theLinphoneCore) return @"[]";
    NSMutableArray *logs = [NSMutableArray array];
    const bctbx_list_t *history = linphone_core_get_call_logs(theLinphoneCore);
    
    for (const bctbx_list_t *it = history; it != NULL; it = it->next) {
        LinphoneCallLog *log = (LinphoneCallLog *)it->data;
        if (linphone_call_log_get_status(log) == LinphoneCallMissed) {
            const LinphoneAddress *addr = linphone_call_log_get_remote_address(log);
            NSString *phone = addr ? [NSString stringWithUTF8String:linphone_address_get_username(addr) ?: ""] : @"";
            NSString *name = addr ? [NSString stringWithUTF8String:linphone_address_get_display_name(addr) ?: ""] : @"";
            
            [logs addObject:@{
                @"callID": linphone_call_log_get_call_id(log) ? [NSString stringWithUTF8String:linphone_call_log_get_call_id(log)] : @"",
                @"phoneNumber": phone,
                @"name": name,
                @"duration": [@(linphone_call_log_get_duration(log)) stringValue],
                @"status": @"MissCall",
                @"timestamp": @(linphone_call_log_get_start_date(log))
            }];
        }
    }
    
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:logs options:0 error:nil];
    return jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : @"[]";
}

- (void)hangUp {
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (call)
    linphone_call_terminate(call);
}

- (void)hangUpAll {
  if (!theLinphoneCore) return;
  linphone_core_terminate_all_calls(theLinphoneCore);
}

- (void)terminateAllCalls {
    [self hangUpAll];
}

- (void)terminateCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone {
  const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
  for (const bctbx_list_t *it = calls; it != NULL; it = it->next) {
    LinphoneCall *call = (LinphoneCall *)it->data;
    const LinphoneAddress *addr = linphone_call_get_remote_address(call);
    if (addr &&
        [[NSString stringWithUTF8String:linphone_address_get_username(addr)
                                            ?: ""] isEqualToString:phone]) {
      linphone_call_terminate(call);
      break;
    }
  }
}

- (void)resumeCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone {
  const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
  for (const bctbx_list_t *it = calls; it != NULL; it = it->next) {
    LinphoneCall *call = (LinphoneCall *)it->data;
    const LinphoneAddress *addr = linphone_call_get_remote_address(call);
    if (addr &&
        [[NSString stringWithUTF8String:linphone_address_get_username(addr)
                                            ?: ""] isEqualToString:phone]) {
      linphone_call_resume(call);
      break;
    }
  }
}

- (int)getDurationTime {
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  return call ? linphone_call_get_duration(call) : 0;
}

- (int)getDurationByAddress:(NSString *)address {
  const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
  for (const bctbx_list_t *it = calls; it != NULL; it = it->next) {
    LinphoneCall *call = (LinphoneCall *)it->data;
    const LinphoneAddress *addr = linphone_call_get_remote_address(call);
    if (addr &&
        [[NSString stringWithUTF8String:linphone_address_get_username(addr)
                                            ?: ""] isEqualToString:address]) {
      return linphone_call_get_duration(call);
    }
  }
  return 0;
}

- (BOOL)isInConference {
  return linphone_core_get_conference(theLinphoneCore) != NULL;
}

- (void)pauseCallAtIndex:(NSInteger)index phoneNumber:(NSString *)phone {
  if (!theLinphoneCore) return;
  const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
  LinphoneCall *call = (LinphoneCall *)bctbx_list_nth_data(calls, (int)index);
  if (call) linphone_call_pause(call);
}

- (void)startConference {
  linphone_core_add_to_conference(
      theLinphoneCore, linphone_core_get_current_call(theLinphoneCore));
}

- (void)splitConference {
  linphone_core_leave_conference(theLinphoneCore);
}

- (void)dtmfKeypad:(NSString *)numberDtmf key:(NSString *)key {
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (call && key.length > 0) {
    linphone_call_send_dtmf(call, [key characterAtIndex:0]);
  }
}

- (void)applySmartPlaybackGain:(BOOL)isExtension {
  linphone_core_set_playback_gain_db(theLinphoneCore,
                                     isExtension ? 0.0f : 6.0f);
}

- (void)setPlaybackGain:(NSString *)gain {
  linphone_core_set_playback_gain_db(theLinphoneCore, [gain floatValue]);
}

- (BOOL)getEchoCancellation {
  return theLinphoneCore ? linphone_core_echo_cancellation_enabled(theLinphoneCore) : NO;
}

- (void)setEchoCancellationEnabled:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_enable_echo_cancellation(theLinphoneCore, enabled);
}

- (BOOL)getAdaptiveRateControl {
  return theLinphoneCore ? linphone_core_adaptive_rate_control_enabled(theLinphoneCore) : NO;
}

- (void)setAdaptiveRateControlEnabled:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_enable_adaptive_rate_control(theLinphoneCore, enabled);
}

- (float)getMicrophoneGainDb {
  return theLinphoneCore ? linphone_core_get_mic_gain_db(theLinphoneCore) : 0.0f;
}

- (void)setMicrophoneGainDb:(float)gain {
  if (theLinphoneCore) linphone_core_set_mic_gain_db(theLinphoneCore, gain);
}

- (float)getPlaybackGainDb {
  return theLinphoneCore ? linphone_core_get_playback_gain_db(theLinphoneCore) : 0.0f;
}

- (int)getCodecBitrateKbps {
  if (!theLinphoneCore) return 0;
  static const int kAllowedBitrates[] = {10, 15, 20, 36, 64, 128};
  static const int kCount = 6;
  const bctbx_list_t *it = linphone_core_get_audio_payload_types(theLinphoneCore);
  for (; it != NULL; it = it->next) {
    LinphonePayloadType *pt = (LinphonePayloadType *)it->data;
    if (!linphone_payload_type_is_vbr(pt)) continue;
    int br = linphone_payload_type_get_normal_bitrate(pt);
    for (int i = 0; i < kCount; i++) {
      if (kAllowedBitrates[i] == br) return br;
    }
  }
  return 0;
}

- (void)setCodecBitrateKbps:(int)kbps {
  if (!theLinphoneCore) return;
  const bctbx_list_t *it = linphone_core_get_audio_payload_types(theLinphoneCore);
  for (; it != NULL; it = it->next) {
    LinphonePayloadType *pt = (LinphonePayloadType *)it->data;
    if (linphone_payload_type_is_vbr(pt)) {
      linphone_payload_type_set_normal_bitrate(pt, kbps);
    }
  }
}

- (NSString *)getCodecsListJSON {
  if (!theLinphoneCore) return @"[]";
  NSMutableArray *list = [NSMutableArray array];
  const bctbx_list_t *it = linphone_core_get_audio_payload_types(theLinphoneCore);
  for (; it != NULL; it = it->next) {
    LinphonePayloadType *pt = (LinphonePayloadType *)it->data;
    const char *mime = linphone_payload_type_get_mime_type(pt);
    int clock = linphone_payload_type_get_clock_rate(pt);
    BOOL enabled = linphone_payload_type_enabled(pt);
    [list addObject:@{
      @"mimeType": mime ? @(mime) : @"",
      @"clockRate": [@(clock) stringValue],
      @"value": @(enabled)
    }];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

// ── Ringtone / Vibrate ────────────────────────────────────────────────────

- (BOOL)getDeviceRingtone {
  return theLinphoneCore ? linphone_core_get_ring(theLinphoneCore) == NULL : NO;
}

- (void)setDeviceRingtone:(BOOL)useDevice {
  if (!theLinphoneCore) return;
  linphone_core_set_ring(theLinphoneCore, useDevice ? NULL : "");
}

- (BOOL)getVibrateOnIncomingCall {
  return theLinphoneCore ? linphone_core_is_vibration_on_incoming_call_enabled(theLinphoneCore) : NO;
}

- (void)setVibrateOnIncomingCallEnabled:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_enable_vibration_on_incoming_call(theLinphoneCore, enabled);
}

// ── Encryption ────────────────────────────────────────────────────────────

- (NSString *)getMediaEncryptionName {
  if (!theLinphoneCore) return @"None";
  switch (linphone_core_get_media_encryption(theLinphoneCore)) {
    case LinphoneMediaEncryptionSRTP: return @"SRTP";
    case LinphoneMediaEncryptionZRTP: return @"ZRTP";
    case LinphoneMediaEncryptionDTLS: return @"DTLS";
    default: return @"None";
  }
}

- (BOOL)getEncryptionMandatory {
  return theLinphoneCore ? linphone_core_is_media_encryption_mandatory(theLinphoneCore) : NO;
}

- (void)setEncryptionMandatory:(BOOL)mandatory {
  if (theLinphoneCore) linphone_core_set_media_encryption_mandatory(theLinphoneCore, mandatory);
}

// ── DTMF ──────────────────────────────────────────────────────────────────

- (BOOL)getSipInfoDtmf {
  return theLinphoneCore ? linphone_core_get_use_info_for_dtmf(theLinphoneCore) : NO;
}

- (void)setSipInfoDtmf:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_set_use_info_for_dtmf(theLinphoneCore, enabled);
}

- (BOOL)getUseRfc2833ForDtmf {
  return theLinphoneCore ? linphone_core_get_use_rfc2833_for_dtmf(theLinphoneCore) : YES;
}

- (void)setUseRfc2833ForDtmf:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_set_use_rfc2833_for_dtmf(theLinphoneCore, enabled);
}

// ── Call Behaviour ────────────────────────────────────────────────────────

- (int)getIncomingTimeout {
  return theLinphoneCore ? linphone_core_get_inc_timeout(theLinphoneCore) : 30;
}

- (void)setIncomingTimeout:(int)seconds {
  if (theLinphoneCore) linphone_core_set_inc_timeout(theLinphoneCore, seconds);
}

// ── Network ───────────────────────────────────────────────────────────────

- (BOOL)getWifiOnly {
  return theLinphoneCore ? linphone_core_wifi_only_enabled(theLinphoneCore) : NO;
}

- (void)setWifiOnly:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_enable_wifi_only(theLinphoneCore, enabled);
}

- (BOOL)getAllowIpv6 {
  return theLinphoneCore ? linphone_core_ipv6_enabled(theLinphoneCore) : NO;
}

- (void)setAllowIpv6:(BOOL)enabled {
  if (theLinphoneCore) linphone_core_enable_ipv6(theLinphoneCore, enabled);
}

- (BOOL)getRandomPorts {
  if (!theLinphoneCore) return NO;
  const LinphoneTransports *t = linphone_core_get_transports(theLinphoneCore);
  int udp = linphone_transports_get_udp_port(t);
  int tcp = linphone_transports_get_tcp_port(t);
  return udp == -1 || (udp == 0 && tcp == -1);
}

- (void)setRandomPorts:(BOOL)random {
  if (!theLinphoneCore) return;
  int port = random ? -1 : 5060;
  LinphoneTransports *t = linphone_factory_create_transports(linphone_factory_get());
  linphone_transports_set_udp_port(t, port);
  linphone_transports_set_tcp_port(t, port);
  linphone_transports_set_tls_port(t, -1);
  linphone_core_set_transports(theLinphoneCore, t);
  linphone_transports_unref(t);
}

- (int)getJitterBuffer {
  return theLinphoneCore ? linphone_core_get_audio_jittcomp(theLinphoneCore) : 0;
}

- (void)setJitterBuffer:(int)ms {
  if (!theLinphoneCore) return;
  linphone_core_set_audio_jittcomp(theLinphoneCore, ms);
  linphone_core_enable_audio_adaptive_jittcomp(theLinphoneCore, ms == 999);
}

// ── Logging ───────────────────────────────────────────────────────────────

- (NSString *)getLogsUploadServerURL {
  if (!theLinphoneCore) return @"";
  const char *url = linphone_core_get_log_collection_upload_server_url(theLinphoneCore);
  return url ? @(url) : @"";
}

- (void)setLogsUploadServerURL:(NSString *)url {
  if (theLinphoneCore) {
    linphone_core_set_log_collection_upload_server_url(theLinphoneCore, [url UTF8String]);
  }
}

// ── Echo Calibration / Tester ─────────────────────────────────────────────

- (void)startEchoCancellerCalibration {
  if (theLinphoneCore) linphone_core_start_echo_canceller_calibration(theLinphoneCore);
}

- (void)toggleEchoTester {
  if (!theLinphoneCore) return;
  if (_echoTesterRunning) {
    linphone_core_stop_echo_tester(theLinphoneCore);
    _echoTesterRunning = NO;
  } else {
    linphone_core_start_echo_tester(theLinphoneCore, 0);
    _echoTesterRunning = YES;
  }
}

// ==========================================
// MARK: - Audio Hardware
// ==========================================

- (BOOL)isSpeakerEnabled {
  AVAudioSessionRouteDescription *route =
      [[AVAudioSession sharedInstance] currentRoute];
  for (AVAudioSessionPortDescription *desc in [route outputs]) {
    if ([[desc portType] isEqualToString:AVAudioSessionPortBuiltInSpeaker])
      return YES;
  }
  return NO;
}

- (void)toggleSpeaker {
  // Use the Linphone audio device API exclusively — AVAudioSession overrides conflict
  // with linphone_call_set_output_audio_device used in routeAudioTo* methods.
  if ([self isSpeakerEnabled]) {
    [self routeAudioToEarpiece];
  } else {
    [self routeAudioToSpeaker];
  }
  [[NSNotificationCenter defaultCenter] postNotificationName:@"dataFromAudio"
                                                      object:nil];
}

- (BOOL)isMicMuted {
  return !linphone_core_mic_enabled(theLinphoneCore);
}

- (BOOL)toggleMute {
  BOOL currentMute = !linphone_core_mic_enabled(theLinphoneCore);
  linphone_core_enable_mic(theLinphoneCore, currentMute);
  return !linphone_core_mic_enabled(theLinphoneCore);
}

- (BOOL)isBluetoothAudioRouteAvailable {
  if (!theLinphoneCore) return NO;
  const bctbx_list_t *devices = linphone_core_get_audio_devices(theLinphoneCore);
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    if (linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeBluetooth) {
      return YES;
    }
  }
  return NO;
}

- (BOOL)isBluetoothState {
  if (!theLinphoneCore) return NO;
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (!call) return NO;
  LinphoneAudioDevice *dev = linphone_call_get_output_audio_device(call);
  if (dev && linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeBluetooth) {
    return YES;
  }
  return NO;
}

- (void)routeAudioToSpeaker {
  if (!theLinphoneCore) return;
  LinphoneAudioDevice *speaker = NULL;
  const bctbx_list_t *devices = linphone_core_get_audio_devices(theLinphoneCore);
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    if (linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeSpeaker) {
      speaker = dev;
      break;
    }
  }
  if (speaker) {
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
      linphone_call_set_output_audio_device(call, speaker);
    } else {
      linphone_core_set_output_audio_device(theLinphoneCore, speaker);
    }
  }
}

- (void)routeAudioToEarpiece {
  if (!theLinphoneCore) return;
  LinphoneAudioDevice *earpiece = NULL;
  const bctbx_list_t *devices = linphone_core_get_audio_devices(theLinphoneCore);
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    if (linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeEarpiece) {
      earpiece = dev;
      break;
    }
  }
  if (earpiece) {
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
      linphone_call_set_output_audio_device(call, earpiece);
    } else {
      linphone_core_set_output_audio_device(theLinphoneCore, earpiece);
    }
  }
}

- (void)routeAudioToBluetooth {
  if (!theLinphoneCore) return;
  LinphoneAudioDevice *bluetooth = NULL;
  const bctbx_list_t *devices = linphone_core_get_audio_devices(theLinphoneCore);
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    if (linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeBluetooth) {
      bluetooth = dev;
      break;
    }
  }
  if (bluetooth) {
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
      linphone_call_set_output_audio_device(call, bluetooth);
    } else {
      linphone_core_set_output_audio_device(theLinphoneCore, bluetooth);
    }
  }
}

- (void)pauseCall {
  if (!theLinphoneCore) return;
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (call) linphone_call_pause(call);
}

- (NSString *)destinationUsername {
  if (!theLinphoneCore) return @"";
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (!call) return @"";
  const LinphoneAddress *addr = linphone_call_get_remote_address(call);
  if (!addr) return @"";
  const char *username = linphone_address_get_username(addr);
  return username ? [NSString stringWithUTF8String:username] : @"";
}

- (int)missedCallsCount {
  if (!theLinphoneCore) return 0;
  return linphone_core_get_missed_calls_count(theLinphoneCore);
}

- (void)transferCallNow:(NSString *)phoneNumber {
    if (!theLinphoneCore) return;
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
        linphone_call_transfer(call, [phoneNumber UTF8String]);
    }
}

- (void)transferCallAskFirst:(NSString *)phoneNumber {
    // Basic implementation to match Android's logic if possible
    [self transferCallNow:phoneNumber];
}

// ==========================================
// MARK: - Call Event Bridge
// ==========================================

static void linphone_iphone_call_state(LinphoneCore *lc, LinphoneCall *call,
                                        LinphoneCallState state,
                                        const char *message) {
  LinphoneManager *manager = [LinphoneManager sharedInstance];
  NSString *stateStr = [manager convertCallStateToString:state];
  NSString *msgStr = message ? [NSString stringWithUTF8String:message] : @"";

  // Voicemail Detection via SIP Headers (Logic from Android)
  if (state == LinphoneCallOutgoingEarlyMedia || state == LinphoneCallOutgoingProgress || 
      state == LinphoneCallConnected || state == LinphoneCallStreamsRunning) {
      
      const LinphoneCallParams *params = linphone_call_get_params(call);
      if (linphone_call_get_dir(call) == LinphoneCallOutgoing && 
          linphone_call_params_video_enabled(params)) {
          
          const LinphoneCallParams *remoteParams = linphone_call_get_remote_params(call);
          if (remoteParams) {
              const char *diversion = linphone_call_params_get_custom_header(remoteParams, "Diversion");
              const char *contact = linphone_call_params_get_custom_header(remoteParams, "Contact");
              const char *xVoicemail = linphone_call_params_get_custom_header(remoteParams, "X-Voicemail");
              
              BOOL isVoicemail = NO;
              if (diversion && (strcasestr(diversion, "voicemail") || strcasestr(diversion, "vmail"))) isVoicemail = YES;
              if (contact && (strcasestr(contact, "voicemail") || strcasestr(contact, "vmail"))) isVoicemail = YES;
              if (xVoicemail && strcasecmp(xVoicemail, "yes") == 0) isVoicemail = YES;
              
              if (isVoicemail) {
                  NSLog(@"[LinphoneManager] Voicemail detected via SIP headers. Terminating call.");
                  linphone_call_terminate(call);
                  
                  // Emit as MissCall to match Android behavior
                  NSDictionary *dict = @{@"stateString": @"MissCall", @"message": @"Voicemail detected"};
                  [[NSNotificationCenter defaultCenter] postNotificationName:kLinphoneCallStateUpdate object:nil userInfo:dict];
                  return;
              }
          }
      }
  }
  
  // Remote Video State Monitoring — mirrors Android's lastRemoteCameraOnState dedup.
  // Skip during LinphoneCallUpdating: remote params reflect mid-negotiation SDP which
  // may temporarily show a stale direction, causing a spurious isRemoteCameraOn=NO event
  // that hides the remote view (black flash). LinphoneCallUpdatedByRemote fires after
  // negotiation is complete, so that state is safe to read.
  if (state == LinphoneCallStreamsRunning || state == LinphoneCallUpdatedByRemote) {
      const LinphoneCallParams *remoteParams = linphone_call_get_remote_params(call);
      if (remoteParams) {
          BOOL isRemoteVideoEnabled = linphone_call_params_video_enabled(remoteParams);
          LinphoneMediaDirection dir = linphone_call_params_get_video_direction(remoteParams);
          BOOL isSendingVideo = isRemoteVideoEnabled &&
              (dir == LinphoneMediaDirectionSendOnly || dir == LinphoneMediaDirectionSendRecv);
          int newState = isSendingVideo ? 1 : 0;

          // Only fire when value changed — prevents toggling display:none on the remote view
          // during re-INVITEs where the remote camera state is actually unchanged.
          if (newState != manager->_lastRemoteCameraOnState) {
              NSLog(@"[LinphoneManager] onRemoteVideoStateChanged: %d (was %d, state=%d)",
                    isSendingVideo, manager->_lastRemoteCameraOnState, state);
              manager->_lastRemoteCameraOnState = newState;
              [[NSNotificationCenter defaultCenter] postNotificationName:kLinphoneRemoteVideoStateUpdate
                                                                  object:nil
                                                                userInfo:@{@"enabled": @(isSendingVideo)}];
          }
      }
  }

  // Reset remote camera tracking on call tear-down (End, Error, Released).
  // Matches Android: lastRemoteCameraOnState = null on End + Released + Error.
  if (state == LinphoneCallEnd || state == LinphoneCallError || state == LinphoneCallReleased) {
      manager->_lastRemoteCameraOnState = -1;
  }

  // Re-enable mic if the last call ended while muted — mirrors Android onLastCallEnded.
  if (state == LinphoneCallReleased && linphone_core_get_calls_nb(lc) == 0) {
      if (!linphone_core_mic_enabled(lc)) {
          NSLog(@"[LinphoneManager] Mic was muted, re-enabling for next call");
          linphone_core_enable_mic(lc, TRUE);
      }
  }

  // Bluetooth Auto-Routing on StreamsRunning/Connected
  if (state == LinphoneCallStreamsRunning || state == LinphoneCallConnected) {
      if ([manager isBluetoothAudioRouteAvailable]) {
          [manager routeAudioToBluetooth];
      }
  }

  NSDictionary *dict = @{@"stateString" : stateStr, @"message" : msgStr};

  [[NSNotificationCenter defaultCenter]
      postNotificationName:kLinphoneCallStateUpdate
                    object:nil
                  userInfo:dict];
}

static void linphone_iphone_audio_device_changed(LinphoneCore *lc, LinphoneAudioDevice *device) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kLinphoneAudioDeviceUpdate object:nil userInfo:@{@"action": @"onAudioDeviceChanged"}];
}

static void linphone_iphone_audio_devices_list_updated(LinphoneCore *lc) {
    [[NSNotificationCenter defaultCenter] postNotificationName:kLinphoneAudioDeviceUpdate object:nil userInfo:@{@"action": @"onAudioDevicesListUpdated"}];
}

// 1. ฟังก์ชันช่วยทำ MD5 Hash
- (NSString *)md5Hash:(NSString *)input {
  const char *cStr = [input UTF8String];
  unsigned char digest[CC_MD5_DIGEST_LENGTH];
  CC_MD5(cStr, (CC_LONG)strlen(cStr), digest);
  NSMutableString *output =
      [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
    [output appendFormat:@"%02x", digest[i]];
  }
  return output;
}

// 2. ฟังก์ชันช่วยแปลง NSDictionary เป็น JSON String
- (NSString *)jsonStringFromDictionary:(NSDictionary *)dict {
  NSError *error;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict
                                                     options:0
                                                       error:&error];
  if (!jsonData)
    return @"{}";
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

// 3. ฟังก์ชันช่วยส่ง Event กลับไปยัง NativeModuleiOS
- (void)postCansEventWithState:(NSString *)state
             payloadDictionary:(NSDictionary *)dict {
  NSString *jsonString = [self jsonStringFromDictionary:dict];
  dispatch_async(dispatch_get_main_queue(), ^{
    // kLinphoneRegistrationUpdate with "stateStr" key — NativeModuleiOS forwards this
    // on the "register" event channel that SignInCANSAccoutScreen listens to.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kLinphoneRegistrationUpdate
                      object:nil
                    userInfo:@{@"stateStr" : state, @"payload" : jsonString}];
    // kCansCustomRegistrationEvent — keeps "registerAccountSetting" listeners working.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kCansCustomRegistrationEvent
                      object:nil
                    userInfo:@{@"state" : state, @"message" : jsonString}];
  });
}

// 4. ฟังก์ชันหลักสำหรับ CANS Account Login
- (void)registerCansAccountWithUsername:(NSString *)username
                               password:(NSString *)password
                                 domain:(NSString *)domain
                                 apiURL:(NSString *)apiURL {
  username = [username stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  password = [password stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  domain = [domain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  apiURL = [apiURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

  NSLog(@"[CansConnect] DEBUG: trimmed username=[%@] len=%lu, domain=[%@] len=%lu", username, (unsigned long)username.length, domain, (unsigned long)domain.length);
  
  if (!username.length || !password.length || !domain.length) {
    NSLog(@"[CansConnect] registerCansAccountWithUsername: empty inputs");
    [self postCansEventWithState:@"FAIL" payloadDictionary:@{}];
    return;
  }

  if (apiURL.length > 0 && ![apiURL hasSuffix:@"/"]) {
    apiURL = [apiURL stringByAppendingString:@"/"];
  }

  [[NSUserDefaults standardUserDefaults] setObject:apiURL forKey:kCANSApiLoginURL];

  NSString *md5Password = [self md5Hash:password];
  // Build fullUsername without stringWithFormat to avoid any weirdness
  NSString *fullUsername = [username stringByAppendingString:@"@"];
  fullUsername = [fullUsername stringByAppendingString:domain];
  
  NSData *fullUserBytes = [fullUsername dataUsingEncoding:NSUTF8StringEncoding];
  NSLog(@"[CansConnect] fullUsername: %@ (bytes: %@)", fullUsername, fullUserBytes);
  NSString *loginUrlString = [NSString stringWithFormat:@"%@api/v3/sign-in/cc", apiURL];
  NSURL *loginUrl = [NSURL URLWithString:loginUrlString];
  NSMutableURLRequest *loginRequest = [NSMutableURLRequest requestWithURL:loginUrl];
  loginRequest.HTTPMethod = @"POST";
  [loginRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [loginRequest setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
  [loginRequest setValue:@"en-US,en;q=0.9,th-TH;q=0.8,th;q=0.7" forHTTPHeaderField:@"Accept-Language"];
  [loginRequest setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
  [loginRequest setValue:@"okhttp/4.9.1" forHTTPHeaderField:@"User-Agent"];

  NSDictionary *loginBody = @{@"username" : fullUsername, @"password" : md5Password};
  NSError *jsonError;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:loginBody options:0 error:&jsonError];
  loginRequest.HTTPBody = jsonData;
  
  NSLog(@"[CansConnect] V3 Login Request: URL=%@ Body=%@", loginUrlString, [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]);

  NSURLSession *session = [NSURLSession sharedSession];
  [[session dataTaskWithRequest:loginRequest
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
          NSLog(@"[CansConnect] Login V3 network error: %@", error);
          [self postCansEventWithState:@"FAIL" payloadDictionary:@{}];
          return;
        }

        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *responseData = json[@"data"];

        if (httpResp.statusCode != 200 || !responseData || [responseData isKindOfClass:[NSNull class]]) {
          NSLog(@"[CansConnect] Login V3 failed: code=%ld message=%@", (long)httpResp.statusCode, json[@"message"]);
          [self postCansEventWithState:@"FAIL" payloadDictionary:@{}];
          return;
        }

        NSDictionary *user = responseData[@"user"];
        BOOL passwordResetRequired = [user[@"password_reset_required"] boolValue];
        NSString *token = responseData[@"token"];
        NSString *domainId = user[@"domain_id"];

        if (passwordResetRequired) {
          NSDictionary *payload = @{
            @"action" : @"PASSWORD_RESET_REQUIRED",
            @"token" : token ?: @"",
            @"userId" : user[@"user_id"] ?: @"",
            @"domainId" : domainId ?: @""
          };
          [self postCansEventWithState:@"PASSWORD_RESET_REQUIRED" payloadDictionary:payload];
          return;
        }

        NSString *sipCredsUrlString = [NSString stringWithFormat:@"%@api/v3/%@/sip-credentials", apiURL, domainId];
        NSURL *sipCredsUrl = [NSURL URLWithString:sipCredsUrlString];
        NSMutableURLRequest *sipRequest = [NSMutableURLRequest requestWithURL:sipCredsUrl];
        sipRequest.HTTPMethod = @"GET";
        [sipRequest setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [sipRequest setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
        [sipRequest setValue:@"en-US,en;q=0.9,th-TH;q=0.8,th;q=0.7" forHTTPHeaderField:@"Accept-Language"];
        [sipRequest setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];

        [[session dataTaskWithRequest:sipRequest
            completionHandler:^(NSData *sipData, NSURLResponse *sipResponse, NSError *sipError) {
              if (sipError || !sipData) {
                NSLog(@"[CansConnect] SIP credentials network error: %@", sipError);
                [self postCansEventWithState:@"FAIL" payloadDictionary:@{}];
                return;
              }

              NSHTTPURLResponse *sipHttpResp = (NSHTTPURLResponse *)sipResponse;
              NSInteger sipCode = sipHttpResp.statusCode;

              // 404 or 424 = SIP account not yet linked to this user
              if (sipCode == 404 || sipCode == 424) {
                NSDictionary *payload = @{@"action" : @"SIP_NOT_LINKED", @"message" : @"SIP Account not linked"};
                [self postCansEventWithState:@"SIP_NOT_LINKED" payloadDictionary:payload];
                return;
              }

              if (sipCode < 200 || sipCode >= 300) {
                NSLog(@"[CansConnect] SIP credentials failed: code=%ld", (long)sipCode);
                [self postCansEventWithState:@"FAIL" payloadDictionary:@{}];
                return;
              }

              NSDictionary *sipJson = [NSJSONSerialization JSONObjectWithData:sipData options:0 error:nil];
              NSDictionary *credsData = sipJson[@"data"];

              if (!credsData || [credsData isKindOfClass:[NSNull class]]) {
                NSDictionary *payload = @{@"action" : @"SIP_NOT_LINKED", @"message" : @"SIP Account not linked"};
                [self postCansEventWithState:@"SIP_NOT_LINKED" payloadDictionary:payload];
                return;
              }

              NSString *ext = credsData[@"extension"] ?: username;
              NSString *domainName = credsData[@"domain_name"] ?: domain;
              NSString *sipCredsHA1 = credsData[@"sip_creds"];

              // Persist token and domainUUID keyed by SIP address — required by forceSetPasswordBcrypt
              NSString *sipAddress = [NSString stringWithFormat:@"%@@%@", ext, domain];
              [[NSUserDefaults standardUserDefaults]
                  setObject:token
                     forKey:[NSString stringWithFormat:@"com.canscloud.accessToken.%@", sipAddress]];
              [[NSUserDefaults standardUserDefaults]
                  setObject:domainId
                     forKey:[NSString stringWithFormat:@"com.canscloud.domainUUID.%@", sipAddress]];

              dispatch_async(dispatch_get_main_queue(), ^{
                [self setupLinphoneWithExtension:ext ha1:sipCredsHA1 domain:domainName port:@"8446" transport:@"tcp"];
              });
            }] resume];
      }] resume];
}

// 5. นำ HA1 มาเซ็ตค่าให้กับ Linphone
- (void)setupLinphoneWithExtension:(NSString *)extension
                               ha1:(NSString *)ha1
                            domain:(NSString *)domainName
                              port:(NSString *)port
                         transport:(NSString *)transportType {
  NSString *realm = [[domainName componentsSeparatedByString:@":"] firstObject];

  LinphoneAuthInfo *authInfo =
      linphone_auth_info_new(extension.UTF8String, NULL, NULL, ha1.UTF8String,
                             realm.UTF8String, realm.UTF8String);
  if (authInfo) {
    linphone_core_add_auth_info(theLinphoneCore, authInfo);
    linphone_auth_info_unref(authInfo);
  }

  LinphoneAccountParams *params =
      linphone_core_create_account_params(theLinphoneCore);
  NSString *identityStr =
      [NSString stringWithFormat:@"sip:%@@%@", extension, realm];
  LinphoneAddress *identity = linphone_address_new(identityStr.UTF8String);
  if (identity) {
    linphone_account_params_set_identity_address(params, identity);
  }

  NSString *serverAddr = [NSString
      stringWithFormat:@"sip:%@:%@;transport=%@", realm, port, transportType];
  LinphoneAddress *server = linphone_address_new(serverAddr.UTF8String);
  if (server) {
    linphone_account_params_set_server_address(params, server);
  }

  linphone_account_params_enable_register(params, TRUE);
  linphone_account_params_set_contact_uri_parameters(params, "app-login-type=cans");

  LinphoneAccount *account = linphone_core_create_account(theLinphoneCore, params);
  if (account) {
    linphone_core_add_account(theLinphoneCore, account);
    linphone_core_set_default_account(theLinphoneCore, account);

    // Set conferenceFactoryUri via the ProxyConfig layer (Account API in SDK 5.4
    // does not expose this directly; ProxyConfig is the underlying representation).
    NSString *confFactoryUri = [NSString stringWithFormat:@"sip:conference-factory@%@", realm];
    const bctbx_list_t *proxies = linphone_core_get_proxy_config_list(theLinphoneCore);
    const bctbx_list_t *last = bctbx_list_last_elem(proxies);
    if (last) {
      LinphoneProxyConfig *pc = (LinphoneProxyConfig *)last->data;
      linphone_proxy_config_set_conference_factory_uri(pc, confFactoryUri.UTF8String);
      NSLog(@"[LinphoneManager] conferenceFactoryUri set: %@", confFactoryUri);
    }
  }

  if (identity)
    linphone_address_unref(identity);
  if (server)
    linphone_address_unref(server);
  if (params)
    linphone_account_params_unref(params);

  linphone_core_refresh_registers(theLinphoneCore);
}

// --- ชุดฟังก์ชันจัดการ Video Call ---

- (BOOL)isVideoCall {
  if (!theLinphoneCore)
    return NO;

  LinphoneCall *currentCall = linphone_core_get_current_call(theLinphoneCore);
  if (!currentCall) {
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    if (calls != NULL) {
      currentCall = (LinphoneCall *)calls->data;
    }
  }

  if (currentCall) {
    const LinphoneCallParams *remoteParams =
        linphone_call_get_remote_params(currentCall);
    if (remoteParams) {
      bool isVideoEnabled = linphone_call_params_video_enabled(remoteParams);
      LinphoneMediaDirection videoDirection =
          linphone_call_params_get_video_direction(remoteParams);

      if (isVideoEnabled && videoDirection != LinphoneMediaDirectionInactive) {
        return YES;
      }
    }
  }
  return NO;
}

- (void)switchCamera {
  if (!theLinphoneCore)
    return;

  const char *currentDevice = linphone_core_get_video_device(theLinphoneCore);
  if (!currentDevice)
    return;

  NSString *currentStr = [NSString stringWithUTF8String:currentDevice];
  NSString *newDeviceStr = nil;

  const char **cameras = linphone_core_get_video_devices(theLinphoneCore);
  if (!cameras)
    return;

  if ([currentStr containsString:@"front"]) {
    for (int i = 0; cameras[i] != NULL; i++) {
      if (strstr(cameras[i], "back") != NULL) {
        newDeviceStr = [NSString stringWithUTF8String:cameras[i]];
        break;
      }
    }
  } else {
    for (int i = 0; cameras[i] != NULL; i++) {
      if (strstr(cameras[i], "front") != NULL) {
        newDeviceStr = [NSString stringWithUTF8String:cameras[i]];
        break;
      }
    }
  }

  if (!newDeviceStr) {
    for (int i = 0; cameras[i] != NULL; i++) {
      if (strcmp(cameras[i], currentDevice) != 0 &&
          strstr(cameras[i], "StaticImage") == NULL) {
        newDeviceStr = [NSString stringWithUTF8String:cameras[i]];
        break;
      }
    }
  }

  if (newDeviceStr) {
    linphone_core_set_video_device(theLinphoneCore, [newDeviceStr UTF8String]);

    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
      LinphoneCallParams *params =
          linphone_core_create_call_params(theLinphoneCore, call);
      linphone_call_update(call, params);
      linphone_call_params_unref(params);
    }
  }
}

- (void)makeVideoCall:(NSString *)phoneNumber {
  if (!theLinphoneCore || !phoneNumber)
    return;

  LinphoneAddress *addr =
      linphone_core_interpret_url(theLinphoneCore, [phoneNumber UTF8String]);
  if (!addr)
    return;

  LinphoneCallParams *params =
      linphone_core_create_call_params(theLinphoneCore, NULL);
  linphone_call_params_enable_video(params, TRUE);
  linphone_call_params_enable_audio(params, TRUE);

  linphone_core_invite_address_with_params(theLinphoneCore, addr, params);

  linphone_address_unref(addr);
  linphone_call_params_unref(params);
}

- (void)acceptVideoCall {
  if (!theLinphoneCore)
    return;

  LinphoneCall *currentCall = linphone_core_get_current_call(theLinphoneCore);
  if (!currentCall) {
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    if (calls != NULL) {
      currentCall = (LinphoneCall *)calls->data;
    }
  }

  if (currentCall) {
    LinphoneCallParams *params =
        linphone_core_create_call_params(theLinphoneCore, currentCall);
    linphone_call_params_enable_video(params, TRUE);
    linphone_call_accept_with_params(currentCall, params);
    linphone_call_params_unref(params);
  }
}

- (void)setVideoWindowsWithRemoteView:(UIView *)remoteView
                            localView:(UIView *)localView {
  if (!theLinphoneCore)
    return;

  if (remoteView) {
    linphone_core_set_native_video_window_id(theLinphoneCore,
                                             (__bridge void *)remoteView);
  }

  if (localView) {
    linphone_core_set_native_preview_window_id(theLinphoneCore,
                                               (__bridge void *)localView);
  }
}

// รับสายแบบ Audio ปกติ
- (void)acceptCall {
  if (!theLinphoneCore)
    return;

  // หา Call ปัจจุบัน
  LinphoneCall *currentCall = linphone_core_get_current_call(theLinphoneCore);
  if (!currentCall) {
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    if (calls != NULL) {
      currentCall = (LinphoneCall *)calls->data;
    }
  }

  // ถ้าเจอสาย ให้กดรับ
  if (currentCall) {
    LinphoneCallParams *params =
        linphone_core_create_call_params(theLinphoneCore, currentCall);

    // ⭐ รับสายเป็น Audio อย่างเดียว ปิดวิดีโอ
    linphone_call_params_enable_video(params, FALSE);
    linphone_call_accept_with_params(currentCall, params);

    linphone_call_params_unref(params);
  }
}

- (void)setVideoEnabled:(BOOL)enabled {
    if (!theLinphoneCore) return;
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (!call) {
        const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
        if (calls != NULL) call = (LinphoneCall *)calls->data;
    }
    if (!call) {
        NSLog(@"[LinphoneManager] setVideoEnabled: no active call, enabled=%d", enabled);
        return;
    }

    // Toggle local capture — no SDP renegotiation, avoids TextureView flicker
    linphone_core_enable_video_capture(theLinphoneCore, enabled);

    // Notify remote peer via SIP INFO so it knows our camera state
    LinphoneContent *content = linphone_factory_create_content(linphone_factory_get());
    linphone_content_set_type(content, "application");
    linphone_content_set_subtype(content, "cans-video-state");
    linphone_content_set_utf8_text(content, enabled ? "video=on" : "video=off");

    LinphoneInfoMessage *info = linphone_core_create_info_message(theLinphoneCore);
    linphone_info_message_set_content(info, content);
    linphone_call_send_info_message(call, info);

    linphone_content_unref(content);
    NSLog(@"[LinphoneManager] setVideoEnabled: %d, sent SIP INFO cans-video-state", enabled);
}

- (void)sendTextMessage:(NSString *)peerUri text:(NSString *)text requestId:(NSString *)requestId {
    if (!theLinphoneCore) return;
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return;
    
    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    if (room) {
        LinphoneChatMessage *msg = linphone_chat_room_create_message(room, text.UTF8String);
        if (requestId) {
            linphone_chat_message_add_custom_header(msg, "X-Request-ID", requestId.UTF8String);
        }
        linphone_chat_message_send(msg);
    }
    linphone_address_unref(addr);
}

- (void)sendImageMessage:(NSString *)peerUri filePath:(NSString *)filePath requestId:(NSString *)requestId {
    if (!theLinphoneCore) return;
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return;
    
    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    if (room) {
        LinphoneChatMessage *msg = linphone_chat_room_create_empty_message(room);
        LinphoneContent *content = linphone_factory_create_content(linphone_factory_get());
        linphone_content_set_type(content, "image");
        linphone_content_set_file_path(content, filePath.UTF8String);
        linphone_chat_message_add_file_content(msg, content);
        if (requestId) {
            linphone_chat_message_add_custom_header(msg, "X-Request-ID", requestId.UTF8String);
        }
        linphone_chat_message_send(msg);
        linphone_content_unref(content);
    }
    linphone_address_unref(addr);
}

- (NSString *)getChatRoomsJSON {
    if (!theLinphoneCore) return @"[]";
    const bctbx_list_t *rooms = linphone_core_get_chat_rooms(theLinphoneCore);
    NSMutableArray *roomsArray = [NSMutableArray array];
    
    for (const bctbx_list_t *it = rooms; it != NULL; it = it->next) {
        LinphoneChatRoom *room = (LinphoneChatRoom *)it->data;
        const LinphoneAddress *peer = linphone_chat_room_get_peer_address(room);
        LinphoneChatMessage *lastMsg = linphone_chat_room_get_last_message_in_history(room);
        
        NSMutableDictionary *roomDict = [NSMutableDictionary dictionary];
        roomDict[@"phoneNumber"] = [NSString stringWithUTF8String:linphone_address_get_username(peer) ?: ""];
        roomDict[@"peerUri"] = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peer) ?: ""];
        roomDict[@"unreadCount"] = @(linphone_chat_room_get_unread_messages_count(room));
        
        if (lastMsg) {
            roomDict[@"lastMessage"] = [NSString stringWithUTF8String:linphone_chat_message_get_text_content(lastMsg) ?: ""];
            roomDict[@"timestamp"] = @(linphone_chat_message_get_time(lastMsg) * 1000.0);
        }
        
        [roomsArray addObject:roomDict];
    }
    
    NSData *data = [NSJSONSerialization dataWithJSONObject:roomsArray options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSString *)getChatHistoryJSON:(NSString *)peerUri {
    if (!theLinphoneCore) return @"[]";
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return @"[]";
    
    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    NSMutableArray *messagesArray = [NSMutableArray array];
    
    if (room) {
        const bctbx_list_t *history = linphone_chat_room_get_history(room, 0);
        for (const bctbx_list_t *it = history; it != NULL; it = it->next) {
            LinphoneChatMessage *msg = (LinphoneChatMessage *)it->data;
            NSMutableDictionary *msgDict = [NSMutableDictionary dictionary];
            msgDict[@"id"] = [NSString stringWithUTF8String:linphone_chat_message_get_custom_header(msg, "X-Request-ID") ?: ""];
            msgDict[@"text"] = [NSString stringWithUTF8String:linphone_chat_message_get_text_content(msg) ?: ""];
            msgDict[@"timestamp"] = @(linphone_chat_message_get_time(msg) * 1000.0);
            msgDict[@"sender"] = linphone_chat_message_is_outgoing(msg) ? @"me" : @"other";
            [messagesArray addObject:msgDict];
        }
    }
    
    linphone_address_unref(addr);
    NSData *data = [NSJSONSerialization dataWithJSONObject:messagesArray options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)deleteMessage:(NSString *)peerUri msgId:(NSString *)msgId {
    if (!theLinphoneCore || !peerUri || !msgId) return;
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return;

    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    if (room) {
        const bctbx_list_t *history = linphone_chat_room_get_history(room, 0);
        for (const bctbx_list_t *it = history; it != NULL; it = it->next) {
            LinphoneChatMessage *msg = (LinphoneChatMessage *)it->data;
            const char *header = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
            if (header && [[NSString stringWithUTF8String:header] isEqualToString:msgId]) {
                linphone_chat_room_delete_message(room, msg);
                NSLog(@"[LinphoneManager] deleteMessage: deleted msgId=%@", msgId);
                break;
            }
        }
    }
    linphone_address_unref(addr);
}

- (void)markAsRead:(NSString *)peerUri {
    if (!theLinphoneCore) return;
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return;
    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    if (room) linphone_chat_room_mark_as_read(room);
    linphone_address_unref(addr);
}

- (void)configureChatSettings:(NSString *)username {
    if (!theLinphoneCore) {
        NSLog(@"[LinphoneManager] configureChatSettings: core not ready, skipping");
        return;
    }

    NSString *currentUser = (username && username.length > 0) ? username : @"default";
    NSString *dbName = [NSString stringWithFormat:@"%@-chats.db", currentUser];
    NSString *dbPath = [LinphoneManager dataFile:dbName];

    NSLog(@"[LinphoneManager] configureChatSettings: user=%@, dbPath=%@", currentUser, dbPath);

    LinphoneConfig *config = linphone_core_get_config(theLinphoneCore);
    if (!config) return;

    // Update per-user chat DB path (takes effect on next core start if changed mid-session)
    const char *currentUri = linphone_config_get_string(config, "storage", "uri", "");
    NSString *currentUriStr = currentUri ? [NSString stringWithUTF8String:currentUri] : @"";
    if (![currentUriStr isEqualToString:dbPath]) {
        NSLog(@"[LinphoneManager] configureChatSettings: updating DB path: %@ → %@", currentUriStr, dbPath);
        linphone_config_set_string(config, "storage", "uri", dbPath.UTF8String);
        linphone_config_set_string(config, "misc", "chat_database_path", dbPath.UTF8String);
        linphone_config_set_string(config, "call_logs", "database_path", dbPath.UTF8String);
    }

    // Chat configuration (mirrors Android CansCenter.configureChatSettings)
    linphone_config_set_int(config, "misc", "hide_empty_chat_rooms", 0);
    linphone_config_set_int(config, "misc", "load_chat_rooms_from_db", 1);
    linphone_config_set_int(config, "misc", "store_chat_logs", 1);
    linphone_config_set_int(config, "misc", "chat_rooms_enabled", 1);
    linphone_config_set_int(config, "misc", "hide_chat_rooms_from_removed_proxies", 0);
    linphone_config_set_int(config, "misc", "group_chat_supported", 0);
    linphone_config_set_int(config, "sip", "check_incoming_request_uri", 1);
    linphone_config_set_string(config, "sip", "save_headers", "To, Diversion, Contact, X-Voicemail");
    linphone_config_set_string(config, "misc", "file_transfer_protocol", "https");

    // Video configuration
    linphone_config_set_int(config, "video", "enabled", 1);
    linphone_config_set_int(config, "video", "capture_enabled", 1);
    linphone_config_set_int(config, "video", "display_enabled", 1);
    linphone_config_set_int(config, "video", "self_view", 1);

    linphone_config_sync(config);

    // Apply video settings directly to running core
    linphone_core_enable_video_capture(theLinphoneCore, TRUE);
    linphone_core_enable_video_display(theLinphoneCore, TRUE);

    NSLog(@"[LinphoneManager] configureChatSettings: done for user=%@", currentUser);
}

- (void)removeAccountAll {
    if (!theLinphoneCore) return;
    linphone_core_clear_accounts(theLinphoneCore);
}

#pragma mark - Chat Callbacks

static void linphone_iphone_message_received(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatMessage *message) {
    LinphoneManager *manager = (__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc));
    const LinphoneAddress *from = linphone_chat_message_get_from_address(message);
    NSString *fromUser = [NSString stringWithUTF8String:linphone_address_get_username(from) ?: ""];
    NSString *text = [NSString stringWithUTF8String:linphone_chat_message_get_text_content(message) ?: ""];
    
    NSDictionary *dict = @{
        @"id": [NSString stringWithUTF8String:linphone_chat_message_get_custom_header(message, "X-Request-ID") ?: ""],
        @"sender": fromUser,
        @"text": text,
        @"timestamp": @(linphone_chat_message_get_time(message) * 1000.0)
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LinphoneMessageReceived" object:nil userInfo:dict];
}

static void linphone_iphone_chat_message_state_changed(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatMessage *message, LinphoneChatMessageState state) {
    NSDictionary *dict = @{
        @"id": [NSString stringWithUTF8String:linphone_chat_message_get_custom_header(message, "X-Request-ID") ?: ""],
        @"state": @(state)
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LinphoneMessageStateChanged" object:nil userInfo:dict];
}

static void linphone_iphone_info_received(LinphoneCore *lc, LinphoneCall *call, const LinphoneInfoMessage *msg) {
    const LinphoneContent *content = linphone_info_message_get_content(msg);
    if (!content) return;

    const char *type = linphone_content_get_type(content);
    const char *subtype = linphone_content_get_subtype(content);

    if (type && subtype &&
        strcmp(type, "application") == 0 &&
        strcmp(subtype, "cans-video-state") == 0) {

        const char *body = linphone_content_get_utf8_text(content);
        BOOL enabled = body && strcmp(body, "video=on") == 0;

        NSLog(@"[LinphoneManager] SIP INFO cans-video-state received: %s", body ?: "(null)");

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kLinphoneRemoteVideoStateUpdate
                              object:nil
                            userInfo:@{@"enabled": @(enabled)}];
        });
    }
}



- (BOOL)getPushNotification {
    if (!theLinphoneCore) return NO;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        return linphone_account_params_get_push_notification_allowed(linphone_account_get_params(acc));
    }
    return NO;
}

- (int)getExpires {
    if (!theLinphoneCore) return 3600;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        return linphone_account_params_get_expires(linphone_account_get_params(acc));
    }
    return 3600;
}

- (void)setExpire:(int)seconds {
    if (!theLinphoneCore) return;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (!acc) return;
    LinphoneAccountParams *params = linphone_account_params_clone(linphone_account_get_params(acc));
    linphone_account_params_set_expires(params, seconds);
    linphone_account_set_params(acc, params);
    linphone_account_params_unref(params);
    NSLog(@"[LinphoneManager] setExpire: %d seconds", seconds);
}

- (NSString *)getPrefix {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        const char *prefix = linphone_account_params_get_international_prefix(linphone_account_get_params(acc));
        return prefix ? [NSString stringWithUTF8String:prefix] : @"";
    }
    return @"";
}

- (BOOL)getReplaceBy00 {
    return NO;
}

- (NSString *)getUsername {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        const LinphoneAddress *addr = linphone_account_params_get_identity_address(linphone_account_get_params(acc));
        const char *user = linphone_address_get_username(addr);
        return user ? [NSString stringWithUTF8String:user] : @"";
    }
    return @"";
}

- (NSString *)getPassword {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        const LinphoneAccountParams *params = linphone_account_get_params(acc);
        const LinphoneAddress *identity = linphone_account_params_get_identity_address(params);
        if (identity) {
            const char *username = linphone_address_get_username(identity);
            const char *domain = linphone_address_get_domain(identity);
            const LinphoneAuthInfo *authInfo = linphone_core_find_auth_info(theLinphoneCore, NULL, username, domain);
            if (authInfo) {
                const char *pw = linphone_auth_info_get_password(authInfo);
                return pw ? [NSString stringWithUTF8String:pw] : @"";
            }
        }
    }
    return @"";
}

- (NSString *)getDisplayName {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        const LinphoneAddress *addr = linphone_account_params_get_identity_address(linphone_account_get_params(acc));
        const char *display_name = linphone_address_get_display_name(addr);
        return display_name ? [NSString stringWithUTF8String:display_name] : @"";
    }
    return @"";
}

- (NSString *)getDomain {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        const LinphoneAddress *addr = linphone_account_params_get_identity_address(linphone_account_get_params(acc));
        const char *domain = linphone_address_get_domain(addr);
        return domain ? [NSString stringWithUTF8String:domain] : @"";
    }
    return @"";
}

- (NSString *)getSipProxy {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        const LinphoneAddress *server = linphone_account_params_get_server_address(linphone_account_get_params(acc));
        char *addr = server ? linphone_address_as_string(server) : NULL;
        NSString *proxy = addr ? [NSString stringWithUTF8String:addr] : @"";
        if (addr) ms_free(addr);
        return proxy;
    }
    return @"";
}

- (BOOL)getOutboundProxy {
    if (!theLinphoneCore) return NO;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        return linphone_account_params_outbound_proxy_enabled(linphone_account_get_params(acc));
    }
    return NO;
}

- (NSString *)getStunServer {
    if (!theLinphoneCore) return @"";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        LinphoneNatPolicy *policy = linphone_account_params_get_nat_policy(linphone_account_get_params(acc));
        const char *stun = policy ? linphone_nat_policy_get_stun_server(policy) : NULL;
        return stun ? [NSString stringWithUTF8String:stun] : @"";
    }
    return @"";
}

- (BOOL)getEnableICE {
    if (!theLinphoneCore) return NO;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        LinphoneNatPolicy *policy = linphone_account_params_get_nat_policy(linphone_account_get_params(acc));
        return policy ? linphone_nat_policy_ice_enabled(policy) : NO;
    }
    return NO;
}

- (int)getAVPF {
    if (!theLinphoneCore) return 0;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        return (int)linphone_account_params_get_avpf_mode(linphone_account_get_params(acc));
    }
    return 0;
}

- (int)getAvpfRrInterval {
    if (!theLinphoneCore) return 5;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        return (int)linphone_account_params_get_avpf_rr_interval(linphone_account_get_params(acc));
    }
    return 5;
}

- (NSString *)getTransport {
    if (!theLinphoneCore) return @"udp";
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (acc) {
        LinphoneTransportType t = linphone_account_params_get_transport(linphone_account_get_params(acc));
        switch (t) {
            case LinphoneTransportUdp: return @"udp";
            case LinphoneTransportTcp: return @"tcp";
            case LinphoneTransportTls: return @"tls";
            case LinphoneTransportDtls: return @"dtls";
            default: return @"udp";
        }
    }
    return @"udp";
}

- (BOOL)checkSessionCansLogin {
    return NO;
}

// PATCH {apiURL}api/v3/{domainId}/user/{userId}/password-set
// Called after a PASSWORD_RESET_REQUIRED flow (CreatePasswordScreen).
- (void)forceSetPasswordWithDomainId:(NSString *)domainId
                              userId:(NSString *)userId
                               token:(NSString *)token
                         newPassword:(NSString *)newPassword
                          completion:(void (^)(BOOL success, NSString *error))completion {
  NSString *apiURL = [[NSUserDefaults standardUserDefaults] stringForKey:kCANSApiLoginURL] ?: @"";
  if (!apiURL.length) {
    NSLog(@"[LinphoneManager] forceSetPasswordWithDomainId: apiLoginURL missing");
    if (completion) completion(NO, @"API URL missing — please login again");
    return;
  }

  NSString *urlStr = [NSString stringWithFormat:@"%@api/v3/%@/user/%@/password-set", apiURL, domainId, userId];
  NSURL *url = [NSURL URLWithString:urlStr];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"PATCH";
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
  req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"password" : newPassword} options:0 error:nil];

  [[NSURLSession.sharedSession dataTaskWithRequest:req
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
          NSLog(@"[LinphoneManager] forceSetPassword network error: %@", error);
          if (completion) completion(NO, error.localizedDescription);
          return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode >= 200 && httpResp.statusCode < 300) {
          NSLog(@"[LinphoneManager] forceSetPassword success: code=%ld", (long)httpResp.statusCode);
          if (completion) completion(YES, nil);
        } else {
          NSString *msg = [NSString stringWithFormat:@"Set password failed: %ld", (long)httpResp.statusCode];
          NSLog(@"[LinphoneManager] %@", msg);
          if (completion) completion(NO, msg);
        }
      }] resume];
}

@end
