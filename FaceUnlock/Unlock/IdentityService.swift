import Darwin
import Foundation

/// Answers one question, for one trusted caller, over a local socket:
/// *is the enrolled user in front of the camera right now?*
///
/// This is the user-session half of the lock-screen unlock design
/// (`Spike/lock-screen-unlock/DESIGN.md`). The camera and the encrypted profile
/// live here, in the logged-in user's session, because that is where the TCC
/// grant and the Keychain item already are. A future root broker connects to
/// this service and relays the question from the lock screen; nothing is
/// installed and no privilege is involved on this side.
///
/// It is **off unless explicitly asked for**: `AppEnvironment` starts it only
/// when `FACEUNLOCK_IDENTITY_SOCKET` names a path, so an ordinary run of the app
/// never opens a socket. The answer is an *identity* verdict from the full
/// recognition pipeline — model, per-user threshold and liveness — never "a face
/// is present". And it is only ever an answer: this service cannot unlock
/// anything, it reports yes or no and the privileged side decides what to do
/// with that, always leaving the password in place.
public final class IdentityService: @unchecked Sendable {
    /// Runs one recognition attempt and reports whether it was the enrolled user.
    /// Returns quickly with `false` rather than throwing, because a broker asking
    /// at the lock screen has nothing useful to do with an error but fall through
    /// to the password.
    public typealias Verify = @Sendable (_ nonce: String) async -> Bool

    private let socketPath: String
    private let verify: Verify
    private let queue = DispatchQueue(label: "de.faceunlock.identity.accept")
    private var listener: Int32 = -1
    private var running = false

    public init(socketPath: String, verify: @escaping Verify) {
        self.socketPath = socketPath
        self.verify = verify
    }

    public func start() {
        queue.async { [self] in
            guard let descriptor = Self.makeListeningSocket(at: socketPath) else { return }
            listener = descriptor
            running = true
            AppLogger.unlock.notice("Identity service listening")
            acceptLoop()
        }
    }

    public func stop() {
        queue.async { [self] in
            running = false
            if listener >= 0 { close(listener); listener = -1 }
            unlink(socketPath)
        }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                if running { AppLogger.unlock.error("Identity accept failed") }
                return
            }
            // Each request runs the camera for a few seconds, so handle
            // connections off the accept thread and one at a time is fine: the
            // lock screen asks once.
            handle(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 128)
        let received = read(client, &buffer, buffer.count)
        guard received > 0 else { return }
        let request = String(decoding: buffer[0..<received], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Protocol: "CHALLENGE <nonce>". The nonce is echoed back with the
        // verdict so the caller can bind the answer to the question it asked;
        // the anti-replay guarantee that the nonce is fresh and single-use is
        // enforced by the privileged broker that issues it, not here.
        let parts = request.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0] == "CHALLENGE" else {
            _ = "ERR bad-request\n".withCString { write(client, $0, strlen($0)) }
            return
        }
        let nonce = String(parts[1])

        // Bridge to the async pipeline. This runs on the accept queue, not inside
        // any actor or async context, so waiting here is safe.
        let semaphore = DispatchSemaphore(value: 0)
        let recognised = UnsafeSendableBox(false)
        Task {
            recognised.value = await verify(nonce)
            semaphore.signal()
        }
        semaphore.wait()

        let answer = recognised.value ? "OK \(nonce)\n" : "NO \(nonce)\n"
        _ = answer.withCString { write(client, $0, strlen($0)) }
        AppLogger.unlock.notice("Identity challenge answered \(recognised.value ? "OK" : "NO", privacy: .public)")
    }

    private static func makeListeningSocket(at path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            AppLogger.unlock.error("Identity socket() failed")
            return nil
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            AppLogger.unlock.error("Identity socket path too long")
            close(descriptor)
            return nil
        }
        unlink(path)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                _ = strncpy(destination, path, capacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            AppLogger.unlock.error("Identity bind() failed")
            close(descriptor)
            return nil
        }
        // Only this user may reach the socket; the privileged broker connecting in
        // Stage 2 runs as root, which is not restricted by this.
        chmod(path, 0o600)
        guard listen(descriptor, 2) == 0 else {
            AppLogger.unlock.error("Identity listen() failed")
            close(descriptor)
            return nil
        }
        return descriptor
    }
}

/// A minimal box for carrying a value out of a `Task` across a semaphore. Access
/// is ordered by the semaphore (write before signal, read after wait), so it
/// needs no lock of its own.
private final class UnsafeSendableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
