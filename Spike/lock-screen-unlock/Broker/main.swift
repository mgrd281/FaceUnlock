//
//  faceunlockd — the root broker.
//
//  It exists for one structural reason. The app registers its Mach service in
//  the Aqua bootstrap domain, which is per-user and per-session; SecurityAgent
//  runs in a different session and cannot look that name up. A LaunchDaemon's
//  MachServices entry lands in the *system* domain, which both sides can reach.
//
//  So this is a relay with a policy check, and nothing more. It holds no
//  biometric data, and the entire payload it ever carries is a nonce, a uid and
//  a boolean. See DESIGN.md §2.
//

import Darwin
import Dispatch
import Foundation
import Security
import SystemConfiguration
import os

private let log = Logger(subsystem: "de.faceunlock.mac", category: "Broker")

// MARK: - Clock

/// Seconds on the continuous clock, which keeps advancing while the Mac sleeps.
/// A challenge TTL measured on the uptime clock would silently extend across a
/// lid close, which is exactly the window this design refuses to leave open.
private func continuousSeconds() -> Double {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = mach_continuous_time()
    let nanos = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    return nanos / 1_000_000_000
}

// MARK: - Peer pinning

/// The two code-signing requirements the broker pins its peers to, written by
/// `install.sh` from the binaries it actually installed.
///
/// This is deliberately a file rather than a compile-time constant. A locally
/// built, ad-hoc signed spike and a Developer ID-signed release have different
/// requirements, and both have to work without recompiling the daemon.
private struct PeerRequirements {
    /// Pins the agent service: our own app, which answers challenges.
    let app: String
    /// Pins the asker service: Apple's SecurityAgent, which hosts our mechanism.
    let host: String

    static func load() -> PeerRequirements? {
        guard let data = FileManager.default.contents(atPath: FU_PEERS_PLIST_PATH),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: String],
              let app = plist[FU_PEERS_KEY_APP], !app.isEmpty,
              let host = plist[FU_PEERS_KEY_HOST], !host.isEmpty
        else { return nil }
        return PeerRequirements(app: app, host: host)
    }
}

/// Which service a connection arrived on, and therefore what it may ask for.
private enum PeerRole {
    case agent   // the app: may register and answer
    case asker   // SecurityAgent: may begin a challenge
}

// MARK: - XPC helpers

private func dictionaryData(_ message: xpc_object_t, _ key: String) -> Data? {
    var length = 0
    guard let pointer = xpc_dictionary_get_data(message, key, &length), length > 0 else { return nil }
    return Data(bytes: pointer, count: length)
}

private func setData(_ message: xpc_object_t, _ key: String, _ data: Data) {
    data.withUnsafeBytes { raw in
        xpc_dictionary_set_data(message, key, raw.baseAddress, raw.count)
    }
}

/// Length-independent comparison. The nonce is not a secret an attacker can
/// grind at over the network, but comparing it in constant time costs nothing
/// and removes the question.
private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in 0..<lhs.count { difference |= lhs[index] ^ rhs[index] }
    return difference == 0
}

private func randomNonce() -> Data? {
    var bytes = [UInt8](repeating: 0, count: Int(FU_NONCE_LENGTH))
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        return nil
    }
    return Data(bytes)
}

/// The uid that owns the console right now, resolved by the broker itself.
///
/// The plugin is never asked to supply this. It runs inside SecurityAgent at a
/// moment when no one has authenticated yet, so any uid it offered would have to
/// be validated here anyway; asking the system directly skips a class of bug.
private func consoleUser() -> (uid: uid_t, name: String)? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String? else { return nil }
    // "loginwindow" is reported while the login window itself owns the console,
    // which is not a locked user session and is not ours to answer for.
    guard !name.isEmpty, name != "loginwindow", uid != 0 else { return nil }
    return (uid, name)
}

// MARK: - Broker

private final class Broker {
    /// One challenge in flight, waiting for the app to answer.
    private struct Challenge {
        let nonce: Data
        let uid: uid_t
        let mintedAt: Double
        let reply: xpc_object_t
        let asker: xpc_connection_t
        var resolved = false
    }

    /// Every piece of mutable state below is touched only on this queue, so the
    /// "one outstanding challenge" rule is an invariant rather than a hope.
    private let queue = DispatchQueue(label: "de.faceunlock.broker.state")

    /// Every live agent for a uid, in registration order, rather than one.
    ///
    /// Keying by uid alone let a second instance of the app evict the first, and
    /// the eviction was invisible to the evicted one: when the newcomer exited,
    /// the uid was left with no agent while a perfectly healthy app still
    /// believed it was registered. Keeping them all means a departure only ever
    /// removes the connection that actually departed.
    private var agents: [uid_t: [xpc_connection_t]] = [:]
    private var pending: Challenge?
    private var denialStreak = 0
    private var lockedOutUntil: Double = 0

    // MARK: Connection handling

    func accept(_ peer: xpc_connection_t, as role: PeerRole, pinnedTo requirement: String) {
        // Pin before resuming. A connection that does not satisfy either of our
        // own components' requirements never delivers a message at all.
        let pinned = requirement.withCString { xpc_connection_set_peer_code_signing_requirement(peer, $0) }
        guard pinned == 0 else {
            log.error("Refusing a peer: the code-signing requirement could not be applied")
            xpc_connection_cancel(peer)
            return
        }

        xpc_connection_set_event_handler(peer) { [weak self] event in
            guard let self else { return }
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self.queue.async { self.forgetAgent(peer) }
                return
            }
            guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else { return }
            self.handle(event, from: peer, as: role)
        }
        xpc_connection_resume(peer)
    }

    private func handle(_ message: xpc_object_t, from peer: xpc_connection_t, as role: PeerRole) {
        guard xpc_dictionary_get_uint64(message, FU_KEY_VERSION) == UInt64(FU_PROTOCOL_VERSION) else {
            log.error("Dropping a message with an unrecognised protocol version")
            replyFailure(to: message, from: peer, refusal: "protocol version mismatch")
            return
        }

        let euid = xpc_connection_get_euid(peer)

        switch xpc_dictionary_get_uint64(message, FU_KEY_MESSAGE) {
        case UInt64(FU_MSG_HANDSHAKE):
            guard let reply = xpc_dictionary_create_reply(message) else { return }
            xpc_dictionary_set_uint64(reply, FU_KEY_VERSION, UInt64(FU_PROTOCOL_VERSION))
            xpc_dictionary_set_bool(reply, FU_KEY_OK, true)
            xpc_connection_send_message(peer, reply)

        case UInt64(FU_MSG_REGISTER_AGENT):
            // Only on the agent service, and never for root: an agent answers
            // for one ordinary user, and the uid comes from the connection
            // rather than from the message body.
            guard role == .agent, euid != 0 else {
                replyFailure(to: message, from: peer, refusal: "this peer may not act as an agent")
                return
            }
            queue.async {
                var existing = self.agents[euid] ?? []
                if !existing.contains(where: { $0 === peer }) {
                    existing.append(peer)
                    log.notice(
                        "Agent registered for uid \(euid, privacy: .public) (\(existing.count, privacy: .public) live)"
                    )
                }
                self.agents[euid] = existing
            }
            guard let reply = xpc_dictionary_create_reply(message) else { return }
            xpc_dictionary_set_bool(reply, FU_KEY_OK, true)
            xpc_connection_send_message(peer, reply)

        case UInt64(FU_MSG_BEGIN_CHALLENGE):
            // Only on the asker service, which is pinned to Apple's
            // SecurityAgent. The user's own app cannot reach that service, so it
            // cannot mint challenges for itself to answer.
            guard role == .asker else {
                replyFailure(to: message, from: peer, refusal: "this peer may not begin a challenge")
                return
            }
            log.notice("Challenge requested by a SecurityAgent host running as uid \(euid, privacy: .public)")
            let claimedUsername = xpc_dictionary_get_string(message, FU_KEY_USERNAME).map { String(cString: $0) }
            queue.async { self.beginChallenge(replyingTo: message, from: peer, claimedUsername: claimedUsername) }

        default:
            replyFailure(to: message, from: peer, refusal: "unknown message")
        }
    }

    private func forgetAgent(_ peer: xpc_connection_t) {
        for (uid, connections) in agents {
            let remaining = connections.filter { $0 !== peer }
            guard remaining.count != connections.count else { continue }
            if remaining.isEmpty {
                agents.removeValue(forKey: uid)
            } else {
                agents[uid] = remaining
            }
            log.notice(
                "An agent for uid \(uid, privacy: .public) disconnected (\(remaining.count, privacy: .public) left)"
            )
        }
    }

    // MARK: Challenges

    private func beginChallenge(
        replyingTo message: xpc_object_t,
        from asker: xpc_connection_t,
        claimedUsername: String?
    ) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }

        func deny(_ refusal: String) {
            log.notice("Denying: \(refusal, privacy: .public)")
            xpc_dictionary_set_bool(reply, FU_KEY_VERDICT, false)
            xpc_dictionary_set_string(reply, FU_KEY_REFUSAL, refusal)
            xpc_connection_send_message(asker, reply)
        }

        let now = continuousSeconds()
        guard now >= lockedOutUntil else {
            deny("locked out after \(FU_DENIAL_STREAK_LIMIT) consecutive denials")
            return
        }
        guard let console = consoleUser() else {
            deny("no console user owns this session")
            return
        }
        // Advisory cross-check. The broker's own answer is authoritative; a
        // mismatch means the two disagree about what is being unlocked, and
        // disagreement is a reason to fall through to the password, not to pick.
        if let claimedUsername, !claimedUsername.isEmpty, claimedUsername != console.name {
            deny("the mechanism named a different user than the console owner")
            return
        }
        // The most recently registered agent, which is the one most likely to
        // still be in the foreground if more than one is live.
        guard let agent = agents[console.uid]?.last else {
            deny("FaceUnlock is not running for the console user")
            return
        }
        guard let nonce = randomNonce() else {
            deny("the nonce could not be generated")
            return
        }

        // A second request supersedes the first; the older asker is denied now
        // rather than left waiting on a reply that will never come.
        if pending != nil { resolvePending(verdict: false, refusal: "superseded by a newer challenge") }

        pending = Challenge(nonce: nonce, uid: console.uid, mintedAt: now, reply: reply, asker: asker)

        let challenge = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(challenge, FU_KEY_VERSION, UInt64(FU_PROTOCOL_VERSION))
        xpc_dictionary_set_uint64(challenge, FU_KEY_MESSAGE, UInt64(FU_MSG_CHALLENGE))
        xpc_dictionary_set_uint64(challenge, FU_KEY_UID, UInt64(console.uid))
        setData(challenge, FU_KEY_NONCE, nonce)

        log.notice("Challenge minted for uid \(console.uid, privacy: .public)")

        xpc_connection_send_message_with_reply(agent, challenge, queue) { [weak self] answer in
            self?.receiveAnswer(answer, expecting: nonce)
        }

        // The backstop. If the app never answers — it crashed, it is wedged, the
        // user walked away mid-attempt — the asker still gets a definite no.
        queue.asyncAfter(deadline: .now() + FU_CHALLENGE_TTL_SECONDS) { [weak self] in
            guard let self, let current = self.pending, !current.resolved,
                  constantTimeEquals(current.nonce, nonce) else { return }
            self.resolvePending(verdict: false, refusal: "the challenge expired unanswered")
        }
    }

    private func receiveAnswer(_ answer: xpc_object_t, expecting nonce: Data) {
        guard xpc_get_type(answer) == XPC_TYPE_DICTIONARY else {
            resolveIfMatching(nonce, verdict: false, refusal: "the agent connection failed")
            return
        }
        guard let echoed = dictionaryData(answer, FU_KEY_NONCE),
              constantTimeEquals(echoed, nonce) else {
            resolveIfMatching(nonce, verdict: false, refusal: "the agent echoed the wrong nonce")
            return
        }
        // Freshness is re-checked here and not only in the timer: a reply that
        // arrives after the TTL is as stale as one that never arrived.
        guard let current = pending, !current.resolved,
              continuousSeconds() - current.mintedAt <= FU_CHALLENGE_TTL_SECONDS else {
            resolveIfMatching(nonce, verdict: false, refusal: "the answer arrived too late")
            return
        }
        let verdict = xpc_dictionary_get_bool(answer, FU_KEY_VERDICT)
        let refusal = xpc_dictionary_get_string(answer, FU_KEY_REFUSAL).map { String(cString: $0) }
        resolveIfMatching(nonce, verdict: verdict, refusal: refusal ?? "not recognised")
    }

    private func resolveIfMatching(_ nonce: Data, verdict: Bool, refusal: String) {
        guard let current = pending, !current.resolved,
              constantTimeEquals(current.nonce, nonce) else { return }
        resolvePending(verdict: verdict, refusal: refusal)
    }

    /// Which refusals mean "that was not the enrolled face".
    ///
    /// Only these count toward the lockout. The rest are infrastructure — no
    /// profile, an unreadable one, a challenge that expired, one superseded by a
    /// newer request — and counting them punishes the user for the feature being
    /// misconfigured rather than for anyone attacking it. It also cost a real
    /// diagnosis: a single probe run of three attempts tripped the lockout on
    /// failures that had nothing to do with a face.
    ///
    /// Nothing is lost by this. An attacker cannot authenticate by provoking a
    /// timeout, so refusing to count timeouts does not widen the door.
    private static let recognitionFailures: Set<String> = ["notRecognised"]

    /// The single exit point for a challenge. Replies exactly once, erases the
    /// nonce, and keeps the denial streak honest.
    private func resolvePending(verdict: Bool, refusal: String) {
        guard var current = pending, !current.resolved else { return }
        current.resolved = true
        pending = nil

        xpc_dictionary_set_bool(current.reply, FU_KEY_VERDICT, verdict)
        if !verdict { xpc_dictionary_set_string(current.reply, FU_KEY_REFUSAL, refusal) }
        xpc_connection_send_message(current.asker, current.reply)

        if verdict {
            denialStreak = 0
            log.notice("Verdict: recognised")
        } else {
            log.notice("Verdict: not recognised (\(refusal, privacy: .public))")
            if Broker.recognitionFailures.contains(refusal) {
                denialStreak += 1
                if denialStreak >= Int(FU_DENIAL_STREAK_LIMIT) {
                    lockedOutUntil = continuousSeconds() + FU_LOCKOUT_SECONDS
                    denialStreak = 0
                    log.error(
                        "\(FU_DENIAL_STREAK_LIMIT) faces in a row were not recognised; refusing challenges for \(FU_LOCKOUT_SECONDS) seconds"
                    )
                }
            }
        }
    }

    private func replyFailure(to message: xpc_object_t, from peer: xpc_connection_t, refusal: String) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_bool(reply, FU_KEY_OK, false)
        xpc_dictionary_set_bool(reply, FU_KEY_VERDICT, false)
        xpc_dictionary_set_string(reply, FU_KEY_REFUSAL, refusal)
        xpc_connection_send_message(peer, reply)
    }
}

// MARK: - Entry point

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("faceunlockd must run as root; launchd starts it.\n".utf8))
    exit(1)
}

guard let requirements = PeerRequirements.load() else {
    // Failing closed here is the point. Without pinned requirements the broker
    // would accept any process that can reach the service name, so it refuses to
    // start at all rather than run unpinned.
    log.fault("No peer requirements at \(FU_PEERS_PLIST_PATH, privacy: .public); refusing to start")
    FileHandle.standardError.write(Data("Missing \(FU_PEERS_PLIST_PATH). Run install.sh.\n".utf8))
    exit(1)
}

private let broker = Broker()
let listenerQueue = DispatchQueue(label: "de.faceunlock.broker.listener")

/// One listener per role. Each pins exactly one code requirement, so which
/// service a peer reached *is* its identity — the app cannot appear on the asker
/// service, and SecurityAgent cannot appear on the agent service.
private func listen(on name: String, as role: PeerRole, requirement: String) -> xpc_connection_t {
    let listener = xpc_connection_create_mach_service(
        name, listenerQueue, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
    xpc_connection_set_event_handler(listener) { event in
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        broker.accept(event, as: role, pinnedTo: requirement)
    }
    xpc_connection_resume(listener)
    log.notice("Listening on \(name, privacy: .public)")
    return listener
}

// Held for the life of the process; cancelling either would stop the service.
let agentListener = listen(on: FU_AGENT_SERVICE_NAME, as: .agent, requirement: requirements.app)
let askerListener = listen(on: FU_ASKER_SERVICE_NAME, as: .asker, requirement: requirements.host)

log.notice("faceunlockd ready")
dispatchMain()
