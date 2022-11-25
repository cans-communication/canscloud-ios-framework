//
//  CansLinphoneManager.m
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 13/11/2565 BE.
//

#import "CansLinphoneManager.h"


@interface CansLinphoneManager ()
    
@end

@implementation CansLinphoneManager

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

- (void)createLinphoneCore {
    [self overrideDefaultSettings];
    
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
    linphone_core_cbs_set_version_update_check_result_received(cbs, linphone_iphone_version_update_check_result_received);
    linphone_core_cbs_set_call_log_updated(cbs, linphone_iphone_call_log_updated);
    linphone_core_cbs_set_call_id_updated(cbs, linphone_iphone_call_id_updated);
    linphone_core_cbs_set_user_data(cbs, (__bridge void *)(self));
    
    theLinphoneCore = linphone_factory_create_shared_core_with_config(factory, _configDb, NULL, [kLinphoneMsgNotificationAppGroupId UTF8String], true);
    linphone_core_add_callbacks(theLinphoneCore, cbs);
}

- (void)overrideDefaultSettings {
    NSString *factory = [CansLinphoneManager bundleFile:@"linphonerc-factory"];
    
    _configDb = linphone_config_new_for_shared_core(kLinphoneMsgNotificationAppGroupId.UTF8String, @"linphonerc".UTF8String, factory.UTF8String);
    linphone_config_clean_entry(_configDb, "misc", "max_calls");
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


// MARK: - Transfert State Functions

static void linphone_iphone_transfer_state_changed(LinphoneCore *lc, LinphoneCall *call, LinphoneCallState state) {
    
}

// MARK: - Text Received Functions

static void linphone_iphone_call_id_updated(LinphoneCore *lc, const char *previous_call_id, const char *current_call_id) {
//    [CansCallManager.instance updateCallIdWithPrevious:[NSString stringWithUTF8String:previous_call_id] current:[NSString stringWithUTF8String:current_call_id]];
}

static void linphone_iphone_call_log_updated(LinphoneCore *lc, LinphoneCallLog *newcl) {
    if (linphone_call_log_get_status(newcl) == LinphoneCallEarlyAborted) {
        const char *cid = linphone_call_log_get_call_id(newcl);
        if (cid) {
//            [CansCallManager.instance markCallAsDeclinedWithCallId:[NSString stringWithUTF8String:cid]];
        }
    }
}

void linphone_iphone_version_update_check_result_received (LinphoneCore *lc, LinphoneVersionUpdateCheckResult result, const char *version, const char *url) {
    if (result == LinphoneVersionUpdateCheckUpToDate || result == LinphoneVersionUpdateCheckError) {
        return;
    }
//    NSString *title = NSLocalizedString(@"Outdated Version", nil);
//    NSString *body = NSLocalizedString(@"A new version of your app is available, use the button below to download it.", nil);
//
//    UIAlertController *versVerifView = [UIAlertController alertControllerWithTitle:title
//                        message:body
//                        preferredStyle:UIAlertControllerStyleAlert];
//
//    NSString *ObjCurl = [NSString stringWithUTF8String:url];
//    UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Download", nil)
//                    style:UIAlertActionStyleDefault
//                    handler:^(UIAlertAction * action) {
//            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:ObjCurl]];
//        }];
//
//    [versVerifView addAction:defaultAction];
//    [PhoneMainView.instance presentViewController:versVerifView animated:YES completion:nil];
}

static void linphone_iphone_call_encryption_changed(LinphoneCore *lc, LinphoneCall *call, bool_t on,
                            const char *authentication_token) {
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onCallEncryptionChanged:lc call:call on:on token:authentication_token];
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
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onNotifyPresenceReceivedForUriOrTel:lc friend:lf uri:uri_or_tel presenceModel:presence_model];
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
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onNotifyReceived:lc event:lev notifyEvent:notified_event content:body];
}


// MARK: - Auth info Function

static void linphone_iphone_popup_password_request(LinphoneCore *lc, LinphoneAuthInfo *auth_info, LinphoneAuthMethod method) {
    // let the wizard handle its own errors
//    if ([PhoneMainView.instance currentView] != AssistantView.compositeViewDescription) {
//        const char * realmC = linphone_auth_info_get_realm(auth_info);
//        const char * usernameC = linphone_auth_info_get_username(auth_info) ? : "";
//        const char * domainC = linphone_auth_info_get_domain(auth_info) ? : "";
//        static UIAlertController *alertView = nil;
//
//        // InstantMessageDeliveryNotifications from previous accounts can trigger some pop-up spam asking for indentification
//        // Try to filter the popup password request to avoid displaying those that do not matter and can be handled through a simple warning
//        const MSList *configList = linphone_core_get_proxy_config_list(LC);
//        bool foundMatchingConfig = false;
//        while (configList && !foundMatchingConfig) {
//            const char * configUsername = linphone_proxy_config_get_identity(configList->data);
//            const char * configDomain = linphone_proxy_config_get_domain(configList->data);
//            foundMatchingConfig = (strcmp(configUsername, usernameC) == 0) && (strcmp(configDomain, domainC) == 0);
//            configList = configList->next;
//        }
//        if (!foundMatchingConfig) {
//            LOGW(@"Received an authentication request from %s@%s, but ignored it did not match any current user", usernameC, domainC);
//            return;
//        }
//
//        // avoid having multiple popups
//        [PhoneMainView.instance dismissViewControllerAnimated:YES completion:nil];
//
//        // dont pop up if we are in background, in any case we will refresh registers when entering
//        // the application again
//        if ([[UIApplication sharedApplication] applicationState] != UIApplicationStateActive) {
//            return;
//        }
//
//        NSString *realm = [NSString stringWithUTF8String:realmC?:domainC];
//        NSString *username = [NSString stringWithUTF8String:usernameC];
//        NSString *domain = [NSString stringWithUTF8String:domainC];
//        alertView = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"Authentification needed", nil)
//                 message:[NSString stringWithFormat:NSLocalizedString(@"Connection failed because authentication is "
//                                          @"missing or invalid for %@@%@.\nYou can "
//                                          @"provide password again, or check your "
//                                          @"account configuration in the settings.", nil), username, realm]
//                 preferredStyle:UIAlertControllerStyleAlert];
//
//        UIAlertAction* defaultAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel", nil)
//                        style:UIAlertActionStyleDefault
//                        handler:^(UIAlertAction * action) {}];
//
//        [alertView addTextFieldWithConfigurationHandler:^(UITextField *textField) {
//                textField.placeholder = NSLocalizedString(@"Password", nil);
//                textField.clearButtonMode = UITextFieldViewModeWhileEditing;
//                textField.borderStyle = UITextBorderStyleRoundedRect;
//                textField.secureTextEntry = YES;
//            }];
//
//        UIAlertAction* continueAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Confirm password", nil)
//                         style:UIAlertActionStyleDefault
//                         handler:^(UIAlertAction * action) {
//                NSString *password = alertView.textFields[0].text;
//                LinphoneAuthInfo *info =
//                linphone_auth_info_new(username.UTF8String, NULL, password.UTF8String, NULL,
//                               realm.UTF8String, domain.UTF8String);
//                linphone_core_add_auth_info(LC, info);
//                [CansCoreManager.instance refreshRegisters];
//            }];
//
//        UIAlertAction* settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"Go to settings", nil)
//                         style:UIAlertActionStyleDefault
//                         handler:^(UIAlertAction * action) {
//                [PhoneMainView.instance changeCurrentView:SettingsView.compositeViewDescription];
//            }];
//
//        [alertView addAction:defaultAction];
//        [alertView addAction:continueAction];
//        [alertView addAction:settingsAction];
//        [PhoneMainView.instance presentViewController:alertView animated:YES completion:nil];
//    }
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
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onMessageComposeReceived:lc forRoom:room];
}

// MARK: - Registration State Functions

static void linphone_iphone_registration_state(LinphoneCore *lc, LinphoneProxyConfig *cfg,
                           LinphoneRegistrationState state, const char *message) {
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onRegister:lc cfg:cfg state:state message:message];
}

- (void)onRegister:(LinphoneCore *)lc cfg:(LinphoneProxyConfig *)cfg state:(LinphoneRegistrationState)state message:(const char *)cmessage {
//    LOGI(@"New registration state: %s (message: %s)", linphone_registration_state_to_string(state), cmessage);

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
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onConfiguringStatusChanged:status withMessage:message];
}

- (void)onConfiguringStatusChanged:(LinphoneConfiguringState)status withMessage:(const char *)message {
//    LOGI(@"onConfiguringStatusChanged: %s %@", linphone_configuring_state_to_string(status),
//         message ? [NSString stringWithFormat:@"(message: %s)", message] : @"");
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

// MARK: - Global state change

static void linphone_iphone_global_state_changed(LinphoneCore *lc, LinphoneGlobalState gstate, const char *message) {
    [(__bridge CansLinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onGlobalStateChanged:gstate withMessage:message];
}

- (void)onGlobalStateChanged:(LinphoneGlobalState)state withMessage:(const char *)message {
//    LOGI(@"onGlobalStateChanged: %d (message: %s)", state, message);

    NSDictionary *dict = [NSDictionary
                  dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:state], @"state",
                  [NSString stringWithUTF8String:message ? message : ""], @"message", nil];

//    if (theLinphoneCore && linphone_core_get_global_state(theLinphoneCore) == LinphoneGlobalOff) {
//        [CansCoreManager.instance stopIterateTimer];
//    }
//    // dispatch the notification asynchronously
//    dispatch_async(dispatch_get_main_queue(), ^(void) {
//        if (theLinphoneCore && linphone_core_get_global_state(theLinphoneCore) != LinphoneGlobalOff)
//            [NSNotificationCenter.defaultCenter postNotificationName:kLinphoneGlobalStateUpdate object:self userInfo:dict];
//    });
}

// MARK: - Misc Functions

+ (NSString *)bundleFile:(NSString *)file {
    return [[NSBundle mainBundle] pathForResource:[file stringByDeletingPathExtension] ofType:[file pathExtension]];
}

@end
