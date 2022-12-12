//
//  LinphoneManager.m
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 13/11/2565 BE.
//

#import "LinphoneManager.h"
#import <CansConnect/CansConnect-Swift.h>


static LinphoneCore *theLinphoneCore = nil;
static LinphoneManager *theLinphoneManager = nil;

NSString *const LINPHONERC_APPLICATION_KEY = @"app";

NSString *const kLinphoneCoreUpdate = @"LinphoneCoreUpdate";
NSString *const kLinphoneDisplayStatusUpdate = @"LinphoneDisplayStatusUpdate";
NSString *const kLinphoneMessageReceived = @"LinphoneMessageReceived";
NSString *const kLinphoneTextComposeEvent = @"LinphoneTextComposeStarted";
NSString *const kLinphoneCallUpdate = @"LinphoneCallUpdate";
NSString *const kLinphoneRegistrationUpdate = @"LinphoneRegistrationUpdate";
NSString *const kLinphoneAddressBookUpdate = @"LinphoneAddressBookUpdate";
NSString *const kLinphoneMainViewChange = @"LinphoneMainViewChange";
NSString *const kLinphoneLogsUpdate = @"LinphoneLogsUpdate";
NSString *const kLinphoneSettingsUpdate = @"LinphoneSettingsUpdate";
NSString *const kLinphoneBluetoothAvailabilityUpdate = @"LinphoneBluetoothAvailabilityUpdate";
NSString *const kLinphoneConfiguringStateUpdate = @"LinphoneConfiguringStateUpdate";
NSString *const kLinphoneGlobalStateUpdate = @"LinphoneGlobalStateUpdate";
NSString *const kLinphoneNotifyReceived = @"LinphoneNotifyReceived";
NSString *const kLinphoneNotifyPresenceReceivedForUriOrTel = @"LinphoneNotifyPresenceReceivedForUriOrTel";
NSString *const kLinphoneCallEncryptionChanged = @"LinphoneCallEncryptionChanged";
NSString *const kLinphoneFileTransferSendUpdate = @"LinphoneFileTransferSendUpdate";
NSString *const kLinphoneFileTransferRecvUpdate = @"LinphoneFileTransferRecvUpdate";
NSString *const kLinphoneQRCodeFound = @"LinphoneQRCodeFound";
NSString *const kLinphoneChatCreateViewChange = @"LinphoneChatCreateViewChange";
NSString *const kLinphoneMsgNotificationAppGroupId = @"group.cc.cans.canscloud.msgNotification";

extern void libmsamr_init(MSFactory *factory);
extern void libmsx264_init(MSFactory *factory);
extern void libmsopenh264_init(MSFactory *factory);
extern void libmssilk_init(MSFactory *factory);
extern void libmswebrtc_init(MSFactory *factory);
extern void libmscodec2_init(MSFactory *factory);


@interface LinphoneManager ()
    
@end


@implementation LinphoneManager

#pragma mark - Lifecycle Functions

- (id)init {
    if ((self = [super init])) {
        [self copyDefaultSettings];
        [self overrideDefaultSettings];
        
        [self lpConfigSetString:[LinphoneManager dataFile:@"linphone.db"] forKey:@"uri" inSection:@"storage"];
        [self lpConfigSetString:[LinphoneManager dataFile:@"x3dh.c25519.sqlite3"] forKey:@"x3dh_db_path" inSection:@"lime"];
        // set default values for first boot
        if ([self lpConfigStringForKey:@"debugenable_preference"] == nil) {
#ifdef DEBUG
            [self lpConfigSetInt:1 forKey:@"debugenable_preference"];
#else
            [self lpConfigSetInt:0 forKey:@"debugenable_preference"];
#endif
        }
        
        // by default if handle_content_encoding is not set, we use plain text for debug purposes only
        if ([self lpConfigStringForKey:@"handle_content_encoding" inSection:@"misc"] == nil) {
#ifdef DEBUG
            [self lpConfigSetString:@"none" forKey:@"handle_content_encoding" inSection:@"misc"];
#else
            [self lpConfigSetString:@"conflate" forKey:@"handle_content_encoding" inSection:@"misc"];
#endif
        }
        
        [self migrateFromUserPrefs];
        [self loadAvatar];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

+ (LinphoneManager *)instance {
    @synchronized(self) {
        if (theLinphoneManager == nil) {
            theLinphoneManager = [[LinphoneManager alloc] init];
        }
    }
    return theLinphoneManager;
}

- (void)overrideDefaultSettings {
    NSString *factory = [LinphoneManager bundleFile:@"linphonerc-factory"];
    
    _configDb = linphone_config_new_for_shared_core(kLinphoneMsgNotificationAppGroupId.UTF8String, @"linphonerc".UTF8String, factory.UTF8String);
    linphone_config_clean_entry(_configDb, "misc", "max_calls");
}

- (void)createLinphoneCore {
    [self migrationAllPre];
    if (theLinphoneCore != nil) {
        LOGI(@"linphonecore is already created");
        return;
    }

    // Set audio assets
    NSString *ring =
        ([LinphoneManager bundleFile:[self lpConfigStringForKey:@"local_ring" inSection:@"sound"].lastPathComponent]
         ?: [LinphoneManager bundleFile:@"notes_of_the_optimistic.caf"])
        .lastPathComponent;
    NSString *ringback =
        ([LinphoneManager bundleFile:[self lpConfigStringForKey:@"remote_ring" inSection:@"sound"].lastPathComponent]
         ?: [LinphoneManager bundleFile:@"ringback.wav"])
        .lastPathComponent;
    NSString *hold =
        ([LinphoneManager bundleFile:[self lpConfigStringForKey:@"hold_music" inSection:@"sound"].lastPathComponent]
         ?: [LinphoneManager bundleFile:@"hold.mkv"])
        .lastPathComponent;
    [self lpConfigSetString:[LinphoneManager bundleFile:ring] forKey:@"local_ring" inSection:@"sound"];
    [self lpConfigSetString:[LinphoneManager bundleFile:ringback] forKey:@"remote_ring" inSection:@"sound"];
    [self lpConfigSetString:[LinphoneManager bundleFile:hold] forKey:@"hold_music" inSection:@"sound"];
    
    LinphoneFactory *factory = linphone_factory_get();
    LinphoneCoreCbs *cbs = linphone_factory_create_core_cbs(factory);
    linphone_core_cbs_set_registration_state_changed(cbs,linphone_iphone_registration_state);
    linphone_core_cbs_set_notify_presence_received_for_uri_or_tel(cbs, linphone_iphone_notify_presence_received_for_uri_or_tel);
    linphone_core_cbs_set_authentication_requested(cbs, linphone_iphone_popup_password_request);
    linphone_core_cbs_set_transfer_state_changed(cbs, linphone_iphone_transfer_state_changed);
    linphone_core_cbs_set_is_composing_received(cbs, linphone_iphone_is_composing_received);
    linphone_core_cbs_set_configuring_status(cbs, linphone_iphone_configuring_status_changed);
    linphone_core_cbs_set_global_state_changed(cbs, linphone_iphone_global_state_changed);
    linphone_core_cbs_set_notify_received(cbs, linphone_iphone_notify_received);
    linphone_core_cbs_set_call_encryption_changed(cbs, linphone_iphone_call_encryption_changed);
    linphone_core_cbs_set_call_log_updated(cbs, linphone_iphone_call_log_updated);
    linphone_core_cbs_set_call_id_updated(cbs, linphone_iphone_call_id_updated);
    linphone_core_cbs_set_user_data(cbs, (__bridge void *)(self));
    
    theLinphoneCore = linphone_factory_create_shared_core_with_config(factory, _configDb, NULL, [kLinphoneMsgNotificationAppGroupId UTF8String], true);
    linphone_core_add_callbacks(theLinphoneCore, cbs);
    
    [CallManager.instance setCoreWithCore:theLinphoneCore];
    [CoreManager.instance setCoreWithCore:theLinphoneCore];
    [ConfigManager.instance setDbWithDb:_configDb];

    linphone_core_start(theLinphoneCore);

    // Let the core handle cbs
    linphone_core_cbs_unref(cbs);

    LOGI(@"Create linphonecore %p", theLinphoneCore);

    // Load plugins if available in the linphone SDK - otherwise these calls will do nothing
    MSFactory *f = linphone_core_get_ms_factory(theLinphoneCore);
    libmssilk_init(f);
    libmsamr_init(f);
    libmsx264_init(f);
    libmsopenh264_init(f);
    libmswebrtc_init(f);
    libmscodec2_init(f);

    linphone_core_reload_ms_plugins(theLinphoneCore, NULL);
    [self migrationAllPost];

    /* Use the rootca from framework, which is already set*/
    linphone_core_set_user_certificates_path(theLinphoneCore, [LinphoneManager cacheDirectory].UTF8String);

    /* The core will call the linphone_iphone_configuring_status_changed callback when the remote provisioning is loaded
       (or skipped).
       Wait for this to finish the code configuration */

    [NSNotificationCenter.defaultCenter addObserver:self
     selector:@selector(globalStateChangedNotificationHandler:)
     name:kLinphoneGlobalStateUpdate
     object:nil];
    
    [NSNotificationCenter.defaultCenter addObserver:self
     selector:@selector(configuringStateChangedNotificationHandler:)
     name:kLinphoneConfiguringStateUpdate
     object:nil];

    /*call iterate once immediately in order to initiate background connections with sip server or remote provisioning
     * grab, if any */
    [self iterate];
    // start scheduler
    [CoreManager.instance startIterateTimer];
}

- (void)registerSip {
    NSString *domain = @"test.cans.cc:8444";
    NSString *username = @"50101";
    NSString *pwd = @"p50101CANS";

    LinphoneAccountParams *accountParams =  linphone_core_create_account_params(LC);
    LinphoneAddress *addr = linphone_address_new(NULL);
    LinphoneAddress *tmpAddr = linphone_address_new([NSString stringWithFormat:@"sip:%@",domain].UTF8String);
    if (tmpAddr == nil) {
        return;
    }

    linphone_address_set_username(addr, username.UTF8String);
    linphone_address_set_port(addr, linphone_address_get_port(tmpAddr));
    linphone_address_set_domain(addr, linphone_address_get_domain(tmpAddr));
    linphone_account_params_set_identity_address(accountParams, addr);

    // set transport
    linphone_account_params_set_routes_addresses(accountParams, NULL);
    linphone_account_params_set_server_addr(accountParams, [NSString stringWithFormat:@"%s;transport=tcp", domain.UTF8String].UTF8String);

    linphone_account_params_set_publish_enabled(accountParams, FALSE);
    linphone_account_params_set_register_enabled(accountParams, TRUE);

    LinphoneAuthInfo *info = linphone_auth_info_new(linphone_address_get_username(addr), // username
                                                    NULL,                                // user id
                                                    pwd.UTF8String,                        // passwd
                                                    NULL,                                // ha1
                                                    linphone_address_get_domain(addr),   // realm - assumed to be domain
                                                    linphone_address_get_domain(addr)    // domain
                                                    );
    linphone_core_add_auth_info(LC, info);
    linphone_address_unref(addr);
    linphone_address_unref(tmpAddr);

    LinphoneAccount *account = linphone_core_create_account(LC, accountParams);
    linphone_account_params_unref(accountParams);
    if (account) {
        if (linphone_core_add_account(LC, account) != -1) {
            linphone_core_set_default_account(LC, account);
        }
    }
}

- (void)copyDefaultSettings {
    NSString *src = [LinphoneManager bundleFile:@"linphonerc"];
    NSString *dst = [LinphoneManager preferenceFile:@"linphonerc"];
    [LinphoneManager copyFile:src destination:dst override:FALSE ignore:FALSE];
}

// scheduling loop
- (void)iterate {
    linphone_core_iterate(theLinphoneCore);
}


// MARK: - Linphone Core Functions

+ (LinphoneCore *)getLc {
    if (theLinphoneCore == nil) {
        @throw([NSException exceptionWithName:@"LinphoneCoreException"
            reason:@"Linphone core not initialized yet"
            userInfo:nil]);
    }
    return theLinphoneCore;
}

#pragma mark - Migration

- (void)migrationAllPost {
    [self migrationLinphoneSettings];
    [self migrationPerAccount];
}

- (void)migrationAllPre {
    // migrate xmlrpc URL if needed
    if ([self lpConfigBoolForKey:@"migration_xmlrpc"] == NO) {
        [self lpConfigSetString:@"https://subscribe.linphone.org:444/wizard.php"
         forKey:@"xmlrpc_url"
         inSection:@"assistant"];
        [self lpConfigSetString:@"sip:rls@voxxycloud.com" forKey:@"rls_uri" inSection:@"sip"];
        [self lpConfigSetBool:YES forKey:@"migration_xmlrpc"];
    }
    [self lpConfigSetBool:NO forKey:@"store_friends" inSection:@"misc"]; //so far, storing friends in files is not needed. may change in the future.
}

static int check_should_migrate_images(void *data, int argc, char **argv, char **cnames) {
    *((BOOL *)data) = TRUE;
    return 0;
}

- (void)migrateFromUserPrefs {
    static NSString *migration_flag = @"userpref_migration_done";

    if (_configDb == nil)
        return;

    if ([self lpConfigIntForKey:migration_flag withDefault:0]) {
        return;
    }

    NSDictionary *defaults = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    NSArray *defaults_keys = [defaults allKeys];
    NSDictionary *values =
        @{ @"backgroundmode_preference" : @NO,
           @"debugenable_preference" : @NO,
           @"start_at_boot_preference" : @YES };
    BOOL shouldSync = FALSE;

    LOGI(@"%lu user prefs", (unsigned long)[defaults_keys count]);

    for (NSString *userpref in values) {
        if ([defaults_keys containsObject:userpref]) {
            LOGI(@"Migrating %@ from user preferences: %d", userpref, [[defaults objectForKey:userpref] boolValue]);
            [self lpConfigSetBool:[[defaults objectForKey:userpref] boolValue] forKey:userpref];
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:userpref];
            shouldSync = TRUE;
        } else if ([self lpConfigStringForKey:userpref] == nil) {
            // no default value found in our linphonerc, we need to add them
            [self lpConfigSetBool:[[values objectForKey:userpref] boolValue] forKey:userpref];
        }
    }

    if (shouldSync) {
        LOGI(@"Synchronizing...");
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
    
    // don't get back here in the future
    [self lpConfigSetBool:YES forKey:migration_flag];
}

- (void)migrationLinphoneSettings {
    /* AVPF migration */
    if ([self lpConfigBoolForKey:@"avpf_migration_done"] == FALSE) {
        const MSList *proxies = linphone_core_get_proxy_config_list(theLinphoneCore);
        while (proxies) {
            LinphoneProxyConfig *proxy = (LinphoneProxyConfig *)proxies->data;
            const char *addr = linphone_proxy_config_get_addr(proxy);
            // we want to enable AVPF for the proxies
            if (addr &&
                strstr(addr, [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
                      inSection:@"app"
                      withDefault:@"voxxycloud.com"]
                   .UTF8String) != 0) {
                LOGI(@"Migrating proxy config to use AVPF");
                linphone_proxy_config_set_avpf_mode(proxy, LinphoneAVPFEnabled);
            }
            proxies = proxies->next;
        }
        [self lpConfigSetBool:TRUE forKey:@"avpf_migration_done"];
    }
    /* Quality Reporting migration */
    if ([self lpConfigBoolForKey:@"quality_report_migration_done"] == FALSE) {
        const MSList *proxies = linphone_core_get_proxy_config_list(theLinphoneCore);
        while (proxies) {
            LinphoneProxyConfig *proxy = (LinphoneProxyConfig *)proxies->data;
            const char *addr = linphone_proxy_config_get_addr(proxy);
            // we want to enable quality reporting for the proxies that are on linphone.org
            if (addr &&
                strstr(addr, [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
                      inSection:@"app"
                      withDefault:@"voxxycloud.com"]
                   .UTF8String) != 0) {
                LOGI(@"Migrating proxy config to send quality report");
                linphone_proxy_config_set_quality_reporting_collector(
                                              proxy, "sip:voip-metrics@voxxycloud.com;transport=tls");
                linphone_proxy_config_set_quality_reporting_interval(proxy, 180);
                linphone_proxy_config_enable_quality_reporting(proxy, TRUE);
            }
            proxies = proxies->next;
        }
        [self lpConfigSetBool:TRUE forKey:@"quality_report_migration_done"];
    }
    /* File transfer migration */
    if ([self lpConfigBoolForKey:@"file_transfer_migration_done"] == FALSE) {
        const char *newURL = "https://www.linphone.org:444/lft.php";
        LOGI(@"Migrating sharing server url from %s to %s", linphone_core_get_file_transfer_server(LC), newURL);
        linphone_core_set_file_transfer_server(LC, newURL);
        [self lpConfigSetBool:TRUE forKey:@"file_transfer_migration_done"];
    }
    
    if ([self lpConfigBoolForKey:@"lime_migration_done"] == FALSE) {
        const MSList *proxies = linphone_core_get_proxy_config_list(LC);
        while (proxies) {
            if (!strcmp(linphone_proxy_config_get_domain((LinphoneProxyConfig *)proxies->data),"voxxycloud.com")) {
                linphone_core_set_lime_x3dh_server_url(LC, "https://lime.linphone.org/lime-server/lime-server.php");
                break;
            }
            proxies = proxies->next;
        }
        [self lpConfigSetBool:TRUE forKey:@"lime_migration_done"];
    }

    if ([self lpConfigBoolForKey:@"push_notification_migration_done"] == FALSE) {
        const MSList *proxies = linphone_core_get_proxy_config_list(LC);
        bool_t pushEnabled;
        while (proxies) {
            const char *refkey = linphone_proxy_config_get_ref_key(proxies->data);
            if (refkey) {
                pushEnabled = (strcmp(refkey, "push_notification") == 0);
            } else {
                pushEnabled = true;
            }
            linphone_proxy_config_set_push_notification_allowed(proxies->data, pushEnabled);
            proxies = proxies->next;
        }
        [self lpConfigSetBool:TRUE forKey:@"push_notification_migration_done"];
    }
}

- (void)migrationPerAccount {
    const bctbx_list_t * proxies = linphone_core_get_proxy_config_list(LC);
    NSString *appDomain  = [LinphoneManager.instance lpConfigStringForKey:@"domain_name"
                inSection:@"app"
                withDefault:@"voxxycloud.com"];
    while (proxies) {
        LinphoneProxyConfig *config = proxies->data;
        // can not create group chat without conference factory
        if (!linphone_proxy_config_get_conference_factory_uri(config)) {
            if (strcmp(appDomain.UTF8String, linphone_proxy_config_get_domain(config)) == 0) {
                linphone_proxy_config_set_conference_factory_uri(config, "sip:conference-factory@voxxycloud.com");
            }
        }
        proxies = proxies->next;
    }
    
    NSString *s = [self lpConfigStringForKey:@"pushnotification_preference"];
    if (s && s.boolValue) {
        LOGI(@"Migrating push notification per account, enabling for ALL");
        [self lpConfigSetBool:NO forKey:@"pushnotification_preference"];
        const MSList *proxies = linphone_core_get_proxy_config_list(LC);
        while (proxies) {
            linphone_proxy_config_set_push_notification_allowed(proxies->data, true);
            [self configurePushTokenForProxyConfig:proxies->data];
            proxies = proxies->next;
        }
    }
}

static void migrateWizardToAssistant(const char *entry, void *user_data) {
    LinphoneManager *thiz = (__bridge LinphoneManager *)(user_data);
    NSString *key = [NSString stringWithUTF8String:entry];
    [thiz lpConfigSetString:[thiz lpConfigStringForKey:key inSection:@"wizard"] forKey:key inSection:@"assistant"];
}


// MARK: - Transfert State Functions

static void linphone_iphone_transfer_state_changed(LinphoneCore *lc, LinphoneCall *call, LinphoneCallState state) {
    
}

// MARK: - Text Received Functions

static void linphone_iphone_call_id_updated(LinphoneCore *lc, const char *previous_call_id, const char *current_call_id) {
    [CallManager.instance updateCallIdWithPrevious:[NSString stringWithUTF8String:previous_call_id] current:[NSString stringWithUTF8String:current_call_id]];
}

static void linphone_iphone_call_log_updated(LinphoneCore *lc, LinphoneCallLog *newcl) {
    if (linphone_call_log_get_status(newcl) == LinphoneCallEarlyAborted) {
        const char *cid = linphone_call_log_get_call_id(newcl);
        if (cid) {
            [CallManager.instance markCallAsDeclinedWithCallId:[NSString stringWithUTF8String:cid]];
        }
    }
}

static void linphone_iphone_call_encryption_changed(LinphoneCore *lc, LinphoneCall *call, bool_t on,
                            const char *authentication_token) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onCallEncryptionChanged:lc call:call on:on token:authentication_token];
}

- (void)onCallEncryptionChanged:(LinphoneCore *)lc
call:(LinphoneCall *)call
on:(BOOL)on
token:(const char *)authentication_token {
    // Post event
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:[NSValue valueWithPointer:call] forKey:@"call"];
    [dict setObject:[NSNumber numberWithBool:on] forKey:@"on"];
    if (authentication_token) {
        [dict setObject:[NSString stringWithUTF8String:authentication_token] forKey:@"token"];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneCallEncryptionChanged object:self userInfo:dict];
}

static void linphone_iphone_notify_presence_received_for_uri_or_tel(LinphoneCore *lc, LinphoneFriend *lf,
                                    const char *uri_or_tel,
                                    const LinphonePresenceModel *presence_model) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onNotifyPresenceReceivedForUriOrTel:lc friend:lf uri:uri_or_tel presenceModel:presence_model];
}

- (void)onNotifyPresenceReceivedForUriOrTel:(LinphoneCore *)lc friend:(LinphoneFriend *)lf uri:(const char *)uri presenceModel:(const LinphonePresenceModel *)model {
    // Post event
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:[NSValue valueWithPointer:lf] forKey:@"friend"];
    [dict setObject:[NSValue valueWithPointer:uri] forKey:@"uri"];
    [dict setObject:[NSValue valueWithPointer:model] forKey:@"presence_model"];
    [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneNotifyPresenceReceivedForUriOrTel
     object:self
     userInfo:dict];
}

- (void)onNotifyReceived:(LinphoneCore *)lc event:(LinphoneEvent *)lev notifyEvent:(const char *)notified_event content:(const LinphoneContent *)body {
    // Post event
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    [dict setObject:[NSValue valueWithPointer:lev] forKey:@"event"];
    [dict setObject:[NSString stringWithUTF8String:notified_event] forKey:@"notified_event"];
    if (body != NULL) {
        [dict setObject:[NSValue valueWithPointer:body] forKey:@"content"];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneNotifyReceived object:self userInfo:dict];
}

static void linphone_iphone_notify_received(LinphoneCore *lc, LinphoneEvent *lev, const char *notified_event,
                        const LinphoneContent *body) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onNotifyReceived:lc event:lev notifyEvent:notified_event content:body];
}


// MARK: - Auth info Function

static void linphone_iphone_popup_password_request(LinphoneCore *lc, LinphoneAuthInfo *auth_info, LinphoneAuthMethod method) {
    // let the wizard handle its own errors
    const char * realmC = linphone_auth_info_get_realm(auth_info);
    const char * usernameC = linphone_auth_info_get_username(auth_info) ? : "";
    const char * domainC = linphone_auth_info_get_domain(auth_info) ? : "";
    
    // InstantMessageDeliveryNotifications from previous accounts can trigger some pop-up spam asking for indentification
    // Try to filter the popup password request to avoid displaying those that do not matter and can be handled through a simple warning
    const MSList *configList = linphone_core_get_proxy_config_list(LC);
    bool foundMatchingConfig = false;
    while (configList && !foundMatchingConfig) {
        const char * configUsername = linphone_proxy_config_get_identity(configList->data);
        const char * configDomain = linphone_proxy_config_get_domain(configList->data);
        foundMatchingConfig = (strcmp(configUsername, usernameC) == 0) && (strcmp(configDomain, domainC) == 0);
        configList = configList->next;
    }
    if (!foundMatchingConfig) {
        LOGW(@"Received an authentication request from %s@%s, but ignored it did not match any current user", usernameC, domainC);
        return;
    }

    NSString *realm = [NSString stringWithUTF8String:realmC?:domainC];
    NSString *username = [NSString stringWithUTF8String:usernameC];
    NSString *domain = [NSString stringWithUTF8String:domainC];
    
    NSLog(@"%@%@", @"Title : ", NSLocalizedString(@"Authentification needed", nil));
    NSLog(
          @"%@%@%@%@%@",
          @"Message : ",
          NSLocalizedString(@"Authentification needed", nil),
          NSLocalizedString(@"Connection failed because authentication is "
                            @"missing or invalid for %@@%@.\nYou can "
                            @"provide password again, or check your "
                            @"account configuration in the settings.", nil),
          username,
          realm);
    
    /*
     NSString *password = alertView.textFields[0].text;
     LinphoneAuthInfo *info =
     linphone_auth_info_new(username.UTF8String, NULL, password.UTF8String, NULL,
                            realm.UTF8String, domain.UTF8String);
     linphone_core_add_auth_info(LC, info);
     [CoreManager.instance refreshRegisters];
     */
}

// MARK: - Message composition start

- (void)onMessageComposeReceived:(LinphoneCore *)core forRoom:(LinphoneChatRoom *)room {
    [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneTextComposeEvent
     object:self
     userInfo:@{
            @"room" : [NSValue valueWithPointer:room]
                }];
}

static void linphone_iphone_is_composing_received(LinphoneCore *lc, LinphoneChatRoom *room) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onMessageComposeReceived:lc forRoom:room];
}

// MARK: - Registration State Functions

static void linphone_iphone_registration_state(LinphoneCore *lc, LinphoneProxyConfig *cfg,
                           LinphoneRegistrationState state, const char *message) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onRegister:lc cfg:cfg state:state message:message];
}

- (void)onRegister:(LinphoneCore *)lc cfg:(LinphoneProxyConfig *)cfg state:(LinphoneRegistrationState)state message:(const char *)cmessage {
    LOGI(@"New registration state: %s (message: %s)", linphone_registration_state_to_string(state), cmessage);

    LinphoneReason reason = linphone_proxy_config_get_error(cfg);
    NSString *message = nil;
    switch (reason) {
    case LinphoneReasonBadCredentials:
        message = NSLocalizedString(@"Bad credentials, check your account settings", nil);
        break;
    case LinphoneReasonNoResponse:
        message = NSLocalizedString(@"No response received from remote", nil);
        break;
    case LinphoneReasonUnsupportedContent:
        message = NSLocalizedString(@"Unsupported content", nil);
        break;
    case LinphoneReasonIOError:
        message = NSLocalizedString(@"Cannot reach the server: either it is an invalid address or it may be temporary down.", nil);
        break;
    case LinphoneReasonUnauthorized:
        message = NSLocalizedString(@"Operation is unauthorized because missing credential", nil);
        break;
    case LinphoneReasonNoMatch:
        message = NSLocalizedString(@"Operation could not be executed by server or remote client because it "
                        @"didn't have any context for it",
                        nil);
        break;
    case LinphoneReasonMovedPermanently:
        message = NSLocalizedString(@"Resource moved permanently", nil);
        break;
    case LinphoneReasonGone:
        message = NSLocalizedString(@"Resource no longer exists", nil);
        break;
    case LinphoneReasonTemporarilyUnavailable:
        message = NSLocalizedString(@"Temporarily unavailable", nil);
        break;
    case LinphoneReasonAddressIncomplete:
        message = NSLocalizedString(@"Address incomplete", nil);
        break;
    case LinphoneReasonNotImplemented:
        message = NSLocalizedString(@"Not implemented", nil);
        break;
    case LinphoneReasonBadGateway:
        message = NSLocalizedString(@"Bad gateway", nil);
        break;
    case LinphoneReasonServerTimeout:
        message = NSLocalizedString(@"Server timeout", nil);
        break;
    case LinphoneReasonNotAcceptable:
    case LinphoneReasonDoNotDisturb:
    case LinphoneReasonDeclined:
    case LinphoneReasonNotFound:
    case LinphoneReasonNotAnswered:
    case LinphoneReasonBusy:
    case LinphoneReasonNone:
    case LinphoneReasonBadEvent:
    case LinphoneReasonSessionIntervalTooSmall:
    case LinphoneReasonUnknown:
        message = NSLocalizedString(@"Unknown error", nil);
        break;
    }

    // Post event
    NSDictionary *dict = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:state], @"state",
         [NSValue valueWithPointer:cfg], @"cfg", message, @"message", nil];
    [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneRegistrationUpdate object:self userInfo:dict];
}

// MARK: - Configuring status changed

static void linphone_iphone_configuring_status_changed(LinphoneCore *lc, LinphoneConfiguringState status,
                               const char *message) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onConfiguringStatusChanged:status withMessage:message];
}

- (void)onConfiguringStatusChanged:(LinphoneConfiguringState)status withMessage:(const char *)message {
    LOGI(@"onConfiguringStatusChanged: %s %@", linphone_configuring_state_to_string(status),
         message ? [NSString stringWithFormat:@"(message: %s)", message] : @"");
    NSDictionary *dict = [NSDictionary
                  dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:status], @"state",
                  [NSString stringWithUTF8String:message ? message : ""], @"message", nil];

    // dispatch the notification asynchronously
    dispatch_async(dispatch_get_main_queue(), ^(void) {
            [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneConfiguringStateUpdate
             object:self
             userInfo:dict];
        });
}

- (void)configuringStateChangedNotificationHandler:(NSNotification *)notif {
    _wasRemoteProvisioned = ((LinphoneConfiguringState)[[[notif userInfo] valueForKey:@"state"] integerValue] ==
                 LinphoneConfiguringSuccessful);
    if (_wasRemoteProvisioned) {
        LinphoneProxyConfig *cfg = linphone_core_get_default_proxy_config(LC);
        if (cfg) {
            [self configurePushTokenForProxyConfig:cfg];
        }
    }
}

// MARK: - Global state change

static void linphone_iphone_global_state_changed(LinphoneCore *lc, LinphoneGlobalState gstate, const char *message) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onGlobalStateChanged:gstate withMessage:message];
}

- (void)onGlobalStateChanged:(LinphoneGlobalState)state withMessage:(const char *)message {
    LOGI(@"onGlobalStateChanged: %d (message: %s)", state, message);

    NSDictionary *dict = [NSDictionary
                  dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:state], @"state",
                  [NSString stringWithUTF8String:message ? message : ""], @"message", nil];

    if (theLinphoneCore && linphone_core_get_global_state(theLinphoneCore) == LinphoneGlobalOff) {
        [CoreManager.instance stopIterateTimer];
    }
    // dispatch the notification asynchronously
    dispatch_async(dispatch_get_main_queue(), ^(void) {
        if (theLinphoneCore && linphone_core_get_global_state(theLinphoneCore) != LinphoneGlobalOff)
            [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneGlobalStateUpdate object:self userInfo:dict];
    });
}

- (void)globalStateChangedNotificationHandler:(NSNotification *)notif {
    if ((LinphoneGlobalState)[[[notif userInfo] valueForKey:@"state"] integerValue] == LinphoneGlobalOn) {
//        [self finishCoreConfiguration];
    }
}

// MARK: - Misc Functions

+ (NSString *)bundleFile:(NSString *)file {
    return [[NSBundle mainBundle] pathForResource:[file stringByDeletingPathExtension] ofType:[file pathExtension]];
}

+ (NSString *)preferenceFile:(NSString *)file {
    LinphoneFactory *factory = linphone_factory_get();
    NSString *fullPath = [NSString stringWithUTF8String:linphone_factory_get_config_dir(factory, kLinphoneMsgNotificationAppGroupId.UTF8String)];
    return [fullPath stringByAppendingPathComponent:file];
}

+ (NSString *)dataFile:(NSString *)file {
    LinphoneFactory *factory = linphone_factory_get();
    NSString *fullPath = [NSString stringWithUTF8String:linphone_factory_get_data_dir(factory, kLinphoneMsgNotificationAppGroupId.UTF8String)];
    return [fullPath stringByAppendingPathComponent:file];
}

+ (NSString *)cacheDirectory {
    LinphoneFactory *factory = linphone_factory_get();
    NSString *cachePath = [NSString stringWithUTF8String:linphone_factory_get_download_dir(factory, kLinphoneMsgNotificationAppGroupId.UTF8String)];
    BOOL isDir = NO;
    NSError *error;
    // cache directory must be created if not existing
    if (![[NSFileManager defaultManager] fileExistsAtPath:cachePath isDirectory:&isDir] && isDir == NO) {
        [[NSFileManager defaultManager] createDirectoryAtPath:cachePath
         withIntermediateDirectories:NO
         attributes:nil
         error:&error];
    }
    return cachePath;
}

#pragma mark - LPConfig Functions

- (void)lpConfigSetInt:(int)value forKey:(NSString *)key {
    [self lpConfigSetInt:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}

- (void)lpConfigSetInt:(int)value forKey:(NSString *)key inSection:(NSString *)section {
    if (!key)
        return;
    linphone_config_set_int(_configDb, [section UTF8String], [key UTF8String], (int)value);
}

- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key {
    [self lpConfigSetString:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}

- (void)lpConfigSetString:(NSString *)value forKey:(NSString *)key inSection:(NSString *)section {
    if (!key)
        return;
    linphone_config_set_string(_configDb, [section UTF8String], [key UTF8String], value ? [value UTF8String] : NULL);
}

- (NSString *)lpConfigStringForKey:(NSString *)key {
    return [self lpConfigStringForKey:key withDefault:nil];
}

- (NSString *)lpConfigStringForKey:(NSString *)key withDefault:(NSString *)defaultValue {
    return [self lpConfigStringForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}

- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section {
    return [self lpConfigStringForKey:key inSection:section withDefault:nil];
}

- (NSString *)lpConfigStringForKey:(NSString *)key inSection:(NSString *)section withDefault:(NSString *)defaultValue {
    if (!key)
        return defaultValue;
    const char *value = linphone_config_get_string(_configDb, [section UTF8String], [key UTF8String], NULL);
    return value ? [NSString stringWithUTF8String:value] : defaultValue;
}

- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key {
    [self lpConfigSetBool:value forKey:key inSection:LINPHONERC_APPLICATION_KEY];
}

- (void)lpConfigSetBool:(BOOL)value forKey:(NSString *)key inSection:(NSString *)section {
    [self lpConfigSetInt:(int)(value == TRUE) forKey:key inSection:section];
}

- (BOOL)lpConfigBoolForKey:(NSString *)key {
    return [self lpConfigBoolForKey:key withDefault:FALSE];
}

- (BOOL)lpConfigBoolForKey:(NSString *)key withDefault:(BOOL)defaultValue {
    return [self lpConfigBoolForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}

- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section {
    return [self lpConfigBoolForKey:key inSection:section withDefault:FALSE];
}

- (BOOL)lpConfigBoolForKey:(NSString *)key inSection:(NSString *)section withDefault:(BOOL)defaultValue {
    if (!key)
        return defaultValue;
    int val = [self lpConfigIntForKey:key inSection:section withDefault:-1];
    return (val != -1) ? (val == 1) : defaultValue;
}

- (int)lpConfigIntForKey:(NSString *)key {
    return [self lpConfigIntForKey:key withDefault:-1];
}

- (int)lpConfigIntForKey:(NSString *)key withDefault:(int)defaultValue {
    return [self lpConfigIntForKey:key inSection:LINPHONERC_APPLICATION_KEY withDefault:defaultValue];
}

- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section {
    return [self lpConfigIntForKey:key inSection:section withDefault:-1];
}

- (int)lpConfigIntForKey:(NSString *)key inSection:(NSString *)section withDefault:(int)defaultValue {
    if (!key)
        return defaultValue;
    return linphone_config_get_int(_configDb, [section UTF8String], [key UTF8String], (int)defaultValue);
}

- (void)loadAvatar {
    NSString *assetId = [self lpConfigStringForKey:@"avatar"];
    __block UIImage *ret = nil;
    if (assetId) {
        PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithLocalIdentifiers:[NSArray arrayWithObject:assetId] options:nil];
        if (![assets firstObject]) {
            LOGE(@"Can't fetch avatar image.");
        }
        PHAsset *asset = [assets firstObject];
        // load avatar synchronously so that we can return UIIMage* directly - since we are
        // only using thumbnail, it must be pretty fast to fetch even without cache.
        PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
        options.synchronous = TRUE;
        [[PHImageManager defaultManager] requestImageForAsset:asset targetSize:PHImageManagerMaximumSize contentMode:PHImageContentModeDefault options:options
         resultHandler:^(UIImage *image, NSDictionary * info) {
//                if (image)
//                    ret = [UIImage UIImageThumbnail:image thumbSize:150];
//                else
//                    LOGE(@"Can't read avatar");
            }];
    }
    
    if (!ret) {
//        ret = CansImage.shared.avatar;
    }
//    _avatar = ret;
}

+ (BOOL)copyFile:(NSString *)src destination:(NSString *)dst override:(BOOL)override ignore:(BOOL)ignore {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *error = nil;
    if ([fileManager fileExistsAtPath:src] == NO) {
        if (!ignore)
            LOGE(@"Can't find \"%@\": %@", src, [error localizedDescription]);
        return FALSE;
    }
    if ([fileManager fileExistsAtPath:dst] == YES) {
        if (override) {
            [fileManager removeItemAtPath:dst error:&error];
            if (error != nil) {
                LOGE(@"Can't remove \"%@\": %@", dst, [error localizedDescription]);
                return FALSE;
            }
        } else {
            LOGW(@"\"%@\" already exists", dst);
            return FALSE;
        }
    }
    [fileManager copyItemAtPath:src toPath:dst error:&error];
    if (error != nil) {
        LOGE(@"Can't copy \"%@\" to \"%@\": %@", src, dst, [error localizedDescription]);
        return FALSE;
    }
    return TRUE;
}

- (void)configurePushTokenForProxyConfig:(LinphoneProxyConfig *)proxyCfg {
    linphone_proxy_config_edit(proxyCfg);

//    NSData *remoteTokenData = _remoteNotificationToken;
//    NSData *PKTokenData = _pushKitToken;
//    BOOL pushNotifEnabled = linphone_proxy_config_is_push_notification_allowed(proxyCfg);
//    if ((remoteTokenData != nil || PKTokenData != nil) && pushNotifEnabled) {
//
//        const unsigned char *remoteTokenBuffer = [remoteTokenData bytes];
//        NSMutableString *remoteTokenString = [NSMutableString stringWithCapacity:[remoteTokenData length] * 2];
//        for (int i = 0; i < [remoteTokenData length]; ++i) {
//            [remoteTokenString appendFormat:@"%02X", (unsigned int)remoteTokenBuffer[i]];
//        }
//
//        const unsigned char *PKTokenBuffer = [PKTokenData bytes];
//        NSMutableString *PKTokenString = [NSMutableString stringWithCapacity:[PKTokenData length] * 2];
//        for (int i = 0; i < [PKTokenData length]; ++i) {
//            [PKTokenString appendFormat:@"%02X", (unsigned int)PKTokenBuffer[i]];
//        }
//
//        NSString *token;
//        NSString *services;
//        if (remoteTokenString && PKTokenString) {
//            token = [NSString stringWithFormat:@"%@:remote&%@:voip", remoteTokenString, PKTokenString];
//            services = @"remote&voip";
//        } else if (remoteTokenString) {
//            token = [NSString stringWithFormat:@"%@:remote", remoteTokenString];
//            services = @"remote";
//        } else {
//            token = [NSString stringWithFormat:@"%@:voip", PKTokenString];
//            services = @"voip";
//        }
//
//#ifdef DEBUG
//#define APPMODE_SUFFIX @".dev"
//#else
//#define APPMODE_SUFFIX @""
//#endif
//        NSString *ring =
//            ([LinphoneManager bundleFile:[self lpConfigStringForKey:@"local_ring" inSection:@"sound"].lastPathComponent]
//             ?: [LinphoneManager bundleFile:@"notes_of_the_optimistic.caf"])
//            .lastPathComponent;
//
//        NSString *timeout;
//        if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_9_x_Max) {
//            timeout = @";pn-timeout=0";
//        } else {
//            timeout = @"";
//        }
//
//        // dummy value, for later use
//        NSString *teamId = @"ABCD1234";
//
//        NSString *params = [NSString
//                    stringWithFormat:@"pn-provider=apns%@;pn-prid=%@;pn-param=%@.%@.%@;pn-msg-str=IM_MSG;pn-call-str=IC_MSG;pn-groupchat-str=GC_MSG;pn-"
//                    @"call-snd=%@;pn-msg-snd=msg.caf%@;pn-silent=1",
//                    APPMODE_SUFFIX, token, teamId, [[NSBundle mainBundle] bundleIdentifier], services, ring, timeout];
//
//        LOGI(@"Proxy config %s configured for push notifications with contact: %@",
//        linphone_proxy_config_get_identity(proxyCfg), params);
//        linphone_proxy_config_set_contact_uri_parameters(proxyCfg, [params UTF8String]);
//        linphone_proxy_config_set_contact_parameters(proxyCfg, NULL);
//    } else {
//        LOGI(@"Proxy config %s NOT configured for push notifications", linphone_proxy_config_get_identity(proxyCfg));
//        // no push token:
//        linphone_proxy_config_set_contact_uri_parameters(proxyCfg, NULL);
//        linphone_proxy_config_set_contact_parameters(proxyCfg, NULL);
//    }
//
    linphone_proxy_config_done(proxyCfg);
}



@end
