import XCTest
@testable import FaceUnlock

final class UnlockCoordinatorTests: XCTestCase {
    func testTheSafestAvailableProviderIsUsed() async throws {
        let safest = StubUnlockProvider(identifier: "safe", safetyRank: 0, canUnlock: true)
        let riskier = StubUnlockProvider(identifier: "risky", safetyRank: 50, canUnlock: true)
        let coordinator = UnlockCoordinator(providers: [riskier, safest])

        let outcome = try await coordinator.unlock()
        XCTAssertEqual(outcome.providerIdentifier, "safe")
        XCTAssertEqual(safest.attemptCount, 1)
        XCTAssertEqual(riskier.attemptCount, 0)
    }

    func testAnUnavailableProviderIsSkipped() async throws {
        let safest = StubUnlockProvider(identifier: "safe", safetyRank: 0, canUnlock: false)
        let fallback = StubUnlockProvider(identifier: "fallback", safetyRank: 100, canUnlock: true)
        let coordinator = UnlockCoordinator(providers: [safest, fallback])

        let outcome = try await coordinator.unlock()
        XCTAssertEqual(outcome.providerIdentifier, "fallback")
        XCTAssertEqual(safest.attemptCount, 0)
    }

    func testNoAvailableProviderThrows() async {
        let coordinator = UnlockCoordinator(providers: [
            StubUnlockProvider(identifier: "a", safetyRank: 0, canUnlock: false)
        ])
        do {
            _ = try await coordinator.unlock()
            XCTFail("expected a failure")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .unlockUnavailableOnThisSystem)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// A burst of recognised frames must not become a burst of unlock attempts.
    func testRepeatedAttemptsAreRateLimited() async throws {
        let provider = StubUnlockProvider(identifier: "safe", safetyRank: 0, canUnlock: true)
        let coordinator = UnlockCoordinator(providers: [provider])

        _ = try await coordinator.unlock()
        do {
            _ = try await coordinator.unlock()
            XCTFail("the second attempt should have been refused")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .unlockAlreadyInProgress)
        }
        XCTAssertEqual(provider.attemptCount, 1)
    }

    func testProviderFailurePropagates() async {
        let provider = StubUnlockProvider(identifier: "safe", safetyRank: 0, canUnlock: true)
        provider.result = .failure(.unlockVerificationFailed("test"))
        let coordinator = UnlockCoordinator(providers: [provider])
        do {
            _ = try await coordinator.unlock()
            XCTFail("expected a failure")
        } catch let error as FaceUnlockError {
            XCTAssertEqual(error, .unlockVerificationFailed("test"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testCapabilityIsTheBestOnOffer() async {
        let unsupported = StubUnlockProvider(
            identifier: "a", safetyRank: 0, canUnlock: false, capability: .unsupported
        )
        let limited = StubUnlockProvider(
            identifier: "b", safetyRank: 10, canUnlock: true, capability: .limited
        )
        let supported = StubUnlockProvider(
            identifier: "c", safetyRank: 20, canUnlock: true, capability: .supported
        )

        var capability = await UnlockCoordinator(providers: [unsupported]).bestAvailableCapability()
        XCTAssertEqual(capability, .unsupported)
        capability = await UnlockCoordinator(providers: [unsupported, limited]).bestAvailableCapability()
        XCTAssertEqual(capability, .limited)
        capability = await UnlockCoordinator(
            providers: [unsupported, limited, supported]
        ).bestAvailableCapability()
        XCTAssertEqual(capability, .supported)
    }

    func testSummariesCoverEveryProvider() async {
        let coordinator = UnlockCoordinator(providers: [
            StubUnlockProvider(identifier: "a", safetyRank: 0, canUnlock: true),
            StubUnlockProvider(identifier: "b", safetyRank: 1, canUnlock: false)
        ])
        let summaries = await coordinator.providerSummaries()
        XCTAssertEqual(summaries.map(\.identifier), ["a", "b"])
        XCTAssertEqual(summaries.map(\.availableNow), [true, false])
    }
}
