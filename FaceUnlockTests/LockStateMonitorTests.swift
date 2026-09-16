import XCTest
@testable import FaceUnlock

final class LockStateMonitorTests: XCTestCase {
    func testEventsAreDeliveredInOrder() async {
        let monitor = StubLockStateMonitor()
        let stream = monitor.events()

        let expected: [LockEvent] = [.screenLocked, .screensDidWake, .screenUnlocked]
        let collector = Task { () -> [LockEvent] in
            var received: [LockEvent] = []
            for await event in stream {
                received.append(event)
                if received.count == expected.count { break }
            }
            return received
        }

        for event in expected { monitor.send(event) }
        let received = await collector.value
        XCTAssertEqual(received, expected)
    }

    func testLockStateIsReported() {
        let monitor = StubLockStateMonitor(locked: false)
        XCTAssertFalse(monitor.isScreenLocked())
        monitor.setLocked(true)
        XCTAssertTrue(monitor.isScreenLocked())
    }

    func testStoppingFinishesTheStream() async {
        let monitor = StubLockStateMonitor()
        let stream = monitor.events()
        let collector = Task { () -> Int in
            var count = 0
            for await _ in stream { count += 1 }
            return count
        }
        monitor.send(.screenLocked)
        monitor.send(.systemDidWake)
        monitor.stop()
        let count = await collector.value
        XCTAssertEqual(count, 2)
    }

    func testEveryEventHasAStableIdentifier() {
        // The raw values end up in logs and diagnostics, so they must stay unique.
        let identifiers = Set(
            [
                LockEvent.screenLocked, .screenUnlocked, .screensaverStarted, .screensaverStopped,
                .systemWillSleep, .systemDidWake, .screensDidWake, .screensDidSleep,
                .sessionDidResignActive, .sessionDidBecomeActive
            ].map(\.rawValue)
        )
        XCTAssertEqual(identifiers.count, 10)
    }
}
