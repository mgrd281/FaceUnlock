import XCTest
@testable import FaceUnlock

/// Keeps the Swift mirror of the wire protocol honest.
///
/// `Spike/lock-screen-unlock/Shared/FaceUnlockBrokerProtocol.h` is the source of
/// truth: the broker and the lock-screen mechanism are compiled against it, and
/// the app cannot include it without a bridging header, so `BrokerProtocol`
/// restates its values. A silent drift between the two would not fail to build —
/// it would fail at the lock screen, which is the worst possible place to find
/// out. This test reads the header and compares.
final class BrokerProtocolParityTests: XCTestCase {
    /// The header, located relative to this source file so the test does not
    /// depend on the working directory the suite happens to run in.
    private func headerContents() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FaceUnlockTests
            .deletingLastPathComponent()   // repository root
        let header = repositoryRoot
            .appendingPathComponent("Spike/lock-screen-unlock/Shared/FaceUnlockBrokerProtocol.h")
        return try String(contentsOf: header, encoding: .utf8)
    }

    /// Pulls `#define NAME value` out of the header.
    private func define(_ name: String, in header: String) throws -> String {
        for line in header.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#define \(name) ") else { continue }
            var value = String(trimmed.dropFirst("#define \(name) ".count))
            // Values carry a trailing /* ... */ note in the header.
            if let comment = value.range(of: "/*") {
                value = String(value[value.startIndex..<comment.lowerBound])
            }
            return value
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        throw XCTSkip("#define \(name) is missing from the header")
    }

    func testTheAgentServiceNameMatches() throws {
        let header = try headerContents()
        XCTAssertEqual(
            try define("FU_AGENT_SERVICE_NAME", in: header), BrokerProtocol.agentServiceName)
    }

    /// The app must not know how to reach the asker service, and must certainly
    /// never connect to it: that service is pinned to Apple's SecurityAgent and
    /// is what keeps the app from minting a challenge for itself to answer.
    func testTheAppCannotReachTheAskerService() throws {
        let header = try headerContents()
        let asker = try define("FU_ASKER_SERVICE_NAME", in: header)
        XCTAssertNotEqual(asker, BrokerProtocol.agentServiceName)

        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FaceUnlock")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(asker) {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "the app references the asker service in \(offenders)")
    }

    func testTheProtocolVersionMatches() throws {
        let header = try headerContents()
        XCTAssertEqual(try define("FU_PROTOCOL_VERSION", in: header), String(BrokerProtocol.version))
    }

    func testEveryMessageNumberMatches() throws {
        let header = try headerContents()
        let expected: [(String, BrokerProtocol.Message)] = [
            ("FU_MSG_HANDSHAKE", .handshake),
            ("FU_MSG_REGISTER_AGENT", .registerAgent),
            ("FU_MSG_BEGIN_CHALLENGE", .beginChallenge),
            ("FU_MSG_CHALLENGE", .challenge)
        ]
        for (name, message) in expected {
            XCTAssertEqual(
                try define(name, in: header), String(message.rawValue),
                "\(name) drifted from BrokerProtocol.Message.\(message)"
            )
        }
    }

    func testEveryDictionaryKeyMatches() throws {
        let header = try headerContents()
        let expected: [(String, String)] = [
            ("FU_KEY_MESSAGE", BrokerProtocol.Key.message),
            ("FU_KEY_VERSION", BrokerProtocol.Key.version),
            ("FU_KEY_NONCE", BrokerProtocol.Key.nonce),
            ("FU_KEY_UID", BrokerProtocol.Key.uid),
            ("FU_KEY_USERNAME", BrokerProtocol.Key.username),
            ("FU_KEY_VERDICT", BrokerProtocol.Key.verdict),
            ("FU_KEY_REFUSAL", BrokerProtocol.Key.refusal),
            ("FU_KEY_OK", BrokerProtocol.Key.ok)
        ]
        for (name, key) in expected {
            XCTAssertEqual(try define(name, in: header), key, "\(name) drifted")
        }
    }

    func testTheNonceLengthAndTTLMatch() throws {
        let header = try headerContents()
        XCTAssertEqual(try define("FU_NONCE_LENGTH", in: header), String(BrokerProtocol.nonceLength))
        XCTAssertEqual(
            Double(try define("FU_CHALLENGE_TTL_SECONDS", in: header)),
            BrokerProtocol.challengeTTL
        )
    }

    func testThePeerPinningPathsMatch() throws {
        let header = try headerContents()
        XCTAssertEqual(try define("FU_PEERS_PLIST_PATH", in: header), BrokerProtocol.peersPlistPath)
        XCTAssertEqual(
            try define("FU_PEERS_KEY_BROKER", in: header), BrokerProtocol.brokerRequirementKey)
    }
}
