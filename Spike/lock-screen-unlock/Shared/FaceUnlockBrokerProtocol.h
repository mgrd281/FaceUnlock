/*
 * The wire protocol between the three processes.
 *
 *   FaceUnlock.app  (you)            registers as the answering agent
 *   faceunlockd     (root)           mints challenges, relays verdicts
 *   FaceUnlock.bundle (_securityagent) asks the question at the lock screen
 *
 * This header is the single source of truth. The broker imports it through
 * `swiftc -import-objc-header`; the plugin #includes it directly. Nothing in
 * here is versioned loosely: a mismatch must fail closed, not guess, which is
 * why every message carries FU_PROTOCOL_VERSION and the broker refuses any
 * other value.
 *
 * What crosses this boundary, in either direction, is a nonce, a uid and a
 * boolean. No image, no descriptor, no profile and no password.
 */

#ifndef FACEUNLOCK_BROKER_PROTOCOL_H
#define FACEUNLOCK_BROKER_PROTOCOL_H

/* Two services, registered by the LaunchDaemon in the *system* bootstrap domain
 * — the only domain both the user's Aqua session and SecurityAgent can reach.
 *
 * There are two rather than one because the two callers must be told apart by
 * *code identity*, and a peer's identity can only be pinned per listener.
 * Distinguishing them by effective uid is not possible: SecurityAgentHelper is
 * an XPC service of type "Application", so it runs as the very same user as the
 * app it is asking about. Each service therefore pins exactly one requirement,
 * and which socket a message arrived on *is* the role. See DESIGN.md §4. */
#define FU_AGENT_SERVICE_NAME "de.faceunlock.broker.agent"
#define FU_ASKER_SERVICE_NAME "de.faceunlock.broker.asker"

#define FU_PROTOCOL_VERSION 1

/* Message types. */
#define FU_MSG_HANDSHAKE       1   /* either -> broker; "are you there and compatible?" */
#define FU_MSG_REGISTER_AGENT  2   /* app -> broker; "I will answer for my uid"        */
#define FU_MSG_BEGIN_CHALLENGE 3   /* plugin -> broker; reply is deferred until answered */
#define FU_MSG_CHALLENGE       4   /* broker -> app; carries the nonce, reply is the verdict */

/* Dictionary keys. */
#define FU_KEY_MESSAGE   "msg"       /* uint64, one of FU_MSG_*        */
#define FU_KEY_VERSION   "version"   /* uint64, FU_PROTOCOL_VERSION    */
#define FU_KEY_NONCE     "nonce"     /* data, FU_NONCE_LENGTH bytes    */
#define FU_KEY_UID       "uid"       /* uint64, the console owner      */
#define FU_KEY_USERNAME  "username"  /* string, advisory cross-check   */
#define FU_KEY_VERDICT   "verdict"   /* bool, the one bit that matters */
#define FU_KEY_REFUSAL   "refusal"   /* string, for the log only       */
#define FU_KEY_OK        "ok"        /* bool                           */

#define FU_NONCE_LENGTH 32

/* A challenge is dead this long after it is minted, measured on the continuous
 * clock so that sleeping the Mac cannot stretch it. Deliberately shorter than
 * any plausible walk-away.
 *
 * Sized to fit the recognition attempt inside it, not the other way round.
 * Passive liveness is motion accumulated over time: at 6 fps a four-second
 * attempt gives the analyser about fourteen frames, and measured on real runs
 * that lands at 0.40-0.66 against a 0.62 floor — a coin toss. The budget is
 * what buys the evidence, so it governs the TTL. */
#define FU_CHALLENGE_TTL_SECONDS 10.0

/* The plugin waits slightly longer than the broker's own TTL, so that in the
 * ordinary timeout case the broker's explicit deny wins the race and the
 * plugin's own deadline stays a backstop rather than the normal path. */
#define FU_PLUGIN_DEADLINE_SECONDS 12.0

/* After this many consecutive denials the broker stops answering at all for
 * FU_LOCKOUT_SECONDS. The mechanism then denies and the password branch of
 * system.login.screensaver takes over, which is the normal unlock path. */
#define FU_DENIAL_STREAK_LIMIT 5
#define FU_LOCKOUT_SECONDS 60.0

/* Written by install.sh, read by the broker at every connection. Holds the two
 * code-signing requirements the broker pins its peers to. It is a deployment
 * fact, not a compile-time constant: a locally built ad-hoc signed spike and a
 * Developer ID release have different requirements and both must work. */
#define FU_PEERS_PLIST_PATH "/Library/Application Support/FaceUnlock/peers.plist"
#define FU_PEERS_KEY_APP    "AppRequirement"
/* The requirement for the process that *hosts* the mechanism, which is Apple's
 * SecurityAgent — not our own bundle. A peer code signing requirement validates
 * the process at the other end of the connection, and our mechanism is a bundle
 * loaded into Apple's process; it never appears as a peer in its own right. */
#define FU_PEERS_KEY_HOST   "PluginHostRequirement"
#define FU_PEERS_KEY_BROKER "BrokerRequirement"

#endif /* FACEUNLOCK_BROKER_PROTOCOL_H */
