import Foundation

/// The wire protocol between the app, the root broker and the lock-screen
/// mechanism.
///
/// These values mirror `Spike/lock-screen-unlock/Shared/FaceUnlockBrokerProtocol.h`,
/// which is the source of truth: the broker and the mechanism are built from
/// that header directly, and the app cannot include it without a bridging
/// header. `BrokerProtocolParityTests` reads the header and fails if the two
/// ever drift, so the duplication is checked rather than trusted.
///
/// Everything that crosses this boundary is a nonce, a uid and a boolean. No
/// image, no descriptor, no profile and no password.
public enum BrokerProtocol {
    /// The agent service. The app only ever reaches this one; the service that
    /// mints challenges is pinned to Apple's SecurityAgent and is deliberately
    /// out of the app's reach, so it cannot mint a challenge for itself to
    /// answer. See DESIGN.md §4.
    public static let agentServiceName = "de.faceunlock.broker.agent"
    public static let version: UInt64 = 1

    public enum Message: UInt64 {
        case handshake = 1
        case registerAgent = 2
        case beginChallenge = 3
        case challenge = 4
    }

    public enum Key {
        public static let message = "msg"
        public static let version = "version"
        public static let nonce = "nonce"
        public static let uid = "uid"
        public static let username = "username"
        public static let verdict = "verdict"
        public static let refusal = "refusal"
        public static let ok = "ok"
    }

    public static let nonceLength = 32
    public static let challengeTTL: TimeInterval = 10.0

    /// Written by `install.sh`; read here so the app can pin the broker in turn.
    /// A daemon we cannot identify is one we do not talk to.
    public static let peersPlistPath = "/Library/Application Support/FaceUnlock/peers.plist"
    public static let brokerRequirementKey = "BrokerRequirement"
}
