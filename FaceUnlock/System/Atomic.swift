import Foundation

/// A minimal lock-protected box.
///
/// Used where a `@Sendable` closure has to read state that lives on the main
/// actor. Reading such state with `MainActor.assumeIsolated` from a background
/// context would trap, so the value is mirrored into one of these instead.
public final class Atomic<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    public init(_ value: Value) {
        self.storage = value
    }

    public var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
