//
//  LinphoneManager.m
//  CansConnect
//

#import "LinphoneManager.h"
#import <CommonCrypto/CommonDigest.h>

static LinphoneCore *theLinphoneCore = nil;
NSString *const kLinphoneRegistrationUpdate = @"LinphoneRegistrationUpdate";
NSString *const kLinphoneCallStateUpdate = @"LinphoneCallStateUpdate";

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
      NSLog(@"[LinphoneManager] createLinphoneCore: Core already exists.");
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

    // 🛡️ 0x138 Crash Fix: Disable specs and features that might trigger internal
    // friend list notifications early
    NSLog(
        @"[LinphoneManager] Overriding config to disable LIME and Presence...");
    linphone_config_set_string(config, "sip", "linphone_specs", "groupchat");
    linphone_config_set_int(config, "app", "publish_presence", 0);
    linphone_config_set_int(config, "sip", "publish_presence", 0);

    // 🛡️ API Fix: linphone_factory_create_core_with_config_3 is the correct
    // modern API.
    NSLog(@"[LinphoneManager] Attempting to create core with correct API "
          @"(v3)...");
    theLinphoneCore =
        linphone_factory_create_core_with_config_3(factory, config, NULL);

    if (theLinphoneCore) {
      NSLog(@"[LinphoneManager] Core created successfully at: %p",
            theLinphoneCore);

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

// 🚀 ฟังก์ชัน Login เข้าระบบ SIP
- (void)registerSipWithUsername:(NSString *)username
                       password:(NSString *)password
                         domain:(NSString *)domain
                      transport:(NSString *)transport {
  NSLog(@"[LinphoneManager] Incoming Register Request (Modern API): "
        @"username=%@, domain=%@, transport=%@",
        username, domain, transport);

  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore) {
      NSLog(@"[LinphoneManager] CRITICAL: Cannot register, theLinphoneCore is "
            @"NULL");
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

// ==========================================
// MARK: - Call Management & History
// ==========================================

- (void)startCall:(NSString *)phoneNumber {
  if (!theLinphoneCore)
    return;
  LinphoneAddress *address =
      linphone_core_interpret_url(theLinphoneCore, [phoneNumber UTF8String]);
  if (!address)
    return;

  LinphoneCallParams *params =
      linphone_core_create_call_params(theLinphoneCore, NULL);
  linphone_call_params_enable_video(params, FALSE);

  linphone_core_invite_address_with_params(theLinphoneCore, address, params);
  linphone_address_unref(address);
  linphone_call_params_unref(params);
}

- (NSInteger)callsCount {
  if (!theLinphoneCore)
    return 0;
  return bctbx_list_size(linphone_core_get_calls(theLinphoneCore));
}

- (int)convertCallStateToInt:(LinphoneCallState)state {
  switch (state) {
  case LinphoneCallIdle:
    return 0;
  case LinphoneCallIncomingReceived:
    return 1;
  case LinphoneCallOutgoingInit:
    return 2;
  case LinphoneCallOutgoingProgress:
    return 3;
  case LinphoneCallOutgoingRinging:
    return 4;
  case LinphoneCallOutgoingEarlyMedia:
    return 5;
  case LinphoneCallConnected:
    return 6;
  case LinphoneCallStreamsRunning:
    return 7;
  case LinphoneCallPausing:
    return 8;
  case LinphoneCallPaused:
    return 9;
  case LinphoneCallResuming:
    return 10;
  case LinphoneCallRefered:
    return 11; // 💡 แก้ไข: Linphone SDK สะกดด้วย r ตัวเดียว (Refered)
  case LinphoneCallError:
    return 12;
  case LinphoneCallEnd:
    return 13;
  case LinphoneCallPausedByRemote:
    return 14;
  case LinphoneCallUpdatedByRemote:
    return 15;
  case LinphoneCallIncomingEarlyMedia:
    return 16;
  case LinphoneCallUpdating:
    return 17;
  case LinphoneCallReleased:
    return 18;
  case LinphoneCallEarlyUpdatedByRemote:
    return 19;
  case LinphoneCallEarlyUpdating:
    return 20;
  default:
    return 0;
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
    int jsState = [self convertCallStateToInt:state];

    [logs addObject:@{
      @"callID" : phone,
      @"phoneNumber" : phone,
      @"name" : name,
      @"isPaused" : isPaused ? @YES : @NO,
      @"duration" : [@(duration) stringValue],
      @"status" : @(jsState)
    }];
  }
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:logs
                                                     options:0
                                                       error:nil];
  // 💡 แก้ไข: เปลี่ยน NSUTF8String เป็น NSUTF8StringEncoding
  return jsonData ? [[NSString alloc] initWithData:jsonData
                                          encoding:NSUTF8StringEncoding]
                  : @"[]";
}

- (void)hangUp {
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (call)
    linphone_call_terminate(call);
}

- (void)hangUpAll {
  linphone_core_terminate_all_calls(theLinphoneCore);
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
  AVAudioSession *session = [AVAudioSession sharedInstance];
  BOOL isSpeaker = [self isSpeakerEnabled];
  NSError *error = nil;
  if (isSpeaker) {
    [session overrideOutputAudioPort:AVAudioSessionPortOverrideNone
                               error:&error];
  } else {
    [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker
                               error:&error];
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
  return NO;
}
- (BOOL)isBluetoothState {
  return NO;
}

// ==========================================
// MARK: - Call Event Bridge
// ==========================================

static void linphone_iphone_call_state(LinphoneCore *lc, LinphoneCall *call,
                                       LinphoneCallState state,
                                       const char *message) {
  int stateInt = [[LinphoneManager sharedInstance] convertCallStateToInt:state];
  NSString *msgStr = message ? [NSString stringWithUTF8String:message] : @"";

  NSDictionary *dict = @{
    @"stateInt" : @(stateInt),
    @"stateString" : msgStr,
    @"message" : msgStr
  };

  [[NSNotificationCenter defaultCenter]
      postNotificationName:kLinphoneCallStateUpdate
                    object:nil
                  userInfo:dict];
}

@end