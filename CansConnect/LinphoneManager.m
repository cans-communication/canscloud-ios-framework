//
//  LinphoneManager.m
//  CansConnect
//

#import "LinphoneManager.h"
#import <CommonCrypto/CommonDigest.h>
#import <CansConnect/CansConnect-Swift.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

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

// Per-message callbacks (Linphone 5.x — set on each outgoing LinphoneChatMessage object)
static void lm_chat_msg_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state);
static void lm_img_msg_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state);
static void lm_incoming_img_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state);
static void lm_incoming_msg_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state);
static void lm_img_progress(LinphoneChatMessage *msg, LinphoneContent *content, size_t offset, size_t total);

static void linphone_iphone_info_received(LinphoneCore *lc, LinphoneCall *call, const LinphoneInfoMessage *msg);
static void linphone_iphone_chat_room_state_changed(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatRoomState state);

@interface LinphoneManager () {
  NSTimer *iterateTimer;
  BOOL _echoTesterRunning;
  // Tracks last-known remote camera state to suppress duplicate/spurious events
  // (mirrors Android's lastRemoteCameraOnState). Reset to -1 (unknown) on End/Error/Released.
  int _lastRemoteCameraOnState; // -1=unknown, 0=off, 1=on
  // callId from a VoIP push that arrived before the core finished initializing.
  // Consumed and cleared inside createLinphoneCore after linphone_core_start.
  NSString *_pendingVoIPCallId;
}
@end

@implementation LinphoneManager

// +load runs at binary-image load time, before main() and before any app code.
// Registering here guarantees the observer exists when AppDelegate first runs.
+ (void)load {
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleEarlyVoIPPushWakeup:)
             name:@"CansEarlyVoIPPushWakeup"
           object:nil];
}

// Handles CansEarlyVoIPPushWakeup posted by CansBase.initializeCoreForPushWakeup.
// NotificationCenter delivers on the posting thread; createLinphoneCore always dispatches to main.
// Safe to call multiple times — createLinphoneCore and setPendingVoIPCallId are both idempotent.
+ (void)handleEarlyVoIPPushWakeup:(NSNotification *)notif {
  NSString *callId = notif.userInfo[@"callId"] ?: @"";
  NSLog(@"[LinphoneManager] handleEarlyVoIPPushWakeup: callId=%@",
        callId.length ? callId : @"(early-init, no callId)");
  [[self sharedInstance] setPendingVoIPCallId:callId];
  [[self sharedInstance] createLinphoneCore];
}

// Stores callId for processing after the core finishes starting.
// If the core is already running, processes the push immediately.
- (void)setPendingVoIPCallId:(NSString *)callId {
  if (!callId.length) return;
  if (theLinphoneCore) {
    NSLog(@"[LinphoneManager] setPendingVoIPCallId: core ready — processing immediately: %@", callId);
    [self processPushNotification:callId];
  } else {
    NSLog(@"[LinphoneManager] setPendingVoIPCallId: core not ready — deferring: %@", callId);
    _pendingVoIPCallId = callId;
  }
}

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

- (void)createLinphoneCore {
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (theLinphoneCore) {
      NSLog(@"[LinphoneManager] createLinphoneCore: Core already exists. (Timer status: %@)", self->iterateTimer ? @"Running" : @"Stopped");
      if (!self->iterateTimer) [weakSelf startIterateTimer];
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

    // Initialize logging service early to set up global SDK state
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
    linphone_config_set_int(config, "app", "use_callkit", 1);

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
                                                                  FALSE);
      linphone_video_activation_policy_set_automatically_accept(videoPolicy,
                                                                TRUE);
      linphone_core_set_video_activation_policy(theLinphoneCore, videoPolicy);
      linphone_video_activation_policy_unref(videoPolicy);
      // ==========================================================

      // Keep alive is essential for background stability
      linphone_core_enable_keep_alive(theLinphoneCore, true);

      // Ghost-call prevention: if no RTP media is received for this many seconds,
      // Linphone terminates the call with LinphoneCallError. Without this, Device B
      // stays frozen indefinitely when Device A loses its network mid-call.
      int nortpTimeout = linphone_config_get_int(linphone_core_get_config(theLinphoneCore), "rtp", "nortp_timeout", 20);
      linphone_core_set_nortp_timeout(theLinphoneCore, nortpTimeout);
      NSLog(@"[LinphoneManager] nortp_timeout set to %ds — ghost call protection active.", nortpTimeout);

      // Session timers (RFC 4028): re-negotiation every 200 s keeps the signaling
      // path alive and lets both sides detect a dead peer via re-INVITE failure,
      // providing a second layer of protection on top of RTP timeout.
      linphone_core_set_session_expires_enabled(theLinphoneCore, TRUE);
      linphone_core_set_session_expires_value(theLinphoneCore, 200);
      linphone_core_set_session_expires_min_value(theLinphoneCore, 90);

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
      linphone_core_cbs_set_chat_room_state_changed(cbs, linphone_iphone_chat_room_state_changed);

      linphone_core_add_callbacks(theLinphoneCore, cbs);

      NSLog(@"[LinphoneManager] Starting core...");
      linphone_core_start(theLinphoneCore);

      // Suppress Linphone's internal ring player so CallKit can ring natively.
      // Without this, Linphone activates AVAudioSession before CallKit's
      // provider:didActivate: fires, muting the system ringtone.
      // This must be called every launch (including VoIP push wakeup before JS loads)
      // because JS's setUseDeviceRingtone() is never called in the killed-state path.
      linphone_core_set_ring(theLinphoneCore, NULL);
      NSLog(@"[LinphoneManager] Ring player suppressed — CallKit will ring natively.");

      // Enable vibration for incoming calls in case the app is in a non-CallKit
      // foreground state where Linphone manages its own ringing.
      linphone_core_enable_vibration_on_incoming_call(theLinphoneCore, true);

      [self startIterateTimer];
      NSLog(@"[LinphoneManager] Core started and timer running!");

      // Wire up Swift CallManager so callByCallId and onCallStateChanged work.
      // CallManager is internal (@objc but not public) so we call through CansBase.
      [CansBase wireCallManagerCore:theLinphoneCore];
      NSLog(@"[LinphoneManager] CansBase.wireCallManagerCore called — CallManager.lc is now set.");

      // Drain any VoIP push callId that arrived before the core was ready.
      if (_pendingVoIPCallId.length) {
        NSString *pendingId = _pendingVoIPCallId;
        _pendingVoIPCallId = nil;
        NSLog(@"[LinphoneManager] createLinphoneCore: processing deferred VoIP push callId=%@", pendingId);
        [self processPushNotification:pendingId];
      }
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

  // cfg can be NULL when called from authentication_requested callback
  // (e.g. during sign-out deregistration). Guard before dereferencing.
  LinphoneReason reason = cfg ? linphone_proxy_config_get_error(cfg) : LinphoneReasonNone;
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

  // Mirror Android onAccountRegistrationStateChanged: if registration succeeded
  // but FCM push params are missing, ask NativeModuleiOS to inject the token.
  if (state == LinphoneRegistrationOk) {
    LinphoneAccount *acc = linphone_core_get_default_account(lc);
    if (acc) {
      const char *cp = linphone_account_params_get_contact_uri_parameters(
          linphone_account_get_params(acc));
      NSString *cpStr = cp ? [NSString stringWithUTF8String:cp] : @"";
      NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
      BOOL hasPushParam = [cpStr containsString:
          [NSString stringWithFormat:@"pn-param=%@", bundleId]];
      if (!hasPushParam) {
        NSLog(@"[LinphoneManager] Registration OK — pn-param missing, requesting FCM injection");
        dispatch_async(dispatch_get_main_queue(), ^{
          [[NSNotificationCenter defaultCenter]
              postNotificationName:@"CansInjectFCMToken"
                            object:nil];
        });
      }
    }
  }
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
    return;
  }

  LinphoneAddress *address =
      linphone_core_interpret_url(theLinphoneCore, [phoneNumber UTF8String]);
  if (!address) {
    return;
  }

  // Route through CallManager (via CansBase) so CallKit receives a CXStartCallAction.
  // CallKit then fires provider(_:didActivate:audioSession:) → activateAudioSession(true).
  // Without this, Linphone's audio pipeline never starts and the call is silent.
  CansBase *cansBase = [CansBase new];
  [cansBase startCallWithAddr:(void *)address isSas:NO];
  linphone_address_unref(address);
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
            @"status": [self convertCallStateToString:(LinphoneCallState)linphone_call_log_get_status(log)] ?: @"Unknown",
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

- (NSString *)lastOutgoingCallLog {
    if (!theLinphoneCore) return @"";
    LinphoneCallLog *log = linphone_core_get_last_outgoing_call_log(theLinphoneCore);
    if (!log) return @"";
    const LinphoneAddress *addr = linphone_call_log_get_remote_address(log);
    if (!addr) return @"";
    const char *username = linphone_address_get_username(addr);
    return username ? [NSString stringWithUTF8String:username] : @"";
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

- (void)setPayLoadAtIndex:(int)index enabled:(BOOL)enabled {
  if (!theLinphoneCore) return;
  LinphonePayloadType *pt = (LinphonePayloadType *)bctbx_list_nth_data(
      linphone_core_get_audio_payload_types(theLinphoneCore), index);
  if (pt) linphone_payload_type_enable(pt, enabled);
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

- (void)setMediaEncryption:(int)position {
  if (!theLinphoneCore) return;
  LinphoneMediaEncryption enc;
  switch (position) {
    case 1: enc = LinphoneMediaEncryptionSRTP; break;
    case 2: enc = LinphoneMediaEncryptionZRTP; break;
    case 3: enc = LinphoneMediaEncryptionDTLS; break;
    default: enc = LinphoneMediaEncryptionNone; break;
  }
  linphone_core_set_media_encryption(theLinphoneCore, enc);
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

- (void)uploadLogCollection {
  if (theLinphoneCore) linphone_core_upload_log_collection(theLinphoneCore);
}

- (void)resetLogCollection {
  linphone_core_reset_log_collection();
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
  if (theLinphoneCore) {
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    const LinphoneAudioDevice *dev = call
        ? linphone_call_get_output_audio_device(call)
        : linphone_core_get_output_audio_device(theLinphoneCore);
    if (dev) {
      LinphoneAudioDeviceType t = linphone_audio_device_get_type(dev);
      BOOL isSpeaker = (t == LinphoneAudioDeviceTypeSpeaker);
      NSLog(@"[LinphoneManager] isSpeakerEnabled: Linphone device type=%d isSpeaker=%d", (int)t, (int)isSpeaker);
      return isSpeaker;
    }
    NSLog(@"[LinphoneManager] isSpeakerEnabled: Linphone device=NULL, falling back to AVAudioSession");
  }
  // Fallback: Linphone core not ready or no call — read AVAudioSession.
  AVAudioSessionRouteDescription *route =
      [[AVAudioSession sharedInstance] currentRoute];
  for (AVAudioSessionPortDescription *desc in [route outputs]) {
    if ([[desc portType] isEqualToString:AVAudioSessionPortBuiltInSpeaker]) {
      NSLog(@"[LinphoneManager] isSpeakerEnabled: AVAudioSession=Speaker → YES");
      return YES;
    }
  }
  NSLog(@"[LinphoneManager] isSpeakerEnabled: AVAudioSession=Receiver → NO");
  return NO;
}

- (void)toggleSpeaker {
  BOOL currentlyOn = [self isSpeakerEnabled];
  NSLog(@"[LinphoneManager] toggleSpeaker: currentlyOn=%d → routing to %@", currentlyOn, currentlyOn ? @"earpiece" : @"speaker");
  if (currentlyOn) {
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
  const LinphoneAudioDevice *dev = linphone_call_get_output_audio_device(call);
  if (dev && linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeBluetooth) {
    return YES;
  }
  return NO;
}

- (BOOL)isBluetoothDevices {
  if (!theLinphoneCore) return NO;
  const bctbx_list_t *devices = linphone_core_get_extended_audio_devices(theLinphoneCore);
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    if (linphone_audio_device_get_type(dev) == LinphoneAudioDeviceTypeBluetooth) {
      return YES;
    }
  }
  return NO;
}

- (void)routeAudioToSpeaker {
  if (!theLinphoneCore) return;
  LinphoneAudioDevice *speaker = NULL;
  const bctbx_list_t *devices = linphone_core_get_audio_devices(theLinphoneCore);
  NSMutableArray *names = [NSMutableArray array];
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    LinphoneAudioDeviceType t = linphone_audio_device_get_type(dev);
    const char *n = linphone_audio_device_get_device_name(dev);
    [names addObject:[NSString stringWithFormat:@"%s(t=%d)", n ?: "?", (int)t]];
    if (t == LinphoneAudioDeviceTypeSpeaker) {
      speaker = dev;
    }
  }
  NSLog(@"[LinphoneManager] routeAudioToSpeaker: devices=%@ found=%d", names, speaker != NULL);
  if (speaker) {
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
      linphone_call_set_output_audio_device(call, speaker);
    } else {
      linphone_core_set_output_audio_device(theLinphoneCore, speaker);
    }
    NSLog(@"[LinphoneManager] routeAudioToSpeaker: done");
  }
}

- (void)routeAudioToEarpiece {
  if (!theLinphoneCore) return;
  LinphoneAudioDevice *earpiece = NULL;
  LinphoneAudioDevice *defaultDev = NULL;
  const bctbx_list_t *devices = linphone_core_get_audio_devices(theLinphoneCore);
  NSMutableArray *names = [NSMutableArray array];
  for (const bctbx_list_t *it = devices; it != NULL; it = it->next) {
    LinphoneAudioDevice *dev = (LinphoneAudioDevice *)it->data;
    LinphoneAudioDeviceType t = linphone_audio_device_get_type(dev);
    const char *n = linphone_audio_device_get_device_name(dev);
    [names addObject:[NSString stringWithFormat:@"%s(t=%d)", n ?: "?", (int)t]];
    if (t == LinphoneAudioDeviceTypeEarpiece) {
      earpiece = dev;
    } else if (t == LinphoneAudioDeviceTypeMicrophone && !defaultDev) {
      // On iPhone, the [default] card (Microphone type) routes to earpiece/receiver
      // when not in speaker mode — explicit Earpiece device is often absent.
      defaultDev = dev;
    }
  }
  LinphoneAudioDevice *target = earpiece ?: defaultDev;
  NSLog(@"[LinphoneManager] routeAudioToEarpiece: devices=%@ earpiece=%d default=%d target=%p", names, earpiece != NULL, defaultDev != NULL, target);
  if (target) {
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (call) {
      linphone_call_set_output_audio_device(call, target);
    } else {
      linphone_core_set_output_audio_device(theLinphoneCore, target);
    }
    NSLog(@"[LinphoneManager] routeAudioToEarpiece: done");
  } else {
    NSLog(@"[LinphoneManager] routeAudioToEarpiece: NO EARPIECE OR DEFAULT DEVICE FOUND");
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

- (BOOL)transferCallNow:(NSString *)phoneNumber {
    if (!theLinphoneCore) return NO;
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (!call) {
        const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
        if (calls) call = (LinphoneCall *)calls->data;
    }
    if (!call) {
        NSLog(@"[LinphoneManager] transferCallNow: no active call");
        return NO;
    }
    LinphoneAddress *address = linphone_core_interpret_url(theLinphoneCore, [phoneNumber UTF8String]);
    if (!address) {
        NSLog(@"[LinphoneManager] transferCallNow: could not resolve address for %@", phoneNumber);
        return NO;
    }
    NSLog(@"[LinphoneManager] transferCallNow: blind transfer to %@", phoneNumber);
    linphone_call_transfer_to(call, address);
    linphone_address_unref(address);
    return YES;
}

- (BOOL)transferCallAskFirst:(NSString *)phoneNumber {
    if (!theLinphoneCore) return NO;
    int callCount = linphone_core_get_calls_nb(theLinphoneCore);
    if (callCount != 2) {
        NSLog(@"[LinphoneManager] transferCallAskFirst: need exactly 2 calls, got %d", callCount);
        return NO;
    }
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    LinphoneCall *call1 = (LinphoneCall *)calls->data;
    LinphoneCall *call2 = (LinphoneCall *)calls->next->data;

    // Identify which call is paused (original caller to transfer) and which is active
    // (transfer target). linphone_call_transfer_to_another(pausedCall, activeCall)
    // transfers the paused call to the active call's endpoint.
    LinphoneCall *pausedCall = NULL;
    LinphoneCall *activeCall = NULL;
    LinphoneCallState state1 = linphone_call_get_state(call1);
    LinphoneCallState state2 = linphone_call_get_state(call2);

    if (state1 == LinphoneCallPaused || state1 == LinphoneCallPausedByRemote) {
        pausedCall = call1;
        activeCall = call2;
    } else if (state2 == LinphoneCallPaused || state2 == LinphoneCallPausedByRemote) {
        pausedCall = call2;
        activeCall = call1;
    } else {
        // Fallback: treat the current call as active, the other as the one to transfer.
        LinphoneCall *current = linphone_core_get_current_call(theLinphoneCore);
        activeCall = current ? current : call1;
        pausedCall = (activeCall == call1) ? call2 : call1;
    }

    NSLog(@"[LinphoneManager] transferCallAskFirst: attended transfer (pausedCall→activeCall)");
    linphone_call_transfer_to_another(pausedCall, activeCall);
    return YES;
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

  NSLog(@"[LinphoneManager][VideoCall] call_state_changed: state=%@ message=%s", stateStr, message ?: "");

  // Remote Video State Monitoring — mirrors Android's lastRemoteCameraOnState.
  // Skip during LinphoneCallUpdating: remote params reflect mid-negotiation SDP which
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

  // Activate Linphone's audio pipeline at StreamsRunning — this is the earliest point
  // where RTP streams actually exist. With use_callkit=1, activateAudioSession is a no-op
  // when called before streams are created (e.g. in acceptCall before acceptWithParams).
  // Calling it here is safe for all three paths:
  //   • Foreground: didActivate never fires → this is the only activation → audio starts ✓
  //   • Background CK (didActivate before StreamsRunning): redundant, idempotent ✓
  //   • Background CK (didActivate after StreamsRunning): preemptive; didActivate is also fine ✓
  if (state == LinphoneCallStreamsRunning) {
      CansBase *cansBase = [CansBase new];
      [cansBase activateLinphoneAudioSession];
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

// convert NSDictionary to JSON String
- (NSString *)jsonStringFromDictionary:(NSDictionary *)dict {
  NSError *error;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict
                                                     options:0
                                                       error:&error];
  if (!jsonData)
    return @"{}";
  return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

// send Event back to NativeModuleiOS
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

- (BOOL)isRemoteVideoEnabled {
    if (!theLinphoneCore) return NO;
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (!call) return NO;

    const LinphoneCallParams *remoteParams = linphone_call_get_remote_params(call);
    const LinphoneCallParams *currentParams = linphone_call_get_current_params(call);

    BOOL remoteHasVideo = remoteParams ? linphone_call_params_video_enabled(remoteParams) : NO;
    LinphoneMediaDirection remoteDir = remoteParams
        ? linphone_call_params_get_video_direction(remoteParams)
        : LinphoneMediaDirectionInactive;
    BOOL remoteIsSending = remoteHasVideo &&
        (remoteDir == LinphoneMediaDirectionSendOnly || remoteDir == LinphoneMediaDirectionSendRecv);

    BOOL currentHasVideo = currentParams ? linphone_call_params_video_enabled(currentParams) : NO;
    LinphoneMediaDirection currentDir = currentParams
        ? linphone_call_params_get_video_direction(currentParams)
        : LinphoneMediaDirectionInactive;
    BOOL weAreReceiving = currentHasVideo &&
        (currentDir == LinphoneMediaDirectionRecvOnly || currentDir == LinphoneMediaDirectionSendRecv);

    return remoteIsSending && weAreReceiving;
}

- (NSDictionary *)getRemoteVideoStats {
    if (!theLinphoneCore) return nil;
    LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
    if (!call) return nil;

    // Linphone 5.4 CallStats has no receiveFramerate — use downloadBandwidth as proxy.
    LinphoneCallStats *stats = linphone_call_get_stats(call, LinphoneStreamTypeVideo);
    float downloadBandwidth = stats ? linphone_call_stats_get_download_bandwidth(stats) : 0.0f;

    return @{@"fps": @(0.0), @"bitrate": @(downloadBandwidth)};
}

// Returns the Linphone camera name string for the front-facing camera, or nil if not found.
// AVCaptureDevice for front-position devices and matching their uniqueID against Linphone's list.
- (NSString *)frontCameraNameForLinphone {
    if (!theLinphoneCore) return nil;
    NSMutableArray<NSString *> *frontIDs = [NSMutableArray array];
    if (@available(iOS 10.0, *)) {
        AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                  mediaType:AVMediaTypeVideo
                                   position:AVCaptureDevicePositionFront];
        for (AVCaptureDevice *dev in session.devices) {
            [frontIDs addObject:dev.uniqueID];
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (AVCaptureDevice *dev in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
            if (dev.position == AVCaptureDevicePositionFront) {
                [frontIDs addObject:dev.uniqueID];
            }
        }
#pragma clang diagnostic pop
    }
    if (frontIDs.count == 0) return nil;
    const char **cameras = linphone_core_get_video_devices(theLinphoneCore);
    if (!cameras) return nil;
    for (int i = 0; cameras[i] != NULL; i++) {
        NSString *camStr = [NSString stringWithUTF8String:cameras[i]];
        for (NSString *uid in frontIDs) {
            if ([camStr containsString:uid]) {
                NSLog(@"[LinphoneManager] frontCameraNameForLinphone: matched camera=%@", camStr);
                return camStr;
            }
        }
    }
    NSLog(@"[LinphoneManager] frontCameraNameForLinphone: no front camera matched in Linphone list");
    return nil;
}

// Returns the Linphone camera name for the back-facing camera, or nil.
- (NSString *)backCameraNameForLinphone {
    if (!theLinphoneCore) return nil;
    NSMutableArray<NSString *> *backIDs = [NSMutableArray array];
    if (@available(iOS 10.0, *)) {
        AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera]
                                  mediaType:AVMediaTypeVideo
                                   position:AVCaptureDevicePositionBack];
        for (AVCaptureDevice *dev in session.devices) {
            [backIDs addObject:dev.uniqueID];
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (AVCaptureDevice *dev in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
            if (dev.position == AVCaptureDevicePositionBack) {
                [backIDs addObject:dev.uniqueID];
            }
        }
#pragma clang diagnostic pop
    }
    if (backIDs.count == 0) return nil;
    const char **cameras = linphone_core_get_video_devices(theLinphoneCore);
    if (!cameras) return nil;
    for (int i = 0; cameras[i] != NULL; i++) {
        NSString *camStr = [NSString stringWithUTF8String:cameras[i]];
        for (NSString *uid in backIDs) {
            if ([camStr containsString:uid]) {
                NSLog(@"[LinphoneManager] backCameraNameForLinphone: matched camera=%@", camStr);
                return camStr;
            }
        }
    }
    NSLog(@"[LinphoneManager] backCameraNameForLinphone: no back camera matched in Linphone list");
    return nil;
}

- (void)switchCamera {
  if (!theLinphoneCore)
    return;

  const char *currentDevice = linphone_core_get_video_device(theLinphoneCore);
  if (!currentDevice)
    return;

  NSString *currentStr = [NSString stringWithUTF8String:currentDevice];
  NSString *newDeviceStr = nil;

  NSString *frontName = [self frontCameraNameForLinphone];
  NSString *backName  = [self backCameraNameForLinphone];

  // Determine current camera face via AVCaptureDevice uniqueID matching.
  BOOL currentIsFront = frontName && [currentStr isEqualToString:frontName];
  if (currentIsFront) {
    newDeviceStr = backName;
  } else {
    newDeviceStr = frontName;
  }

  if (!newDeviceStr) {
    const char **cameras = linphone_core_get_video_devices(theLinphoneCore);
    if (cameras) {
      for (int i = 0; cameras[i] != NULL; i++) {
        if (strcmp(cameras[i], currentDevice) != 0 &&
            strstr(cameras[i], "StaticImage") == NULL) {
          newDeviceStr = [NSString stringWithUTF8String:cameras[i]];
          break;
        }
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

  NSLog(@"[LinphoneManager] makeVideoCall: %@", phoneNumber);
  // Dispatch on the main queue — linphone_core_iterate runs on the main thread via NSTimer;
  // calling linphone_core_* from any other queue introduces races (core is not thread-safe).
  NSString *phoneCopy = [phoneNumber copy];
  LinphoneCore *lc = theLinphoneCore;
  NSString *frontName = [self frontCameraNameForLinphone];
  dispatch_async(dispatch_get_main_queue(), ^{
    if (frontName) {
      NSLog(@"[LinphoneManager] makeVideoCall: selecting front camera=%@", frontName);
      linphone_core_set_video_device(lc, [frontName UTF8String]);
    }
    // Re-enable capture/display/preview in case a previous call left them disabled (background state).
    linphone_core_enable_video_capture(lc, YES);
    linphone_core_enable_video_display(lc, YES);
    linphone_core_enable_video_preview(lc, YES);
    linphone_core_enable_self_view(lc, YES);

    LinphoneAddress *addr =
        linphone_core_interpret_url(lc, [phoneCopy UTF8String]);
    if (!addr)
      return;

    LinphoneCallParams *params =
        linphone_core_create_call_params(lc, NULL);
    linphone_call_params_enable_video(params, TRUE);
    linphone_call_params_enable_audio(params, TRUE);

    linphone_core_invite_address_with_params(lc, addr, params);

    linphone_address_unref(addr);
    linphone_call_params_unref(params);
  });
}

- (void)acceptVideoCall {
  NSLog(@"[LinphoneManager][VideoCall] acceptVideoCall called");
  if (!theLinphoneCore)
    return;

  // Select front camera before accepting — iOS Linphone defaults to back camera.
  NSString *frontName = [self frontCameraNameForLinphone];
  if (frontName) {
    NSLog(@"[LinphoneManager][VideoCall] acceptVideoCall: selecting front camera=%@", frontName);
    linphone_core_set_video_device(theLinphoneCore, [frontName UTF8String]);
  }

  LinphoneCall *currentCall = linphone_core_get_current_call(theLinphoneCore);
  if (!currentCall) {
    const bctbx_list_t *calls = linphone_core_get_calls(theLinphoneCore);
    if (calls != NULL) {
      currentCall = (LinphoneCall *)calls->data;
    }
  }

  if (currentCall) {
    // Release the .playback ringtone session before Linphone reconfigures
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CansCallAnsweredByUser"
        object:nil];
    // Configure AVAudioSession category/mode (.playAndRecord + .voiceChat)
    CansBase *cansBase = [CansBase new];
    [cansBase configureLinphoneAudioSession];

    // Dispatch on the main queue — linphone_core_iterate runs on the main thread via NSTimer;
    // calling linphone_core_* / linphone_call_* from any other queue risks races (core is not thread-safe).
    LinphoneCall *callToAccept = currentCall;
    LinphoneCore *lc = theLinphoneCore;
    dispatch_async(dispatch_get_main_queue(), ^{
      LinphoneCallParams *params =
          linphone_core_create_call_params(lc, callToAccept);
      linphone_call_params_enable_video(params, TRUE);
      linphone_call_accept_with_params(callToAccept, params);
      linphone_call_params_unref(params);
    });
  }
}

- (void)setVideoWindowsWithRemoteView:(UIView *)remoteView
                            localView:(UIView *)localView {
  NSLog(@"[LinphoneManager][VideoCall] setVideoWindowsWithRemoteView: remote=%@ local=%@", remoteView, localView);
  if (!theLinphoneCore)
    return;

  if (remoteView) {
    linphone_core_set_native_video_window_id(theLinphoneCore,
                                             (__bridge void *)remoteView);
    NSLog(@"[LinphoneManager][VideoCall] native video window bound: %@", remoteView);
  }

  if (localView) {
    // Tear down the existing ogl_display before binding the new view.
    // Disabling preview first forces ogl_display destruction so the subsequent YES call creates
    // a fresh instance properly bound to the new view.
    linphone_core_enable_video_preview(theLinphoneCore, NO);
    linphone_core_set_native_preview_window_id(theLinphoneCore,
                                               (__bridge void *)localView);
    NSLog(@"[LinphoneManager][VideoCall] native preview window bound: %@", localView);
    linphone_core_enable_video_capture(theLinphoneCore, YES);
    linphone_core_enable_video_preview(theLinphoneCore, YES);
    NSLog(@"[LinphoneManager][VideoCall] preview pipeline re-enabled for new window");
  }
}

- (void)acceptCall {
  NSLog(@"[LinphoneManager] acceptCall called (foreground path)");
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
    // Release the .playback ringtone session before Linphone reconfigures
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"CansCallAnsweredByUser"
        object:nil];
    // Configure AVAudioSession category/mode (.playAndRecord + .voiceChat) now —
    CansBase *cansBase = [CansBase new];
    [cansBase configureLinphoneAudioSession];

    LinphoneCallParams *params =
        linphone_core_create_call_params(theLinphoneCore, currentCall);
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

    // Switch video device — avoids SDP renegotiation (no re-INVITE, no flicker).
    // StaticImage collapses UL to ~20 kbps so remote FPS polling can detect camera-off.
    // isVideoCaptureEnabled=false alone keeps the encoder on the last frozen frame (~1000 kbps),
    // which the remote's bitrate threshold cannot distinguish from live video.
    NSLog(@"[LinphoneManager][VideoCall] setVideoEnabled: enabled=%d, switching device", enabled);
    if (enabled) {
        NSString *targetCamera = [self frontCameraNameForLinphone];
        if (!targetCamera) {
            // Fallback: first non-StaticImage camera
            const char **cameras = linphone_core_get_video_devices(theLinphoneCore);
            if (cameras) {
                for (int i = 0; cameras[i] != NULL; i++) {
                    if (strstr(cameras[i], "StaticImage") == NULL) {
                        targetCamera = [NSString stringWithUTF8String:cameras[i]];
                        break;
                    }
                }
            }
        }
        if (targetCamera) {
            NSLog(@"[LinphoneManager][VideoCall] setVideoEnabled: switching to camera=%@", targetCamera);
            linphone_core_set_video_device(theLinphoneCore, [targetCamera UTF8String]);
        }
        // Cycle capture off→on to force Linphone to open the hardware camera
        // against the already-bound preview surface.
        linphone_core_enable_video_capture(theLinphoneCore, NO);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (theLinphoneCore) {
                linphone_core_enable_video_capture(theLinphoneCore, YES);
                NSLog(@"[LinphoneManager][VideoCall] setVideoEnabled: video capture re-enabled");
            }
        });
    } else {
        NSLog(@"[LinphoneManager][VideoCall] setVideoEnabled: switching to StaticImage");
        linphone_core_set_video_device(theLinphoneCore, "StaticImage: Static picture");
        linphone_core_enable_video_capture(theLinphoneCore, NO);
    }

    // Primary: notify remote peer via SIP INFO
    LinphoneContent *content = linphone_factory_create_content(linphone_factory_get());
    linphone_content_set_type(content, "application");
    linphone_content_set_subtype(content, "cans-video-state");
    linphone_content_set_utf8_text(content, enabled ? "video=on" : "video=off");

    LinphoneInfoMessage *info = linphone_core_create_info_message(theLinphoneCore);
    linphone_info_message_set_content(info, content);
    linphone_call_send_info_message(call, info);

    linphone_content_unref(content);
    NSLog(@"[LinphoneManager] setVideoEnabled: %d, sent SIP INFO cans-video-state", enabled);

    // Fallback: SIP MESSAGE with X-CANS-CTRL — passes B2BUA proxies that drop SIP INFO
    // with custom Content-Types. callLog.remoteAddress is unaffected by B2BUA Contact rewriting.
    const LinphoneAddress *remoteAddr = linphone_call_log_get_remote_address(linphone_call_get_call_log(call));
    if (!remoteAddr) remoteAddr = linphone_call_get_remote_address(call);
    if (remoteAddr) {
        LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, remoteAddr);
        if (room) {
            const char *ctrlValue = enabled ? "video-state:on" : "video-state:off";
            LinphoneChatMessage *msg = linphone_chat_room_create_empty_message(room);
            linphone_chat_message_add_custom_header(msg, "X-CANS-CTRL", ctrlValue);
            linphone_chat_message_send(msg);
        }
    }
}

- (void)startVideoPreview {
  if (!theLinphoneCore) return;
  LinphoneCall *call = linphone_core_get_current_call(theLinphoneCore);
  if (call) {
    LinphoneCallState st = linphone_call_get_state(call);
    if (st == LinphoneCallEnd || st == LinphoneCallReleased || st == LinphoneCallError) return;
  }
  NSString *target = [self frontCameraNameForLinphone];
  if (!target) {
    // Fallback: first non-StaticImage camera
    const char **cameras = linphone_core_get_video_devices(theLinphoneCore);
    if (cameras) {
      for (int i = 0; cameras[i]; i++) {
        if (!strstr(cameras[i], "StaticImage")) {
          target = [NSString stringWithUTF8String:cameras[i]]; break;
        }
      }
    }
  }
  if (target) {
    NSLog(@"[LinphoneManager] startVideoPreview: selecting camera=%@", target);
    linphone_core_set_video_device(theLinphoneCore, [target UTF8String]);
  }
  // Cycle capture off→on to force Linphone to open the front camera hardware.
  linphone_core_enable_video_capture(theLinphoneCore, NO);
  linphone_core_enable_video_preview(theLinphoneCore, NO);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    if (theLinphoneCore) {
      linphone_core_enable_video_capture(theLinphoneCore, YES);
      // Cycle preview off→on so ogl_display is re-created against the current preview window ID.
      linphone_core_enable_video_preview(theLinphoneCore, NO);
      linphone_core_enable_video_preview(theLinphoneCore, YES);
      NSLog(@"[LinphoneManager] startVideoPreview: capture+preview re-enabled with front camera");
    }
  });
  NSLog(@"[LinphoneManager] startVideoPreview done");
}

- (void)stopVideoPreview {
  if (!theLinphoneCore) return;
  linphone_core_enable_video_preview(theLinphoneCore, NO);
  linphone_core_set_native_video_window_id(theLinphoneCore, NULL);
  linphone_core_set_native_preview_window_id(theLinphoneCore, NULL);
  NSLog(@"[LinphoneManager] stopVideoPreview done");
}

- (int)conferenceDuration {
  if (!theLinphoneCore) return 0;
  LinphoneConference *conf = linphone_core_get_conference(theLinphoneCore);
  if (!conf) return 0;
  return (int)linphone_conference_get_duration(conf);
}

- (void)sendTextMessage:(NSString *)peerUri text:(NSString *)text requestId:(NSString *)requestId {
    if (!theLinphoneCore) return;
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return;

    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    linphone_address_unref(addr);

    if (!room) {
        // Mirror Android waitForRoomCreated failure path — emit NotDelivered so JS
        // can persist the message via FailedMessageUtils.
        NSLog(@"[LinphoneManager] sendTextMessage: failed to get chat room for %@", peerUri);
        if (requestId.length > 0) {
            NSDictionary *errDict = @{
                @"id":     requestId,
                @"status": @"NotDelivered",
                @"sender": @"me",
                @"type":   @"text",
                @"text":   text ?: @"",
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"LinphoneMessageStateChanged"
                                  object:nil
                                userInfo:errDict];
            });
        }
        return;
    }

    LinphoneChatMessage *msg = linphone_chat_room_create_message(room, text.UTF8String);
    if (requestId) {
        linphone_chat_message_add_custom_header(msg, "X-Request-ID", requestId.UTF8String);
    }
    LinphoneChatMessageCbs *msgCbs = linphone_chat_message_get_callbacks(msg);
    if (msgCbs) {
        linphone_chat_message_cbs_set_msg_state_changed(msgCbs, lm_chat_msg_state_changed);
    }
    linphone_chat_message_send(msg);
}

- (void)sendImageMessage:(NSString *)peerUri filePath:(NSString *)filePath requestId:(NSString *)requestId {
    if (!theLinphoneCore) return;
    LinphoneAddress *addr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!addr) return;

    LinphoneChatRoom *room = linphone_core_get_chat_room(theLinphoneCore, addr);
    linphone_address_unref(addr);

    if (!room) {
        // Mirror Android waitForRoomCreated failure path — emit NotDelivered.
        NSLog(@"[LinphoneManager] sendImageMessage: failed to get chat room for %@", peerUri);
        if (requestId.length > 0) {
            NSDictionary *errDict = @{
                @"id":     requestId,
                @"status": @"NotDelivered",
                @"sender": @"me",
                @"type":   @"image",
                @"text":   @"[Image]",
            };
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter]
                    postNotificationName:@"LinphoneMessageStateChanged"
                                  object:nil
                                userInfo:errDict];
            });
        }
        return;
    }

    // Derive file extension for subtype (e.g. "jpeg", "png")
    NSString *ext = filePath.pathExtension.lowercaseString;
    if (ext.length == 0) ext = @"jpeg";

    LinphoneChatMessage *msg = linphone_chat_room_create_empty_message(room);
    LinphoneContent *content = linphone_factory_create_content(linphone_factory_get());
    linphone_content_set_type(content, "image");
    linphone_content_set_subtype(content, ext.UTF8String);
    linphone_content_set_name(content, filePath.lastPathComponent.UTF8String);
    linphone_content_set_file_path(content, filePath.UTF8String);
    linphone_chat_message_add_file_content(msg, content);
    if (requestId) {
        linphone_chat_message_add_custom_header(msg, "X-Request-ID", requestId.UTF8String);
        linphone_chat_message_add_custom_header(msg, "X-Local-Filename", filePath.lastPathComponent.UTF8String);
    }
    LinphoneChatMessageCbs *msgCbs = linphone_chat_message_get_callbacks(msg);
    if (msgCbs) {
        linphone_chat_message_cbs_set_msg_state_changed(msgCbs, lm_img_msg_state_changed);
        linphone_chat_message_cbs_set_file_transfer_progress_indication(msgCbs, lm_img_progress);
    }
    linphone_chat_message_send(msg);
    linphone_content_unref(content);
}

// Returns the plain-text body of a chat message using the non-deprecated content API.
// Iterates contents and reads the first text/plain part via linphone_content_is_text +
// linphone_content_get_utf8_text, avoiding the deprecated linphone_chat_message_get_text_content.
static NSString *lm_getMessageText(LinphoneChatMessage *msg) {
    const bctbx_list_t *contents = linphone_chat_message_get_contents(msg);
    for (const bctbx_list_t *cit = contents; cit != NULL; cit = cit->next) {
        LinphoneContent *content = (LinphoneContent *)cit->data;
        if (linphone_content_is_text(content)) {
            const char *txt = linphone_content_get_utf8_text(content);
            return [NSString stringWithUTF8String:txt ?: ""];
        }
    }
    return @"";
}

// Returns YES if the message contains any image or file-transfer content.
// Mirrors Android hasFileContent: content.isFileTransfer || content.type == "image".
// Uses strstr to match "image/jpeg", "image/png", etc., not just exact "image".
static BOOL lm_hasFileContent(LinphoneChatMessage *msg) {
    const bctbx_list_t *contents = linphone_chat_message_get_contents(msg);
    for (const bctbx_list_t *cit = contents; cit != NULL; cit = cit->next) {
        LinphoneContent *content = (LinphoneContent *)cit->data;
        if (linphone_content_is_file_transfer(content)) return YES;
        const char *ctype = linphone_content_get_type(content);
        if (ctype && strstr(ctype, "image")) return YES;
    }
    return NO;
}

// Forward declaration — lm_chatMessageStateToString is defined after this method.
static NSString *lm_chatMessageStateToString(LinphoneChatMessageState state);

- (NSString *)getChatRoomsJSON {
    if (!theLinphoneCore) return @"[]";
    const bctbx_list_t *rooms = linphone_core_get_chat_rooms(theLinphoneCore);
    NSMutableArray *roomsArray = [NSMutableArray array];

    for (const bctbx_list_t *it = rooms; it != NULL; it = it->next) {
        LinphoneChatRoom *room = (LinphoneChatRoom *)it->data;
        const LinphoneAddress *peer = linphone_chat_room_get_peer_address(room);

        NSMutableDictionary *roomDict = [NSMutableDictionary dictionary];
        const char *peerUsernameC = linphone_address_get_username(peer) ?: "";
        const char *peerDNC       = linphone_address_get_display_name(peer);
        NSString *peerUsernameStr = [NSString stringWithUTF8String:peerUsernameC];
        NSString *peerUriStr      = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peer) ?: ""];

        roomDict[@"phoneNumber"] = peerUsernameStr;
        roomDict[@"displayName"] = [NSString stringWithUTF8String:(peerDNC && strlen(peerDNC) > 0) ? peerDNC : peerUsernameC];
        roomDict[@"peerUri"]     = peerUriStr;

        // localUsername — used by NativeModuleiOS getChatRooms to filter rooms per active account,
        // mirrors Android: room.localAddress.username == currentUsername
        const LinphoneAddress *localAddr = linphone_chat_room_get_local_address(room);
        const char *localUsernameC = (localAddr && linphone_address_get_username(localAddr))
                                     ? linphone_address_get_username(localAddr) : "";
        roomDict[@"localUsername"] = [NSString stringWithUTF8String:localUsernameC];

        // isMuted — mirrors Android: room.hasBeenLeft() || !room.isReadOnly
        BOOL hasLeft    = (BOOL)linphone_chat_room_has_been_left(room);
        BOOL isReadOnly = (BOOL)linphone_chat_room_is_read_only(room);
        roomDict[@"isMuted"] = @(hasLeft || !isReadOnly);

        // isGroup — mirrors Android: room.currentParams?.isGroupEnabled ?: false
        const LinphoneChatRoomParams *roomParams = linphone_chat_room_get_current_params(room);
        roomDict[@"isGroup"] = @(roomParams ? (BOOL)linphone_chat_room_params_group_enabled(roomParams) : NO);

        // Walk history newest-first, skipping X-CANS-CTRL control messages.
        // Mirrors Android processChatRoomToMap: for (i in history.indices.reversed()) { if ctrlHeader.isNullOrEmpty } }
        LinphoneChatMessage *lastMsg = nil;
        const bctbx_list_t *history = linphone_chat_room_get_history(room, 0);
        NSMutableArray *histArray = [NSMutableArray array];
        for (const bctbx_list_t *hit = history; hit != NULL; hit = hit->next) {
            [histArray addObject:[NSValue valueWithPointer:hit->data]];
        }
        for (NSInteger i = (NSInteger)histArray.count - 1; i >= 0; i--) {
            LinphoneChatMessage *candidate = (LinphoneChatMessage *)((NSValue *)histArray[(NSUInteger)i]).pointerValue;
            const char *ctrlHdr = linphone_chat_message_get_custom_header(candidate, "X-CANS-CTRL");
            if (!ctrlHdr || strlen(ctrlHdr) == 0) {
                lastMsg = candidate;
                break;
            }
        }

        if (lastMsg) {
            NSString *lastMsgText = @"";
            NSString *lastMsgType = @"text";

            // Determine message type from content — mirrors Android:
            // firstContent.isFileTransfer || firstContent.type?.contains("image") == true
            const bctbx_list_t *contents = linphone_chat_message_get_contents(lastMsg);
            BOOL foundImage = NO;
            for (const bctbx_list_t *cit = contents; cit != NULL && !foundImage; cit = cit->next) {
                LinphoneContent *c = (LinphoneContent *)cit->data;
                const char *ctype = linphone_content_get_type(c);
                if ((ctype && strstr(ctype, "image") != NULL) || linphone_content_is_file_transfer(c)) {
                    lastMsgType = @"image";
                    lastMsgText = @"Sent an image";
                    foundImage  = YES;
                }
            }
            if (!foundImage) {
                lastMsgText = lm_getMessageText(lastMsg);
                // XML body signals a multimedia/RCS message — mirrors Android trim().startsWith("<?xml")
                if ([lastMsgText hasPrefix:@"<?xml"]) {
                    lastMsgText = @"Multimedia message";
                }
            }

            roomDict[@"lastMessage"]     = lastMsgText;
            roomDict[@"lastMessageType"] = lastMsgType;
            roomDict[@"timestamp"]       = @(linphone_chat_message_get_time(lastMsg) * 1000.0);
            roomDict[@"isMe"]            = @((BOOL)linphone_chat_message_is_outgoing(lastMsg));
            roomDict[@"status"]          = lm_chatMessageStateToString(linphone_chat_message_get_state(lastMsg));

            // Unread count with Android correction: ensure >= 1 when the last message is
            // incoming and has not been read yet (linphone count can lag behind actual state).
            NSInteger unreadCount = (NSInteger)linphone_chat_room_get_unread_messages_count(room);
            if (unreadCount == 0
                    && !linphone_chat_message_is_outgoing(lastMsg)
                    && !linphone_chat_message_is_read(lastMsg)) {
                unreadCount = 1;
            }
            roomDict[@"unreadCount"] = @(unreadCount);
        } else {
            // No non-control message found — emit safe defaults matching Android's else-branch.
            roomDict[@"lastMessage"]     = @"";
            roomDict[@"lastMessageType"] = @"text";
            roomDict[@"timestamp"]       = @(0.0);
            roomDict[@"isMe"]            = @NO;
            roomDict[@"status"]          = @"None";
            roomDict[@"unreadCount"]     = @(0);
        }

        [roomsArray addObject:roomDict];
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:roomsArray options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Map LinphoneChatMessageState → JS status string (mirrors Android ChatMessage.State.name)
static NSString *lm_chatMessageStateToString(LinphoneChatMessageState state) {
    switch (state) {
        case LinphoneChatMessageStateIdle:                   return @"Idle";
        case LinphoneChatMessageStateInProgress:             return @"InProgress";
        case LinphoneChatMessageStateDelivered:              return @"Delivered";
        case LinphoneChatMessageStateNotDelivered:           return @"NotDelivered";
        case LinphoneChatMessageStateFileTransferError:      return @"FileTransferError";
        case LinphoneChatMessageStateFileTransferInProgress: return @"FileTransferInProgress";
        case LinphoneChatMessageStateDisplayed:              return @"Displayed";
        case LinphoneChatMessageStateDeliveredToUser:        return @"DeliveredToUser";
        case LinphoneChatMessageStateFileTransferDone:       return @"FileTransferDone";
        default:                                             return @"Delivered";
    }
}

// Fires when a LinphoneChatRoom changes state.  Mirrors Android coreListener.onChatRoomStateChanged:
// when the room reaches Created or Instantiated, post LinphoneChatRoomCreated so NativeModuleiOS
// can emit event_refresh to JS (keeping the chat-list current without a manual pull-to-refresh).
static void linphone_iphone_chat_room_state_changed(LinphoneCore *lc,
                                                     LinphoneChatRoom *room,
                                                     LinphoneChatRoomState state) {
    if (state != LinphoneChatRoomStateCreated && state != LinphoneChatRoomStateInstantiated) return;

    const LinphoneAddress *peer = linphone_chat_room_get_peer_address(room);
    if (!peer) return;

    NSString *peerUri      = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peer) ?: ""];
    NSString *peerUsername = [NSString stringWithUTF8String:linphone_address_get_username(peer) ?: ""];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"LinphoneChatRoomCreated"
                          object:nil
                        userInfo:@{ @"peerUri":      peerUri,
                                    @"peerUsername": peerUsername }];
    });
}

// Three-stage fallback — mirrors Android getOrCreateSpecificChatRoom(peerUri).
// Stage 1: direct lookup by peer + local address (fast path for existing rooms).
// Stage 2: broader search with Basic ChatRoomParams (catches rooms not in the address index).
// Stage 3: create a new Basic one-to-one chat room when none exists.
// Returns nil only when the core is unavailable or the address cannot be parsed.
- (nullable LinphoneChatRoom *)getOrCreateSpecificChatRoom:(NSString *)peerUri {
    if (!theLinphoneCore || !peerUri.length) return nil;

    LinphoneAccount *defaultAccount = linphone_core_get_default_account(theLinphoneCore);
    if (!defaultAccount) return nil;
    const LinphoneAddress *localAddr =
        linphone_account_params_get_identity_address(linphone_account_get_params(defaultAccount));
    if (!localAddr) return nil;

    LinphoneAddress *remoteAddr = linphone_core_interpret_url(theLinphoneCore, peerUri.UTF8String);
    if (!remoteAddr) return nil;
    linphone_address_clean(remoteAddr);

    LinphoneChatRoom *room = nil;

    char *peerStr = linphone_address_as_string(remoteAddr);
    char *localStr = linphone_address_as_string(localAddr);
    const char *peerUserC = linphone_address_get_username(remoteAddr);
    const char *localUserC = linphone_address_get_username(localAddr);
    NSString *targetPeer  = peerUserC  ? [NSString stringWithUTF8String:peerUserC]  : @"";
    NSString *targetLocal = localUserC ? [NSString stringWithUTF8String:localUserC] : @"";
    NSLog(@"[LinphoneManager] getOrCreateSpecificChatRoom: peer=%s local=%s peerUser=%@ localUser=%@",
          peerStr ?: "?", localStr ?: "?", targetPeer, targetLocal);
    if (peerStr) ms_free(peerStr);
    if (localStr) ms_free(localStr);

    // Stage 0: iterate the full room list (same source as getChatRoomsJSON).
    // Stage 1/2 use address-equality which can miss rooms whose DB address has
    // extra SIP parameters (e.g., gr=, transport=) that linphone_address_clean
    // doesn't strip from the stored form.
    if (targetPeer.length > 0 && targetLocal.length > 0) {
        const bctbx_list_t *allRooms = linphone_core_get_chat_rooms(theLinphoneCore);
        for (const bctbx_list_t *rit = allRooms; rit != NULL; rit = rit->next) {
            LinphoneChatRoom *r = (LinphoneChatRoom *)rit->data;
            const LinphoneAddress *rPeer  = linphone_chat_room_get_peer_address(r);
            const LinphoneAddress *rLocal = linphone_chat_room_get_local_address(r);
            const char *rPeerU  = rPeer  ? linphone_address_get_username(rPeer)  : NULL;
            const char *rLocalU = rLocal ? linphone_address_get_username(rLocal) : NULL;
            const char *rPeerD  = rPeer  ? linphone_address_get_domain(rPeer)    : NULL;
            const char *rLocalD = rLocal ? linphone_address_get_domain(rLocal)   : NULL;
            const char *peerDomainC  = linphone_address_get_domain(remoteAddr);
            const char *localDomainC = linphone_address_get_domain(localAddr);
            if (rPeerU && rLocalU && rPeerD && rLocalD && peerUserC && localUserC && peerDomainC && localDomainC
                && strcmp(rPeerU, peerUserC) == 0
                && strcmp(rLocalU, localUserC) == 0
                && strcmp(rPeerD, peerDomainC) == 0
                && strcmp(rLocalD, localDomainC) == 0) {
                room = r;
                break;
            }
        }
        NSLog(@"[LinphoneManager] getOrCreateSpecificChatRoom: stage0=%p", room);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Stage 1: direct peer + local address lookup
    if (!room) {
        room = linphone_core_get_chat_room_2(theLinphoneCore, remoteAddr, localAddr);
        NSLog(@"[LinphoneManager] getOrCreateSpecificChatRoom: stage1=%p", room);
    }

    if (!room) {
        // Stage 2: broader search with Basic params
        LinphoneChatRoomParams *params = linphone_core_create_default_chat_room_params(theLinphoneCore);
        if (params) {
            linphone_chat_room_params_set_backend(params, LinphoneChatRoomBackendBasic);
            linphone_chat_room_params_enable_group(params, FALSE);
            bctbx_list_t *participants = bctbx_list_append(NULL, remoteAddr);
            room = linphone_core_search_chat_room(theLinphoneCore, params, localAddr, remoteAddr, participants);
            bctbx_list_free(participants);
            linphone_chat_room_params_unref(params);
        }
        NSLog(@"[LinphoneManager] getOrCreateSpecificChatRoom: stage2=%p", room);
    }

    if (!room) {
        // Stage 3: create a new Basic chat room
        NSLog(@"[LinphoneManager] getOrCreateSpecificChatRoom: stage3 creating new room (no existing room found)");
        LinphoneChatRoomParams *params = linphone_core_create_default_chat_room_params(theLinphoneCore);
        if (params) {
            linphone_chat_room_params_set_backend(params, LinphoneChatRoomBackendBasic);
            linphone_chat_room_params_enable_group(params, FALSE);
            bctbx_list_t *participants = bctbx_list_append(NULL, remoteAddr);
            room = linphone_core_create_chat_room_6(theLinphoneCore, params, localAddr, participants);
            bctbx_list_free(participants);
            linphone_chat_room_params_unref(params);
        }
        NSLog(@"[LinphoneManager] getOrCreateSpecificChatRoom: stage3=%p", room);
    }
#pragma clang diagnostic pop

    linphone_address_unref(remoteAddr);

    if (room) {
        linphone_chat_room_mark_as_read(room);
    }
    return room;
}

- (NSString *)getChatHistoryJSON:(NSString *)peerUri {
    if (!theLinphoneCore) return @"[]";

    // Use getOrCreateSpecificChatRoom so history loads for first-contact peers (room may
    // not exist yet when the other side sent first).  Mirrors Android getChatHistory which
    // calls getOrCreateSpecificChatRoom before iterating room.getHistory(0).
    LinphoneChatRoom *room = [self getOrCreateSpecificChatRoom:peerUri];
    NSLog(@"[LinphoneManager] getChatHistoryJSON: peerUri=%@ room=%p", peerUri, room);
    NSMutableArray *messagesArray = [NSMutableArray array];

    if (room) {
        // mark_as_read already called inside getOrCreateSpecificChatRoom

        const bctbx_list_t *history = linphone_chat_room_get_history(room, 0);
        int historyCount = (int)bctbx_list_size(history);
        const LinphoneAddress *peerAddr = linphone_chat_room_get_peer_address(room);
        NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peerAddr) ?: ""];
        NSLog(@"[LinphoneManager] getChatHistoryJSON: room=%p peer=%@ historyCount=%d", room, chatWith, historyCount);

        for (const bctbx_list_t *it = history; it != NULL; it = it->next) {
            LinphoneChatMessage *msg = (LinphoneChatMessage *)it->data;

            // Skip X-CANS-CTRL control messages (camera-state signals) — never show in chat UI.
            const char *ctrlHdr = linphone_chat_message_get_custom_header(msg, "X-CANS-CTRL");
            if (ctrlHdr && strlen(ctrlHdr) > 0) continue;

            // ── id: prefer X-Request-ID header, fallback to native messageId ──
            const char *requestIdC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
            NSString *msgId;
            if (requestIdC && strlen(requestIdC) > 0) {
                msgId = [NSString stringWithUTF8String:requestIdC];
            } else {
                const char *nativeIdC = linphone_chat_message_get_message_id(msg);
                if (nativeIdC && strlen(nativeIdC) > 0) {
                    msgId = [NSString stringWithUTF8String:nativeIdC];
                } else {
                    msgId = [NSString stringWithFormat:@"msg_%ld_%p",
                             (long)linphone_chat_message_get_time(msg), msg];
                }
            }

            // ── text and image content ──
            NSString *textContent = lm_getMessageText(msg);
            BOOL isImage = lm_hasFileContent(msg);
            NSString *imagePath = @"";

            if (isImage) {
                const bctbx_list_t *contents = linphone_chat_message_get_contents(msg);
                for (const bctbx_list_t *cit = contents; cit != NULL; cit = cit->next) {
                    LinphoneContent *content = (LinphoneContent *)cit->data;
                    const char *fp = linphone_content_get_file_path(content);
                    if (fp && strlen(fp) > 0) {
                        imagePath = [NSString stringWithFormat:@"file://%s", fp];
                        break;
                    }
                }
            }

            // Treat XML file-info body (legacy SIP file-transfer) as image
            if (!isImage && [textContent hasPrefix:@"<?xml"] && [textContent containsString:@"file-info"]) {
                isImage = YES;
                textContent = @"";
            }

            NSMutableDictionary *msgDict = [NSMutableDictionary dictionary];
            msgDict[@"id"]        = msgId;
            msgDict[@"timestamp"] = @(linphone_chat_message_get_time(msg) * 1000.0);
            msgDict[@"sender"]    = linphone_chat_message_is_outgoing(msg) ? @"me" : @"other";
            msgDict[@"isRead"]    = @(linphone_chat_message_is_read(msg));
            msgDict[@"status"]    = lm_chatMessageStateToString(linphone_chat_message_get_state(msg));
            msgDict[@"chatWith"]  = chatWith;
            if (isImage) {
                msgDict[@"type"]     = @"image";
                msgDict[@"text"]     = @"[Image]";
                msgDict[@"imageUri"] = imagePath;
            } else {
                msgDict[@"type"]     = @"text";
                msgDict[@"text"]     = textContent;
                msgDict[@"imageUri"] = @"";
            }

            [messagesArray addObject:msgDict];
        }
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:messagesArray options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
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

// Mirrors Android NativeModuleAndroid.chatCleanupAll.
// Deletes all chat rooms + history and clears call logs.
// FailedMessageUtils.clearAllFailedMessages is called by NativeModuleiOS before this.
- (void)chatCleanupAll {
    if (!theLinphoneCore) return;
    // Collect room pointers before iterating (list can change during deletion).
    NSMutableArray *roomPtrs = [NSMutableArray array];
    const bctbx_list_t *rooms = linphone_core_get_chat_rooms(theLinphoneCore);
    for (const bctbx_list_t *it = rooms; it != NULL; it = it->next) {
        [roomPtrs addObject:[NSValue valueWithPointer:it->data]];
    }
    for (NSValue *v in roomPtrs) {
        LinphoneChatRoom *room = (LinphoneChatRoom *)v.pointerValue;
        linphone_chat_room_delete_history(room);
        linphone_core_delete_chat_room(theLinphoneCore, room);
    }
    linphone_core_clear_call_logs(theLinphoneCore);
    NSLog(@"[LinphoneManager] chatCleanupAll: deleted %lu rooms, cleared call logs",
          (unsigned long)roomPtrs.count);
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
    linphone_core_set_file_transfer_server(theLinphoneCore, "https://files.linphone.org/http-file-transfer-server/hft.php");

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
    [self chatCleanupAll];
    linphone_core_clear_accounts(theLinphoneCore);
}

#pragma mark - Chat Callbacks

static void linphone_iphone_message_received(LinphoneCore *lc, LinphoneChatRoom *room, LinphoneChatMessage *message) {
    const LinphoneAddress *dbgPeer = linphone_chat_room_get_peer_address(room);
    NSString *dbgPeerUser = [NSString stringWithUTF8String:linphone_address_get_username(dbgPeer) ?: ""];
    NSLog(@"[LinphoneManager] message_received: from=%@", dbgPeerUser);

    // Skip IMDN delivery/read receipts — they are SIP control messages, not chat messages.
    // The server forwards them as MESSAGE with Content-Type: message/imdn+xml which Linphone
    // fires through message_received; without this guard they render as empty bubbles.
    const bctbx_list_t *earlyContents = linphone_chat_message_get_contents(message);
    for (const bctbx_list_t *eit = earlyContents; eit != NULL; eit = eit->next) {
        LinphoneContent *content = (LinphoneContent *)eit->data;
        const char *ctype    = linphone_content_get_type(content);
        const char *csubtype = linphone_content_get_subtype(content);
        if (ctype && csubtype &&
            strcmp(ctype, "message") == 0 && strcmp(csubtype, "imdn+xml") == 0) {
            NSLog(@"[LinphoneManager] message_received: skipping IMDN receipt");
            return;
        }
    }

    // Intercept X-CANS-CTRL camera-state control messages — convert to video state event,
    // never show in chat UI. Mirrors Android NativeModuleAndroid onMessageReceived guard.
    const char *ctrlHeader = linphone_chat_message_get_custom_header(message, "X-CANS-CTRL");
    if (ctrlHeader && strlen(ctrlHeader) > 0) {
        NSString *ctrlValue = [NSString stringWithUTF8String:ctrlHeader];
        NSLog(@"[LinphoneManager] message_received: X-CANS-CTRL=%@ → remote video state", ctrlValue);
        BOOL enabled = [ctrlValue isEqualToString:@"video-state:on"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:kLinphoneRemoteVideoStateUpdate
                              object:nil
                            userInfo:@{@"enabled": @(enabled)}];
        });
        linphone_chat_room_mark_as_read(room);
        return;
    }

    // id: X-Request-ID preferred, fallback to native messageId
    const char *requestIdC = linphone_chat_message_get_custom_header(message, "X-Request-ID");
    NSString *msgId;
    if (requestIdC && strlen(requestIdC) > 0) {
        msgId = [NSString stringWithUTF8String:requestIdC];
    } else {
        const char *nativeIdC = linphone_chat_message_get_message_id(message);
        msgId = (nativeIdC && strlen(nativeIdC) > 0)
            ? [NSString stringWithUTF8String:nativeIdC]
            : [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(message)];
    }

    NSString *text = lm_getMessageText(message);

    BOOL isImage          = NO;
    BOOL attachedDownloadCbs = NO;
    NSString *imagePath = @"";
    const bctbx_list_t *contents = linphone_chat_message_get_contents(message);
    for (const bctbx_list_t *cit = contents; cit != NULL; cit = cit->next) {
        LinphoneContent *content = (LinphoneContent *)cit->data;
        const char *ctype = linphone_content_get_type(content);
        if (ctype && strcmp(ctype, "image") == 0) {
            isImage = YES;
            const char *fp = linphone_content_get_file_path(content);
            if (fp && strlen(fp) > 0) {
                imagePath = [NSString stringWithFormat:@"file://%s", fp];
            }
            break;
        }
        // RCS file-transfer envelope (application/vnd.gsma.rcs-ft-http+xml) —
        // the actual file must be downloaded before we have a local path.
        if (linphone_content_is_file_transfer(content)) {
            isImage = YES;
            const char *existingPath = linphone_content_get_file_path(content);
            if (existingPath && strlen(existingPath) > 0) {
                imagePath = [NSString stringWithFormat:@"file://%s", existingPath];
            } else {
                // Set a local destination path so Linphone knows where to write the file.
                const char *nameC = linphone_content_get_name(content);
                NSString *fileName = (nameC && strlen(nameC) > 0)
                    ? [NSString stringWithUTF8String:nameC]
                    : [NSString stringWithFormat:@"img_%ld.jpeg",
                       (long)linphone_chat_message_get_time(message)];
                NSString *docs = NSSearchPathForDirectoriesInDomains(
                    NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
                NSString *localPath = [docs stringByAppendingPathComponent:fileName];
                linphone_content_set_file_path(content, localPath.UTF8String);

                // Attach per-message callbacks and start the download.
                // lm_incoming_img_state_changed handles both FileTransferDone and delivery
                // states for these messages — do not overwrite with lm_incoming_msg_state_changed.
                LinphoneChatMessageCbs *msgCbs = linphone_chat_message_get_callbacks(message);
                if (msgCbs) {
                    linphone_chat_message_cbs_set_msg_state_changed(msgCbs, lm_incoming_img_state_changed);
                    linphone_chat_message_cbs_set_file_transfer_progress_indication(msgCbs, lm_img_progress);
                    attachedDownloadCbs = YES;
                }
                linphone_chat_message_download_content(message, content);
                NSLog(@"[LinphoneManager] message_received: incoming image download started → %@", localPath);
            }
            break;
        }
    }
    if (!isImage && [text hasPrefix:@"<?xml"] && [text containsString:@"file-info"]) {
        isImage = YES;
        text = @"";
    }

    // Attach delivery-status monitor to incoming messages whose default Cbs slot is still free
    // (text messages and already-downloaded images). Mirrors Android monitorMessageStatus which
    // calls message.addListener(ChatMessageListenerStub) for every incoming message.
    // File-transfer images already have lm_incoming_img_state_changed on the Cbs slot —
    // that callback now also handles Delivered/DeliveredToUser/Displayed forwarding.
    if (!attachedDownloadCbs) {
        LinphoneChatMessageCbs *msgCbs = linphone_chat_message_get_callbacks(message);
        if (msgCbs) {
            linphone_chat_message_cbs_set_msg_state_changed(msgCbs, lm_incoming_msg_state_changed);
        }
    }

    NSLog(@"[LinphoneManager] message_received: text='%@' isImage=%d", text, isImage);

    if (!isImage && [text length] == 0) {
        NSLog(@"[LinphoneManager] message_received: skipping empty-content message");
        return;
    }

    const LinphoneAddress *peerAddr = linphone_chat_room_get_peer_address(room);
    NSString *peerUri = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peerAddr) ?: ""];
    NSString *peerUser = [NSString stringWithUTF8String:linphone_address_get_username(peerAddr) ?: ""];

    NSDictionary *dict = @{
        @"id":        msgId,
        @"sender":    @"other",
        @"text":      isImage ? @"[Image]" : text,
        @"timestamp": @(linphone_chat_message_get_time(message) * 1000.0),
        @"peerUri":   peerUri,
        @"chatWith":  peerUser,
        @"type":      isImage ? @"image" : @"text",
        @"status":    @"Delivered",
        @"isRead":    @NO,
        @"imageUri":  imagePath,
    };

    [[NSNotificationCenter defaultCenter] postNotificationName:@"LinphoneMessageReceived" object:nil userInfo:dict];
}

// Per-message callback — Linphone 5.x per-message Cbs API.
// linphone_core_cbs_set_chat_message_state_changed does not exist on CoreCbs;
// this function is set individually on each outgoing message via linphone_chat_message_get_callbacks().
static void lm_chat_msg_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state) {
    const char *requestIdC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
    NSString *msgId;
    if (requestIdC && strlen(requestIdC) > 0) {
        msgId = [NSString stringWithUTF8String:requestIdC];
    } else {
        const char *nativeIdC = linphone_chat_message_get_message_id(msg);
        if (nativeIdC && strlen(nativeIdC) > 0) {
            msgId = [NSString stringWithUTF8String:nativeIdC];
        } else {
            msgId = [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(msg)];
        }
    }

    BOOL isOutgoing = linphone_chat_message_is_outgoing(msg);
    LinphoneChatRoom *room = linphone_chat_message_get_chat_room(msg);
    const LinphoneAddress *peerAddr = linphone_chat_room_get_peer_address(room);
    NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peerAddr) ?: ""];

    NSString *statusStr = lm_chatMessageStateToString(state);
    NSLog(@"[LinphoneManager] lm_chat_msg_state_changed: id=%@, status=%@, chatWith=%@", msgId, statusStr, chatWith);

    NSDictionary *dict = @{
        @"id":        msgId,
        @"status":    statusStr,
        @"sender":    isOutgoing ? @"me" : @"other",
        @"timestamp": @(linphone_chat_message_get_time(msg) * 1000.0),
        @"chatWith":  chatWith,
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LinphoneMessageStateChanged" object:nil userInfo:dict];
    });
}

// Mirrors Android monitorMessageStatus — attaches a ChatMessageListenerStub to each
// received message so that Delivered / DeliveredToUser / Displayed state transitions
// are forwarded to JS as onMessageStatusChanged events (read-receipt / delivery icons).
// Deactivates itself on terminal states by nulling the callback pointer, which is the
// C equivalent of Android's msg.removeListener(this).
static void lm_incoming_msg_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state) {
    const char *requestIdC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
    NSString *msgId;
    if (requestIdC && strlen(requestIdC) > 0) {
        msgId = [NSString stringWithUTF8String:requestIdC];
    } else {
        const char *nativeIdC = linphone_chat_message_get_message_id(msg);
        if (nativeIdC && strlen(nativeIdC) > 0) {
            msgId = [NSString stringWithUTF8String:nativeIdC];
        } else {
            msgId = [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(msg)];
        }
    }

    LinphoneChatRoom *room     = linphone_chat_message_get_chat_room(msg);
    const LinphoneAddress *peer = linphone_chat_room_get_peer_address(room);
    NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peer) ?: ""];

    NSString *statusStr = lm_chatMessageStateToString(state);
    NSLog(@"[LinphoneManager] lm_incoming_msg_state_changed: id=%@, status=%@, chatWith=%@",
          msgId, statusStr, chatWith);

    NSDictionary *dict = @{
        @"id":        msgId,
        @"status":    statusStr,
        @"sender":    @"other",
        @"timestamp": @(linphone_chat_message_get_time(msg) * 1000.0),
        @"chatWith":  chatWith,
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"LinphoneMessageStateChanged"
                          object:nil
                        userInfo:dict];
    });

    // Deactivate on terminal states — mirrors Android msg.removeListener(this).
    // Setting the pointer to NULL stops further firings; the Cbs object is owned
    // by the message and will be freed when the message is released.
    BOOL isTerminal = (state == LinphoneChatMessageStateDisplayed      ||
                       state == LinphoneChatMessageStateNotDelivered    ||
                       state == LinphoneChatMessageStateFileTransferError);
    if (isTerminal) {
        LinphoneChatMessageCbs *cbs = linphone_chat_message_get_callbacks(msg);
        if (cbs) {
            linphone_chat_message_cbs_set_msg_state_changed(cbs, NULL);
        }
    }
}

// Image message state-change callback — emits full content (including imageUri) via
// "LinphoneMessageReceived" so the JS onMessageReceived handler can update imageUri.
static void lm_img_msg_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state) {
    const char *requestIdC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
    NSString *msgId;
    if (requestIdC && strlen(requestIdC) > 0) {
        msgId = [NSString stringWithUTF8String:requestIdC];
    } else {
        const char *nativeIdC = linphone_chat_message_get_message_id(msg);
        if (nativeIdC && strlen(nativeIdC) > 0) {
            msgId = [NSString stringWithUTF8String:nativeIdC];
        } else {
            msgId = [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(msg)];
        }
    }

    LinphoneChatRoom *room = linphone_chat_message_get_chat_room(msg);
    const LinphoneAddress *peerAddr = linphone_chat_room_get_peer_address(room);
    NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peerAddr) ?: ""];
    NSString *peerUri  = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peerAddr) ?: ""];

    NSString *imagePath = @"";
    const bctbx_list_t *contents = linphone_chat_message_get_contents(msg);
    for (const bctbx_list_t *cit = contents; cit != NULL; cit = cit->next) {
        LinphoneContent *content = (LinphoneContent *)cit->data;
        const char *ctype = linphone_content_get_type(content);
        if (ctype && strcmp(ctype, "image") == 0) {
            const char *fp = linphone_content_get_file_path(content);
            if (fp && strlen(fp) > 0) {
                imagePath = [NSString stringWithFormat:@"file://%s", fp];
            }
            break;
        }
    }

    BOOL isOutgoing = linphone_chat_message_is_outgoing(msg);
    NSString *statusStr = lm_chatMessageStateToString(state);
    NSLog(@"[LinphoneManager] lm_img_msg_state_changed: id=%@, status=%@, chatWith=%@", msgId, statusStr, chatWith);

    // Clean up stall-detection tracking on any terminal state.
    BOOL isTerminal = (state == LinphoneChatMessageStateDelivered ||
                       state == LinphoneChatMessageStateNotDelivered ||
                       state == LinphoneChatMessageStateFileTransferError ||
                       state == LinphoneChatMessageStateFileTransferDone ||
                       state == LinphoneChatMessageStateDisplayed);
    if (isTerminal && requestIdC && strlen(requestIdC) > 0) {
        NSString *reqIdCleanup = [NSString stringWithUTF8String:requestIdC];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (lm_timerGens)   [lm_timerGens   removeObjectForKey:reqIdCleanup];
            if (lm_lastOffsets) [lm_lastOffsets  removeObjectForKey:reqIdCleanup];
        });
    }

    NSDictionary *dict = @{
        @"id":        msgId,
        @"status":    statusStr,
        @"sender":    isOutgoing ? @"me" : @"other",
        @"timestamp": @(linphone_chat_message_get_time(msg) * 1000.0),
        @"chatWith":  chatWith,
        @"peerUri":   peerUri,
        @"type":      @"image",
        @"text":      @"[Image]",
        @"imageUri":  imagePath,
        @"isRead":    @YES,
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LinphoneMessageReceived" object:nil userInfo:dict];
    });
}

// Per-message state callback for INCOMING file-transfer downloads.
// Posts LinphoneMessageContentUpdated when the file is fully downloaded so JS can
// replace the placeholder image bubble with the real local URI.
static void lm_incoming_img_state_changed(LinphoneChatMessage *msg, LinphoneChatMessageState state) {
    // Forward delivery states (Delivered / DeliveredToUser / Displayed) to JS so that
    // read-receipt and delivery icons update for file-transfer image messages, matching
    // Android's monitorMessageStatus which attaches one listener to every received message.
    if (state == LinphoneChatMessageStateDelivered       ||
        state == LinphoneChatMessageStateDeliveredToUser ||
        state == LinphoneChatMessageStateDisplayed) {

        const char *reqC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
        NSString *delivId;
        if (reqC && strlen(reqC) > 0) {
            delivId = [NSString stringWithUTF8String:reqC];
        } else {
            const char *nativeC = linphone_chat_message_get_message_id(msg);
            delivId = (nativeC && strlen(nativeC) > 0)
                ? [NSString stringWithUTF8String:nativeC]
                : [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(msg)];
        }
        LinphoneChatRoom *delivRoom    = linphone_chat_message_get_chat_room(msg);
        const LinphoneAddress *delivPeer = linphone_chat_room_get_peer_address(delivRoom);
        NSString *delivWith = [NSString stringWithUTF8String:linphone_address_get_username(delivPeer) ?: ""];
        NSString *delivStatus = lm_chatMessageStateToString(state);
        NSLog(@"[LinphoneManager] lm_incoming_img_state_changed: delivery id=%@ status=%@", delivId, delivStatus);

        NSDictionary *delivDict = @{
            @"id":        delivId,
            @"status":    delivStatus,
            @"sender":    @"other",
            @"timestamp": @(linphone_chat_message_get_time(msg) * 1000.0),
            @"chatWith":  delivWith,
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"LinphoneMessageStateChanged"
                              object:nil
                            userInfo:delivDict];
        });

        // Deactivate on Displayed (terminal) — keep alive through Delivered/DeliveredToUser
        // so FileTransferDone processing below can still run if it fires after Displayed.
        if (state == LinphoneChatMessageStateDisplayed) {
            LinphoneChatMessageCbs *cbs = linphone_chat_message_get_callbacks(msg);
            if (cbs) {
                linphone_chat_message_cbs_set_msg_state_changed(cbs, NULL);
            }
        }
        return;
    }

    if (state == LinphoneChatMessageStateFileTransferError ||
        state == LinphoneChatMessageStateNotDelivered) {
        NSLog(@"[LinphoneManager] lm_incoming_img_state_changed: download FAILED state=%d "
              @"(check disk space — ENOSPC causes silent failure)", (int)state);
        return;
    }
    if (state != LinphoneChatMessageStateFileTransferDone) return;

    const char *requestIdC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
    NSString *msgId;
    if (requestIdC && strlen(requestIdC) > 0) {
        msgId = [NSString stringWithUTF8String:requestIdC];
    } else {
        const char *nativeIdC = linphone_chat_message_get_message_id(msg);
        if (nativeIdC && strlen(nativeIdC) > 0) {
            msgId = [NSString stringWithUTF8String:nativeIdC];
        } else {
            msgId = [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(msg)];
        }
    }

    LinphoneChatRoom *room = linphone_chat_message_get_chat_room(msg);
    const LinphoneAddress *peerAddr = linphone_chat_room_get_peer_address(room);
    NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peerAddr) ?: ""];
    NSString *peerUri  = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peerAddr) ?: ""];

    // Find the downloaded file path from whichever content has one.
    NSString *imagePath = @"";
    const bctbx_list_t *contents = linphone_chat_message_get_contents(msg);
    for (const bctbx_list_t *cit = contents; cit != NULL; cit = cit->next) {
        LinphoneContent *content = (LinphoneContent *)cit->data;
        const char *fp = linphone_content_get_file_path(content);
        if (fp && strlen(fp) > 0) {
            imagePath = [NSString stringWithFormat:@"file://%s", fp];
            break;
        }
    }

    NSLog(@"[LinphoneManager] lm_incoming_img_state_changed: id=%@, chatWith=%@, path=%@",
          msgId, chatWith, imagePath);

    NSDictionary *dict = @{
        @"id":        msgId,
        @"chatWith":  chatWith,
        @"peerUri":   peerUri,
        @"imageUri":  imagePath,
        @"type":      @"image",
        @"text":      @"[Image]",
        @"status":    @"Delivered",
        @"sender":    @"other",
        @"isRead":    @NO,
        @"timestamp": @(linphone_chat_message_get_time(msg) * 1000.0),
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"LinphoneMessageContentUpdated"
                          object:nil
                        userInfo:dict];
    });
}

// ── Transfer stall detection ──────────────────────────────────────────────
// Mirrors Android NativeModuleAndroid.startTransferTimeout.
static NSMutableDictionary *lm_timerGens   = nil; // requestId → @(generation)
static NSMutableDictionary *lm_lastOffsets = nil; // requestId → @(lastOffset)

static void lm_startTransferTimeout(LinphoneChatMessage *msg, NSString *reqId, size_t currentOffset) {
    if (!lm_timerGens)   lm_timerGens   = [NSMutableDictionary dictionary];
    if (!lm_lastOffsets) lm_lastOffsets  = [NSMutableDictionary dictionary];

    NSInteger newGen = [lm_timerGens[reqId] integerValue] + 1;
    lm_timerGens[reqId] = @(newGen);
    NSInteger capturedGen = newGen;
    NSInteger capturedOff = (NSInteger)currentOffset;

    if (!lm_lastOffsets[reqId]) {
        lm_lastOffsets[reqId] = @(-1);
    }

    // Retain message so the pointer stays valid when the block fires 15 s later.
    linphone_chat_message_ref(msg);
    LinphoneChatMessage *capturedMsg = msg;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // Superseded by a newer timer — nothing to do.
        if ([lm_timerGens[reqId] integerValue] != capturedGen) {
            linphone_chat_message_unref(capturedMsg);
            return;
        }

        NSInteger lastOff = [lm_lastOffsets[reqId] integerValue];
        LinphoneChatMessageState state = linphone_chat_message_get_state(capturedMsg);
        BOOL stalled = (state == LinphoneChatMessageStateFileTransferInProgress)
                       && (capturedOff <= lastOff);

        if (stalled) {
            NSLog(@"[LinphoneManager] lm_startTransferTimeout: stall detected for %@ — cancelling", reqId);
            linphone_chat_message_cancel_file_transfer(capturedMsg);

            LinphoneChatRoom *room = linphone_chat_message_get_chat_room(capturedMsg);
            const LinphoneAddress *peer = linphone_chat_room_get_peer_address(room);
            NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peer) ?: ""];
            NSString *peerUri  = [NSString stringWithUTF8String:linphone_address_as_string_uri_only(peer) ?: ""];
            NSDictionary *errDict = @{
                @"id":        reqId,
                @"status":    @"FileTransferError",
                @"type":      @"image",
                @"text":      @"[Image]",
                @"imageUri":  @"",
                @"chatWith":  chatWith,
                @"peerUri":   peerUri,
                @"sender":    @"me",
                @"isRead":    @YES,
                @"timestamp": @(linphone_chat_message_get_time(capturedMsg) * 1000.0),
            };
            // Post to LinphoneMessageReceived (mirrors Android emitting onMessageReceived
            // from startTransferTimeout) so the chat bubble updates via onMessageReceived.
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"LinphoneMessageReceived"
                              object:nil
                            userInfo:errDict];
            [lm_timerGens   removeObjectForKey:reqId];
            [lm_lastOffsets  removeObjectForKey:reqId];
        } else {
            // Progress was made — record this offset for the next timer check.
            lm_lastOffsets[reqId] = @(capturedOff);
            [lm_timerGens   removeObjectForKey:reqId];
        }
        linphone_chat_message_unref(capturedMsg);
    });
}

// File transfer progress callback — fires for both upload and download.
static void lm_img_progress(LinphoneChatMessage *msg, LinphoneContent *content, size_t offset, size_t total) {
    const char *requestIdC = linphone_chat_message_get_custom_header(msg, "X-Request-ID");
    NSString *msgId;
    if (requestIdC && strlen(requestIdC) > 0) {
        msgId = [NSString stringWithUTF8String:requestIdC];
    } else {
        const char *nativeIdC = linphone_chat_message_get_message_id(msg);
        msgId = (nativeIdC && strlen(nativeIdC) > 0)
            ? [NSString stringWithUTF8String:nativeIdC]
            : [NSString stringWithFormat:@"msg_%ld", (long)linphone_chat_message_get_time(msg)];
    }

    int percent = (total > 0) ? (int)((offset * 100) / total) : 0;

    LinphoneChatRoom *room = linphone_chat_message_get_chat_room(msg);
    const LinphoneAddress *peerAddr = linphone_chat_room_get_peer_address(room);
    NSString *chatWith = [NSString stringWithUTF8String:linphone_address_get_username(peerAddr) ?: ""];

    NSDictionary *dict = @{
        @"id":       msgId,
        @"progress": @(percent),
        @"status":   @"FileTransferInProgress",
        @"chatWith": chatWith,
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LinphoneMessageProgress" object:nil userInfo:dict];
        // Start stall-detection timer for outgoing uploads only.
        if (linphone_chat_message_is_outgoing(msg) && requestIdC && strlen(requestIdC) > 0) {
            NSString *reqId = [NSString stringWithUTF8String:requestIdC];
            lm_startTransferTimeout(msg, reqId, offset);
        }
    });
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



// ── Push Notification ────────────────────────────────────────────────────

+ (BOOL)isCallKitEnabled {
#if !TARGET_OS_SIMULATOR
    return theLinphoneCore
        ? linphone_config_get_int(linphone_core_get_config(theLinphoneCore), "app", "use_callkit", 0) == 1
        : NO;
#else
    return NO;
#endif
}

- (void)injectVoIPToken:(NSString *)voipToken
             forAccount:(LinphoneAccount *)account
      completionHandler:(void (^)(BOOL))completion {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore || !voipToken.length) {
      if (completion) completion(NO);
      return;
    }
    LinphoneAccount *targetAcc = account ?: linphone_core_get_default_account(theLinphoneCore);
    if (!targetAcc) {
      NSLog(@"[LinphoneManager] injectVoIPToken: no account available");
      if (completion) completion(NO);
      return;
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    LinphoneAccountParams *params =
        linphone_account_params_clone(linphone_account_get_params(targetAcc));

    // Strip existing pn-* params, keep everything else (e.g. app-login-type=cans)
    const char *existing = linphone_account_params_get_contact_uri_parameters(params);
    NSString *existingStr = existing ? [NSString stringWithUTF8String:existing] : @"";
    NSMutableArray *cleanParts = [NSMutableArray array];
    for (NSString *part in [existingStr componentsSeparatedByString:@";"]) {
      if (part.length > 0 && ![part hasPrefix:@"pn-"]) {
        [cleanParts addObject:part];
      }
    }
    NSString *prefix = cleanParts.count > 0
        ? [[cleanParts componentsJoinedByString:@";"] stringByAppendingString:@";"]
        : @"";

    // APNs VoIP format: pn-param uses the .voip sub-bundle ID expected by the push server.
    // pn-timeout=60: gives FreeSWITCH 60 s to wait for re-registration after VoIP push wake-up.
    NSString *voipBundleId = [NSString stringWithFormat:@"%@.voip", bundleId];
    NSString *fullParams = [NSString stringWithFormat:
        @"%@pn-provider=apns;pn-param=%@;pn-prid=%@;pn-timeout=60",
        prefix, voipBundleId, voipToken];

    linphone_account_params_set_contact_uri_parameters(params, fullParams.UTF8String);
    linphone_account_params_set_push_notification_allowed(params, NO);
    linphone_account_set_params(targetAcc, params);
    linphone_account_params_unref(params);
    linphone_core_refresh_registers(theLinphoneCore);

    NSLog(@"[LinphoneManager] VoIP token injected (pn-param=%@)", voipBundleId);
    if (completion) completion(YES);
  });
}

- (void)injectFCMToken:(NSString *)fcmToken
            forAccount:(LinphoneAccount *)account
     completionHandler:(void (^)(BOOL))completion {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore || !fcmToken.length) {
      if (completion) completion(NO);
      return;
    }
    LinphoneAccount *targetAcc = account ?: linphone_core_get_default_account(theLinphoneCore);
    if (!targetAcc) {
      NSLog(@"[LinphoneManager] injectFCMToken: no account available");
      if (completion) completion(NO);
      return;
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    LinphoneAccountParams *params =
        linphone_account_params_clone(linphone_account_get_params(targetAcc));

    const char *existing = linphone_account_params_get_contact_uri_parameters(params);
    NSString *existingStr = existing ? [NSString stringWithUTF8String:existing] : @"";

    // VoIP APNs must remain the active push channel — it is the only mechanism that can
    // wake a force-killed app. If it is already set, skip FCM overwrite entirely.
    if ([existingStr containsString:@"pn-provider=apns"]) {
      NSLog(@"[LinphoneManager] injectFCMToken: VoIP APNs already registered — skipping FCM overwrite");
      linphone_account_params_unref(params);
      if (completion) completion(NO);
      return;
    }

    // Strip existing pn-* params, keep everything else (e.g. app-login-type=cans)
    NSMutableArray *cleanParts = [NSMutableArray array];
    for (NSString *part in [existingStr componentsSeparatedByString:@";"]) {
      if (part.length > 0 && ![part hasPrefix:@"pn-"]) {
        [cleanParts addObject:part];
      }
    }
    NSString *prefix = cleanParts.count > 0
        ? [[cleanParts componentsJoinedByString:@";"] stringByAppendingString:@";"]
        : @"";

    // Percent-encode the FCM token so ':' (and other SIP-special chars) don't cause
    // the Linphone SIP stack to wrap the value in SIP double-quotes.  When quoted,
    // FreeSWITCH passes the literal '"token"' string to FCM → delivery fails.
    NSCharacterSet *sipTokenChars = [NSCharacterSet
        characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"];
    NSString *encodedToken = [fcmToken
        stringByAddingPercentEncodingWithAllowedCharacters:sipTokenChars] ?: fcmToken;
    // pn-timeout=60: gives FreeSWITCH 60 s to wait for re-registration after push wake-up.
    NSString *fullParams = [NSString stringWithFormat:
        @"%@pn-provider=fcm;pn-param=%@;pn-prid=%@;pn-timeout=60",
        prefix, bundleId, encodedToken];

    linphone_account_params_set_contact_uri_parameters(params, fullParams.UTF8String);
    linphone_account_params_set_push_notification_allowed(params, NO); // disable built-in push
    linphone_account_set_params(targetAcc, params);
    linphone_account_params_unref(params);
    linphone_core_refresh_registers(theLinphoneCore);

    NSLog(@"[LinphoneManager] FCM token injected (pn-param=%@)", bundleId);
    if (completion) completion(YES);
  });
}

- (void)removeFCMTokenForAccount:(LinphoneAccount *)account {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore) return;
    LinphoneAccount *targetAcc = account ?: linphone_core_get_default_account(theLinphoneCore);
    if (!targetAcc) return;

    LinphoneAccountParams *params =
        linphone_account_params_clone(linphone_account_get_params(targetAcc));
    const char *existing = linphone_account_params_get_contact_uri_parameters(params);
    NSString *existingStr = existing ? [NSString stringWithUTF8String:existing] : @"";
    NSMutableArray *cleanParts = [NSMutableArray array];
    for (NSString *part in [existingStr componentsSeparatedByString:@";"]) {
      if (part.length > 0 && ![part hasPrefix:@"pn-"]) {
        [cleanParts addObject:part];
      }
    }
    NSString *cleanParams = [cleanParts componentsJoinedByString:@";"];
    linphone_account_params_set_contact_uri_parameters(params, cleanParams.UTF8String);
    linphone_account_set_params(targetAcc, params);
    linphone_account_params_unref(params);
    linphone_core_refresh_registers(theLinphoneCore);
    NSLog(@"[LinphoneManager] FCM pn-* params removed from contact URI");
  });
}

- (void)processPushNotification:(NSString *)callId {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!theLinphoneCore) return;
    if (callId.length > 0) {
      linphone_core_process_push_notification(theLinphoneCore, callId.UTF8String);
    } else {
      linphone_core_refresh_registers(theLinphoneCore);
    }
    NSLog(@"[LinphoneManager] processPushNotification: callId=%@",
          callId.length > 0 ? callId : @"(empty — refreshed registers)");
  });
}

- (BOOL)getPushNotification {
    if (!theLinphoneCore) return NO;
    LinphoneAccount *acc = linphone_core_get_default_account(theLinphoneCore);
    if (!acc) return NO;
    const char *cp = linphone_account_params_get_contact_uri_parameters(
        linphone_account_get_params(acc));
    NSString *cpStr = cp ? [NSString stringWithUTF8String:cp] : @"";
    return [cpStr containsString:@"pn-provider"];
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

#pragma clang diagnostic pop
