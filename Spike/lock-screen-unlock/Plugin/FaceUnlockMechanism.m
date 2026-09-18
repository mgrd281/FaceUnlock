/*
 *  FaceUnlock.bundle — the authorization mechanism.
 *
 *  This code is loaded into SecurityAgent, Apple's own authentication process,
 *  during a lock-screen unlock. Three consequences shape everything below:
 *
 *  1. It is written in Objective-C against AuthorizationPlugin.h and links only
 *     Foundation, CoreFoundation, Security and libxpc — the same shape as every
 *     shipping plugin of this kind. A Swift runtime dependency inside
 *     SecurityAgent would be a risk with no upside.
 *
 *  2. Its only dangerous failure mode is *not returning*, not returning the
 *     wrong answer. A wrong "deny" costs the user a password; a hang costs them
 *     the lock screen. Every path out of MechanismInvoke is therefore bounded by
 *     a deadline, and the XPC call is never a synchronous blocking send.
 *
 *  3. It learns one bit. It never sees an image, a descriptor or a profile, and
 *     it never handles a password.
 *
 *  Returning kAuthorizationResultDeny fails only *our* sub-rule of
 *  system.login.screensaver. Because that rule is a k-of-n=1 container, the
 *  engine then falls through to use-login-window-ui and the user types their
 *  password as they always did. See DESIGN.md §1 and §6.
 */

#import <Foundation/Foundation.h>
#include <Security/AuthorizationPlugin.h>
#include <Security/AuthorizationTags.h>
#include <Security/SecCode.h>
#include <os/log.h>
#include <xpc/xpc.h>

#include "FaceUnlockBrokerProtocol.h"

static os_log_t FULog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("de.faceunlock.mac", "Mechanism"); });
    return log;
}

#pragma mark - Reply box

/*
 *  Carries the broker's answer back across the deadline.
 *
 *  An ObjC object with atomic properties rather than __block locals: once the
 *  deadline expires this stack frame stops reading, but the reply handler may
 *  still be in flight and will write. ARC keeps the box alive for whichever of
 *  the two outlives the other, and the atomics make the overlap safe instead of
 *  a race we would have to reason about.
 */
@interface FUReplyBox : NSObject
@property (atomic, assign) BOOL allowed;
@property (atomic, assign) BOOL answered;
@property (atomic, copy) NSString *refusal;
@end

@implementation FUReplyBox
@end

#pragma mark - Records

typedef struct {
    const AuthorizationCallbacks *callbacks;
} PluginRecord;

typedef struct {
    const PluginRecord *plugin;
    AuthorizationEngineRef engine;
    const char *mechanismId;
} MechanismRecord;

#pragma mark - Helpers

/// The requirement the broker itself must satisfy, written by install.sh.
/// Absent or unreadable means we do not know who we would be talking to, and
/// the mechanism declines rather than asking an unverified daemon.
static NSString *FUBrokerRequirement(void) {
    NSDictionary *peers = [NSDictionary dictionaryWithContentsOfFile:
        @(FU_PEERS_PLIST_PATH)];
    NSString *requirement = peers[@(FU_PEERS_KEY_BROKER)];
    return [requirement isKindOfClass:[NSString class]] && requirement.length > 0
        ? requirement : nil;
}

/// The username loginwindow believes is unlocking, passed to the broker as an
/// advisory cross-check only. The broker resolves the console owner itself and
/// that answer is the authoritative one.
static NSString *FUUsernameHint(MechanismRecord *mechanism) {
    const AuthorizationValue *value = NULL;
    OSStatus status = mechanism->plugin->callbacks->GetHintValue(
        mechanism->engine, kAuthorizationEnvironmentUsername, &value);
    if (status != errAuthorizationSuccess || value == NULL ||
        value->data == NULL || value->length == 0) {
        return nil;
    }
    NSString *name = [[NSString alloc] initWithBytes:value->data
                                              length:value->length
                                            encoding:NSUTF8StringEncoding];
    // The value is sometimes NUL-terminated and sometimes not.
    return [name stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"\0"]];
}

/*
 *  Ask the broker, and come back with an answer within the deadline no matter
 *  what. Every early return here is a deny, which is the safe direction: it
 *  costs a password prompt, never an unlock.
 */
static BOOL FUAskBroker(MechanismRecord *mechanism) {
    // peers.plist is still required on disk: its absence means the components
    // were never installed, and declining is then the correct answer.
    if (FUBrokerRequirement() == nil) {
        os_log_error(FULog(), "Lock-screen unlock is not installed; declining");
        return NO;
    }

    dispatch_queue_t queue = dispatch_queue_create(
        "de.faceunlock.mechanism.reply", DISPATCH_QUEUE_SERIAL);
    // The asker service. It is pinned, on the broker's side, to Apple's
    // SecurityAgent — the process we are loaded into — rather than to this
    // bundle's own signature, which never appears as a peer identity.
    xpc_connection_t connection = xpc_connection_create_mach_service(
        FU_ASKER_SERVICE_NAME, queue, 0);
    if (connection == NULL) {
        os_log_error(FULog(), "The broker service could not be reached");
        return NO;
    }

    // The broker is deliberately *not* pinned by code-signing requirement here,
    // and this is the one place in the design where a check was removed rather
    // than kept.
    //
    // It is not a choice. Inside SecurityAgent the mechanism runs as
    // `_securityagent`, and that sandbox cannot reach
    // `com.apple.CodeSigningHelper`, which is what libxpc uses to evaluate a
    // peer requirement. Unable to evaluate, it fails closed and rejects every
    // reply — the broker answers "recognised", libxpc discards it with
    // "Received message forbidden due to code signing requirement", and the
    // password appears. Measured on a real lock screen: the broker's own
    // validation of *its* peer succeeded from root and logged a
    // CodeSigningHelper connection; the mechanism never logged one. The form of
    // the requirement is irrelevant — certificate-based and cdhash-based fail
    // identically, because neither is ever evaluated.
    //
    // What still stands in its place:
    //
    //   * The asker service lives in the *system* bootstrap domain, registered
    //     by launchd from a root-owned LaunchDaemon plist. Claiming that name
    //     requires root — and an attacker with root can replace this bundle,
    //     the daemon and the authorisation database itself, so the pin was
    //     never what stood between them and an unlock.
    //   * The broker still pins *this* mechanism's host, from root, where
    //     evaluation works.
    //   * The app still pins the broker before answering anything, from the
    //     user's session, where evaluation works. That is the direction that
    //     carries the risk: the app must never answer an impostor.
    //
    // So the unverified hop is the one that learns a single boolean, from a
    // service only root can publish, and the requirement is kept on disk for
    // the app, which can still enforce it. See DESIGN.md section 4.

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        // Errors surface through the reply handler below; this handler exists
        // because libxpc requires one before resume.
        (void)event;
    });
    xpc_connection_resume(connection);

    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, FU_KEY_VERSION, FU_PROTOCOL_VERSION);
    xpc_dictionary_set_uint64(message, FU_KEY_MESSAGE, FU_MSG_BEGIN_CHALLENGE);
    NSString *username = FUUsernameHint(mechanism);
    if (username.length > 0) {
        xpc_dictionary_set_string(message, FU_KEY_USERNAME, username.UTF8String);
    }

    FUReplyBox *box = [FUReplyBox new];
    dispatch_semaphore_t settled = dispatch_semaphore_create(0);

    xpc_connection_send_message_with_reply(connection, message, queue, ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
            box.allowed = xpc_dictionary_get_bool(reply, FU_KEY_VERDICT);
            const char *refusal = xpc_dictionary_get_string(reply, FU_KEY_REFUSAL);
            if (refusal != NULL) { box.refusal = @(refusal); }
        } else if (reply == XPC_ERROR_CONNECTION_INVALID) {
            box.refusal = @"the broker service could not be found (is faceunlockd running?)";
        } else if (reply == XPC_ERROR_CONNECTION_INTERRUPTED) {
            box.refusal = @"the broker connection was interrupted";
        } else if (reply == XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT) {
            box.refusal = @"the broker did not satisfy its code requirement";
        } else {
            char *description = xpc_copy_description(reply);
            box.refusal = [NSString stringWithFormat:@"the broker connection failed (%s)",
                           description ?: "no detail"];
            if (description != NULL) { free(description); }
        }
        box.answered = YES;
        dispatch_semaphore_signal(settled);
    });

    dispatch_time_t deadline = dispatch_time(
        DISPATCH_TIME_NOW, (int64_t)(FU_PLUGIN_DEADLINE_SECONDS * NSEC_PER_SEC));
    long timedOut = dispatch_semaphore_wait(settled, deadline);

    // Cancelling guarantees the reply handler will not be invoked again, and
    // releases the connection whether or not the broker ever answered.
    xpc_connection_cancel(connection);

    if (timedOut != 0) {
        os_log_error(FULog(), "The broker did not answer within the deadline; declining");
        return NO;
    }
    if (!box.allowed) {
        os_log(FULog(), "Not recognised (%{public}s); the password branch takes over",
               box.refusal.length > 0 ? box.refusal.UTF8String : "no reason given");
        return NO;
    }
    os_log(FULog(), "Recognised; satisfying the face branch of this unlock");
    return YES;
}

#pragma mark - Mechanism interface

static OSStatus MechanismCreate(AuthorizationPluginRef inPlugin,
                                AuthorizationEngineRef inEngine,
                                AuthorizationMechanismId mechanismId,
                                AuthorizationMechanismRef *outMechanism) {
    MechanismRecord *mechanism = (MechanismRecord *)calloc(1, sizeof(MechanismRecord));
    if (mechanism == NULL) { return errSecMemoryError; }
    mechanism->plugin = (const PluginRecord *)inPlugin;
    mechanism->engine = inEngine;
    mechanism->mechanismId = mechanismId;
    *outMechanism = (AuthorizationMechanismRef)mechanism;
    return errAuthorizationSuccess;
}

/// Asks SecurityAgent to show "Look at the camera and blink" while we decide.
///
/// `kAuthorizationEnvironmentPrompt` is the only public way a mechanism can put
/// words on an authorisation, and it is Apple's built-in mechanisms that render
/// it — this one draws nothing itself. Whether the password branch of
/// `system.login.screensaver` picks the hint up is not documented and not
/// guaranteed, so this is best-effort: the return value is deliberately ignored
/// and nothing downstream depends on it. The blink is required either way.
static void FUSetBlinkPrompt(MechanismRecord *mechanism) {
    static const char prompt[] = "Look at the camera and blink to unlock with FaceUnlock.";
    AuthorizationValue value = { sizeof(prompt) - 1, (void *)prompt };
    (void)mechanism->plugin->callbacks->SetHintValue(
        mechanism->engine, kAuthorizationEnvironmentPrompt, &value);
}

static OSStatus MechanismInvoke(AuthorizationMechanismRef inMechanism) {
    MechanismRecord *mechanism = (MechanismRecord *)inMechanism;
    @autoreleasepool {
        FUSetBlinkPrompt(mechanism);
        BOOL allowed = NO;
        @try {
            allowed = FUAskBroker(mechanism);
        } @catch (NSException *exception) {
            // An exception escaping into SecurityAgent would be far worse than a
            // password prompt. Nothing here is expected to throw; this is the
            // belt to the deadline's braces.
            os_log_error(FULog(), "Unexpected exception; declining");
            allowed = NO;
        }
        mechanism->plugin->callbacks->SetResult(
            mechanism->engine,
            allowed ? kAuthorizationResultAllow : kAuthorizationResultDeny);
    }
    return errAuthorizationSuccess;
}

static OSStatus MechanismDeactivate(AuthorizationMechanismRef inMechanism) {
    MechanismRecord *mechanism = (MechanismRecord *)inMechanism;
    // The engine waits for this. Answering promptly is the whole contract.
    return mechanism->plugin->callbacks->DidDeactivate(mechanism->engine);
}

static OSStatus MechanismDestroy(AuthorizationMechanismRef inMechanism) {
    free(inMechanism);
    return errAuthorizationSuccess;
}

static OSStatus PluginDestroy(AuthorizationPluginRef inPlugin) {
    free(inPlugin);
    return errAuthorizationSuccess;
}

static const AuthorizationPluginInterface kPluginInterface = {
    kAuthorizationPluginInterfaceVersion,
    PluginDestroy,
    MechanismCreate,
    MechanismInvoke,
    MechanismDeactivate,
    MechanismDestroy
};

/// The single exported symbol. SecurityAgent looks up exactly this.
OSStatus AuthorizationPluginCreate(const AuthorizationCallbacks *callbacks,
                                   AuthorizationPluginRef *outPlugin,
                                   const AuthorizationPluginInterface **outPluginInterface) {
    PluginRecord *plugin = (PluginRecord *)calloc(1, sizeof(PluginRecord));
    if (plugin == NULL) { return errSecMemoryError; }
    plugin->callbacks = callbacks;
    *outPlugin = (AuthorizationPluginRef)plugin;
    *outPluginInterface = &kPluginInterface;
    return errAuthorizationSuccess;
}
