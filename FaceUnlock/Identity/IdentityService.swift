import Foundation

/// A challenge minted by the broker. Opaque here: the app never generates one
/// and never interprets one, it only proves it answered *this* challenge.
public struct ChallengeNonce: Equatable, Sendable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public var isWellFormed: Bool { bytes.count == BrokerProtocol.nonceLength }
}

/// Why a challenge was not satisfied. Carried for the log only — it is deliberately
/// coarse, and never contains a score, a threshold or anything derived from an image.
public enum IdentityRefusal: String, Equatable, Sendable {
    case unlockDisabled
    case noProfileEnrolled
    /// The profile file is present but could not be read — typically because it
    /// cannot be decrypted with the key now in the Keychain. Distinct from
    /// `noProfileEnrolled` because the remedy differs: enrol, versus re-enrol.
    case profileUnreadable
    case profileIncompatible
    case notRecognised
    case attemptFailed
    case deadlineExceeded
    case malformedChallenge
    case challengeReplayed
}

/// The answer to one challenge. One bit, plus a reason when it is `false`.
public struct IdentityVerdict: Equatable, Sendable {
    public let recognised: Bool
    public let refusal: IdentityRefusal?

    public static let recognisedVerdict = IdentityVerdict(recognised: true, refusal: nil)

    public static func refused(_ refusal: IdentityRefusal) -> IdentityVerdict {
        IdentityVerdict(recognised: false, refusal: refusal)
    }
}

/// The narrow layer between the recognition stack and the lock screen.
///
/// The recognition stack — `RecognitionCoordinator`, `FaceMatcher`,
/// `BiometricProfileStore`, `LivenessAnalyzer` — is not reachable from a
/// SecurityAgent context, and should not be reshaped to become so. This is the
/// only part of the app the broker can address, and its entire vocabulary is one
/// question.
public protocol IdentityServing: Sendable {
    /// Runs one fresh recognition attempt, bounded by `deadline`, and answers
    /// whether the enrolled owner of this session is in front of the camera now.
    func answerChallenge(_ nonce: ChallengeNonce, deadline: Duration) async -> IdentityVerdict
}

/// What `IdentityService` needs from the recognition stack, and nothing more.
/// `RecognitionCoordinator` conforms to it, which keeps this type testable
/// without a camera in line with the dependency rule in ARCHITECTURE.md.
public protocol ChallengeRunning: Sendable {
    func runAttempt(purpose: RecognitionPurpose) async -> RecognitionAttemptResult
}

extension RecognitionCoordinator: ChallengeRunning {}

/// Answers the broker's challenges.
///
/// An `actor` because challenges must be serialised: two overlapping answers
/// would both be competing for the same camera, and the second would be racing
/// the first's frames.
public actor IdentityService: IdentityServing {
    private let recogniser: any ChallengeRunning
    private let profileStore: any BiometricProfileStoring
    private let configurationProvider: @Sendable () async -> RecognitionRuntimeConfiguration
    /// Single-use enforcement on this side too. The broker already erases a
    /// nonce when it is answered; refusing a repeat here means a replay has to
    /// defeat both independently.
    private var answeredNonces: Set<Data> = []
    private let answeredNonceLimit = 64

    public init(
        recogniser: any ChallengeRunning,
        profileStore: any BiometricProfileStoring,
        configurationProvider: @escaping @Sendable () async -> RecognitionRuntimeConfiguration
    ) {
        self.recogniser = recogniser
        self.profileStore = profileStore
        self.configurationProvider = configurationProvider
    }

    public func answerChallenge(_ nonce: ChallengeNonce, deadline: Duration) async -> IdentityVerdict {
        guard nonce.isWellFormed else {
            AppLogger.unlock.error("Refusing a malformed challenge")
            return .refused(.malformedChallenge)
        }
        guard !answeredNonces.contains(nonce.bytes) else {
            AppLogger.unlock.error("Refusing a replayed challenge")
            return .refused(.challengeReplayed)
        }
        remember(nonce.bytes)

        // The same preconditions the coordinator already enforces, checked here
        // so that a refusal is cheap and does not cost a camera start.
        let configuration = await configurationProvider()
        guard configuration.unlockEnabled else {
            return .refused(.unlockDisabled)
        }
        guard profileStore.hasProfile else {
            return .refused(.noProfileEnrolled)
        }

        return await runBounded(by: deadline)
    }

    /// Races the recognition attempt against the deadline.
    ///
    /// Losing the race is a refusal, never a wait: the mechanism on the other
    /// end has its own deadline, and an answer that arrives after it has given
    /// up is worse than no answer at all.
    private func runBounded(by deadline: Duration) async -> IdentityVerdict {
        // Deliberately not a task group.
        //
        // `withTaskGroup` awaits every child before it returns, so racing the
        // attempt against a sleeper there does not bound anything: the deadline
        // would be decided on time and then the group would sit waiting for the
        // recognition task anyway. That is exactly what happened on the first
        // real run — the verdict was settled at 5.5 s and delivered at 15.1 s,
        // long after the broker had given up on it.
        //
        // A continuation resumed by whichever finishes first has no such
        // barrier. The losing task keeps running to completion; the coordinator
        // releases the camera either way, and its result is discarded.
        let box = VerdictBox()
        return await withCheckedContinuation { continuation in
            let attempt = Task { [recogniser] in
                let verdict = Self.translate(await recogniser.runAttempt(purpose: .challenge))
                if let resume = box.claim() { resume(verdict) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                if let resume = box.claim() {
                    attempt.cancel()
                    resume(.refused(.deadlineExceeded))
                }
            }
            box.arm { verdict in continuation.resume(returning: verdict) }
        }
    }

    private static func translate(_ result: RecognitionAttemptResult) -> IdentityVerdict {
        switch result.verdict {
        case .recognized:
            return .recognisedVerdict
        case .rejected:
            return .refused(.notRecognised)
        case .failed(let error):
            // The coordinator owns every one of these decisions; they are only
            // translated here, so that a refusal names the actual cause instead
            // of collapsing to "something went wrong".
            switch error {
            case .profileIncompatible: return .refused(.profileIncompatible)
            case .noEnrolledProfile:   return .refused(.noProfileEnrolled)
            case .profileCorrupted:    return .refused(.profileUnreadable)
            default:                   return .refused(.attemptFailed)
            }
        }
    }

    private func remember(_ nonce: Data) {
        if answeredNonces.count >= answeredNonceLimit {
            answeredNonces.removeAll(keepingCapacity: true)
        }
        answeredNonces.insert(nonce)
    }
}

/// Hands the continuation to whichever of the two tasks finishes first, exactly
/// once.
///
/// A checked continuation resumed twice traps, and both tasks can plausibly
/// finish at nearly the same moment, so "who got there first" has to be settled
/// under a lock rather than by inspection.
private final class VerdictBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resume: ((IdentityVerdict) -> Void)?
    private var pending: IdentityVerdict?
    private var claimed = false

    /// Installs the continuation. If a verdict already arrived before the
    /// continuation was armed, it is delivered now.
    func arm(_ resume: @escaping (IdentityVerdict) -> Void) {
        lock.lock()
        if let pending {
            lock.unlock()
            resume(pending)
            return
        }
        self.resume = resume
        lock.unlock()
    }

    /// Returns a delivery closure to the first caller only; every later caller
    /// gets `nil` and must drop its result.
    func claim() -> ((IdentityVerdict) -> Void)? {
        lock.lock()
        guard !claimed else { lock.unlock(); return nil }
        claimed = true
        if let resume {
            self.resume = nil
            lock.unlock()
            return resume
        }
        // The continuation is not armed yet; hold the verdict for `arm`.
        lock.unlock()
        return { [weak self] verdict in
            guard let self else { return }
            lock.lock()
            if let resume = self.resume {
                self.resume = nil
                lock.unlock()
                resume(verdict)
            } else {
                self.pending = verdict
                lock.unlock()
            }
        }
    }
}

/// Test double with a scripted answer.
public actor StubIdentityService: IdentityServing {
    private var verdict: IdentityVerdict
    public private(set) var challengesAnswered: [ChallengeNonce] = []

    public init(verdict: IdentityVerdict = .recognisedVerdict) {
        self.verdict = verdict
    }

    public func setVerdict(_ newValue: IdentityVerdict) { verdict = newValue }

    public func answerChallenge(_ nonce: ChallengeNonce, deadline: Duration) async -> IdentityVerdict {
        challengesAnswered.append(nonce)
        return verdict
    }
}
