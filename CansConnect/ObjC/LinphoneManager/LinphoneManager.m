//
//  LinphoneManager.m
//  CansConnect
//
//  Created by Siraphop Chaisirikul on 13/11/2565 BE.
//

#import "LinphoneManager.h"

#include "linphone/factory.h"
#include "linphone/linphonecore.h"




@interface LinphoneManager ()
    
@end

@implementation LinphoneManager

- (void)createLinphoneCore {
    LinphoneFactory *factory = linphone_factory_get();
    LinphoneCoreCbs *cbs = linphone_factory_create_core_cbs(factory);
    linphone_core_cbs_set_registration_state_changed(cbs,linphone_iphone_registration_state);
//    linphone_core_cbs_set_notify_presence_received_for_uri_or_tel(cbs, linphone_iphone_notify_presence_received_for_uri_or_tel);
//    linphone_core_cbs_set_authentication_requested(cbs, linphone_iphone_popup_password_request);
//    linphone_core_cbs_set_message_received(cbs, linphone_iphone_message_received);
//    linphone_core_cbs_set_transfer_state_changed(cbs, linphone_iphone_transfer_state_changed);
//    linphone_core_cbs_set_is_composing_received(cbs, linphone_iphone_is_composing_received);
//    linphone_core_cbs_set_configuring_status(cbs, linphone_iphone_configuring_status_changed);
//    linphone_core_cbs_set_global_state_changed(cbs, linphone_iphone_global_state_changed);
//    linphone_core_cbs_set_notify_received(cbs, linphone_iphone_notify_received);
//    linphone_core_cbs_set_call_encryption_changed(cbs, linphone_iphone_call_encryption_changed);
//    linphone_core_cbs_set_chat_room_state_changed(cbs, linphone_iphone_chatroom_state_changed);
//    linphone_core_cbs_set_version_update_check_result_received(cbs, linphone_iphone_version_update_check_result_received);
//    linphone_core_cbs_set_qrcode_found(cbs, linphone_iphone_qr_code_found);
//    linphone_core_cbs_set_call_log_updated(cbs, linphone_iphone_call_log_updated);
//    linphone_core_cbs_set_call_id_updated(cbs, linphone_iphone_call_id_updated);
//    linphone_core_cbs_set_user_data(cbs, (__bridge void *)(self));
}

static void linphone_iphone_registration_state(LinphoneCore *lc, LinphoneProxyConfig *cfg,
                           LinphoneRegistrationState state, const char *message) {
    [(__bridge LinphoneManager *)linphone_core_cbs_get_user_data(linphone_core_get_current_callbacks(lc)) onRegister:lc cfg:cfg state:state message:message];
}

- (void)onRegister:(LinphoneCore *)lc
cfg:(LinphoneProxyConfig *)cfg
state:(LinphoneRegistrationState)state
message:(const char *)cmessage {
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


@end
