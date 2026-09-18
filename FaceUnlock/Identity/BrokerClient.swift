import Foundation
import Security
import XPC

/// The app's end of the connection to the root broker.
///
/// It registers as the answering agent for this uid and then waits. The app
/// never initiates anything: it cannot mint a challenge, and the broker refuses
/// to let it try. All it does is answer the question it is asked, when it is
/// asked, through `IdentityServing`.
///
/// `@unchecked Sendable` because `xpc_connection_t` is not `Sendable` and is
/// confined to `queue`; every access to `connection` below happens on it.
public final class BrokerClient: @unchecked Sendable {
    /// `xpc_object_t` is a class type that predates `Sendable`. Each object that
    /// crosses into a `Task` here is used by exactly one consumer and is never
    /// mutated afterwards, which is what this box asserts.
    private struct Transferred: @unchecked Sendable {
        let object: xpc_object_t
    }

    public enum Availability: Equatable, Sendable {
        case available
        /// The daemon is not installed, or not running, or refused us.
        case unavailable(String)
    }

    /// Resolved lazily rather than injected.
    ///
    /// The composition root has a genuine cycle here — the provider chain needs
    /// this client, this client needs `IdentityService`, and `IdentityService`
    /// needs the coordinator that the provider chain is built into. Late-binding
    /// the identity is the smallest place to cut it, and it costs nothing at
    /// run time: nothing asks until a challenge arrives, long after start-up.
    private let identity: @Sendable () -> (any IdentityServing)?
    private let queue = DispatchQueue(label: "de.faceunlock.broker.client")
    private var connection: xpc_connection_t?
    private let registered = Atomic(false)
    /// So a Mac without the feature installed logs the fact once, not on every
    /// capability query.
    private var loggedUnavailable = false
    /// Runs only while unregistered, and is cancelled the moment registration
    /// succeeds. See `scheduleRetry()`.
    private var retryTimer: DispatchSourceTimer?
    private var retryDelay: TimeInterval = BrokerClient.initialRetryDelay
    private static let initialRetryDelay: TimeInterval = 2
    private static let maximumRetryDelay: TimeInterval = 30

    public init(identity: @escaping @Sendable () -> (any IdentityServing)?) {
        self.identity = identity
    }

    // MARK: - Lifecycle

    /// Connects and registers. Safe to call more than once; a live connection is
    /// left alone.
    public func start() {
        queue.async { [self] in self.connectAndRegisterIfNeeded() }
    }

    /// Idempotent, and safe to call at any time.
    ///
    /// The components can be installed while the app is already running, and the
    /// daemon can be restarted underneath it. Rather than polling — which this
    /// project deliberately avoids — every path that cares about the broker
    /// calls this, so the connection repairs itself at the next thing that
    /// happens rather than at a timer.
    private func connectAndRegisterIfNeeded() {
        guard let peer = ensureConnection() else {
            if !loggedUnavailable {
                loggedUnavailable = true
                AppLogger.unlock.notice("Lock-screen unlock is not installed or not reachable")
            }
            scheduleRetry()
            return
        }
        loggedUnavailable = false
        // Registration is re-sent even when this client believes it is already
        // registered, because that belief is not authoritative. The broker keys
        // agents by uid, so a second instance of the app — a test host, a debug
        // build launched alongside the installed one — registers over the top of
        // this one, and when *it* exits the broker is left with no agent for the
        // uid at all. This client cannot observe that happening: its own
        // connection is still alive and its flag still says "registered", so the
        // retry timer stays cancelled and the lock screen silently has nobody to
        // ask. Re-sending costs one message on a refresh that was happening
        // anyway, and it is idempotent on the broker's side.
        sendRegistration(on: peer)
    }

    /// Keeps trying until the app is registered, then stops completely.
    ///
    /// The components can be installed, or the daemon replaced, while the app is
    /// already running, and there is no notification for either. Waiting for the
    /// app's next refresh is not good enough: the window between installing and
    /// the first unlock attempt can be seconds, and an unregistered app means the
    /// lock screen falls back to the password with no indication why.
    ///
    /// This is the one place in the app that retries on a timer rather than on an
    /// event. It is bounded in the way that matters — it does nothing but a file
    /// check and, at most, one connection attempt; it backs off to
    /// `maximumRetryDelay`; and it cancels itself as soon as registration
    /// succeeds. No camera, no recognition, nothing that costs power.
    private func scheduleRetry() {
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + retryDelay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.retryTimer = nil
            self.retryDelay = min(self.retryDelay * 2, BrokerClient.maximumRetryDelay)
            self.connectAndRegisterIfNeeded()
        }
        retryTimer = timer
        timer.resume()
    }

    private func stopRetrying() {
        retryTimer?.cancel()
        retryTimer = nil
        retryDelay = BrokerClient.initialRetryDelay
    }

    public func stop() {
        queue.async { [self] in
            stopRetrying()
            if let connection { xpc_connection_cancel(connection) }
            connection = nil
            registered.value = false
        }
    }

    /// Whether the broker is installed, running and willing to talk to us.
    /// Used by `LockScreenUnlockProvider` to report capability honestly rather
    /// than assuming the daemon is there.
    public func checkAvailability() async -> Availability {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard Self.brokerRequirement() != nil else {
                    continuation.resume(returning: .unavailable("the broker is not installed"))
                    return
                }
                self.connectAndRegisterIfNeeded()
                guard let peer = connection else {
                    continuation.resume(returning: .unavailable("the broker could not be reached"))
                    return
                }
                let message = xpc_dictionary_create(nil, nil, 0)
                xpc_dictionary_set_uint64(message, BrokerProtocol.Key.version, BrokerProtocol.version)
                xpc_dictionary_set_uint64(
                    message, BrokerProtocol.Key.message, BrokerProtocol.Message.handshake.rawValue)
                xpc_connection_send_message_with_reply(peer, message, queue) { reply in
                    guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
                          xpc_dictionary_get_bool(reply, BrokerProtocol.Key.ok),
                          xpc_dictionary_get_uint64(reply, BrokerProtocol.Key.version)
                              == BrokerProtocol.version
                    else {
                        continuation.resume(
                            returning: .unavailable("the broker answered with a different protocol"))
                        return
                    }
                    continuation.resume(returning: .available)
                }
            }
        }
    }

    // MARK: - Connection

    /// The requirement the broker must satisfy, written by `install.sh`. Its
    /// absence is how the app knows the feature is not installed, and a broker
    /// we cannot identify is one we do not talk to.
    private static func brokerRequirement() -> String? {
        guard let data = FileManager.default.contents(atPath: BrokerProtocol.peersPlistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: String],
              let requirement = plist[BrokerProtocol.brokerRequirementKey],
              !requirement.isEmpty
        else { return nil }
        return requirement
    }

    /// The single connection, created on first need. Everything here runs on
    /// `queue`, so "exactly one connection" is an invariant rather than a race.
    private func ensureConnection() -> xpc_connection_t? {
        if let connection { return connection }
        guard let requirement = Self.brokerRequirement() else { return nil }
        guard let peer = connect(pinnedTo: requirement) else { return nil }
        connection = peer
        return peer
    }

    private func connect(pinnedTo requirement: String) -> xpc_connection_t? {
        let peer = xpc_connection_create_mach_service(BrokerProtocol.agentServiceName, queue, 0)
        let pinned = requirement.withCString {
            xpc_connection_set_peer_code_signing_requirement(peer, $0)
        }
        guard pinned == 0 else {
            AppLogger.unlock.error("The broker requirement could not be applied; not connecting")
            xpc_connection_cancel(peer)
            return nil
        }
        xpc_connection_set_event_handler(peer) { [weak self] event in
            self?.handle(event)
        }
        xpc_connection_resume(peer)
        return peer
    }

    private func sendRegistration(on peer: xpc_connection_t) {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(message, BrokerProtocol.Key.version, BrokerProtocol.version)
        xpc_dictionary_set_uint64(
            message, BrokerProtocol.Key.message, BrokerProtocol.Message.registerAgent.rawValue)
        xpc_connection_send_message_with_reply(peer, message, queue) { [weak self] reply in
            guard let self else { return }
            if xpc_get_type(reply) == XPC_TYPE_DICTIONARY,
               xpc_dictionary_get_bool(reply, BrokerProtocol.Key.ok) {
                registered.value = true
                stopRetrying()
                AppLogger.unlock.notice("Registered with the lock-screen broker")
                return
            }
            registered.value = false
            // Distinguish "the daemon is not there" from "the daemon said no".
            // The first is ordinary — the components may not be installed yet, or
            // the daemon may be restarting — and only the second is a real
            // refusal worth reporting as an error.
            if reply === XPC_ERROR_CONNECTION_INVALID || reply === XPC_ERROR_CONNECTION_INTERRUPTED {
                connection = nil
                AppLogger.unlock.notice("The lock-screen broker is not reachable yet; will retry")
            } else {
                AppLogger.unlock.error("The broker refused this app as an agent")
            }
            scheduleRetry()
        }
    }

    // MARK: - Answering

    private func handle(_ event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            // The daemon stopped or was replaced. Drop the connection; `start()`
            // rebuilds it, and until then the mechanism simply denies and the
            // password branch takes over.
            queue.async { [self] in
                connection = nil
                registered.value = false
                scheduleRetry()
            }
            return
        }
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY,
              xpc_dictionary_get_uint64(event, BrokerProtocol.Key.version) == BrokerProtocol.version,
              xpc_dictionary_get_uint64(event, BrokerProtocol.Key.message)
                  == BrokerProtocol.Message.challenge.rawValue
        else { return }

        var length = 0
        guard let pointer = xpc_dictionary_get_data(event, BrokerProtocol.Key.nonce, &length),
              length == BrokerProtocol.nonceLength,
              let reply = xpc_dictionary_create_reply(event)
        else { return }

        guard let peer = connection else { return }
        let nonce = ChallengeNonce(bytes: Data(bytes: pointer, count: length))
        let boxedReply = Transferred(object: reply)
        let boxedPeer = Transferred(object: peer)

        Task { [identity] in
            guard let identity = identity() else {
                AppLogger.unlock.error("A challenge arrived before the app was ready; declining")
                Self.send(
                    verdict: .refused(.attemptFailed), for: nonce,
                    reply: boxedReply, peer: boxedPeer)
                return
            }
            // Slightly inside the broker's own TTL, so that a slow attempt is
            // refused here rather than answered into a challenge that has
            // already expired.
            let verdict = await identity.answerChallenge(
                nonce, deadline: .milliseconds(Int(BrokerProtocol.challengeTTL * 1000) - 500))
            Self.send(verdict: verdict, for: nonce, reply: boxedReply, peer: boxedPeer)
        }
    }

    private static func send(
        verdict: IdentityVerdict,
        for nonce: ChallengeNonce,
        reply: Transferred,
        peer: Transferred
    ) {
        // The nonce is echoed so the broker can bind this answer to the
        // challenge it minted. An answer that does not carry it is discarded.
        nonce.bytes.withUnsafeBytes { raw in
            xpc_dictionary_set_data(reply.object, BrokerProtocol.Key.nonce, raw.baseAddress, raw.count)
        }
        xpc_dictionary_set_bool(reply.object, BrokerProtocol.Key.verdict, verdict.recognised)
        if let refusal = verdict.refusal {
            xpc_dictionary_set_string(reply.object, BrokerProtocol.Key.refusal, refusal.rawValue)
        }
        xpc_connection_send_message(peer.object, reply.object)
        AppLogger.unlock.notice(
            "Answered a lock-screen challenge: \(verdict.recognised ? "recognised" : "not recognised", privacy: .public)"
        )
    }
}
