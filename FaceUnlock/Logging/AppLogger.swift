import Foundation
import os

/// Central, privacy-aware logging facade.
///
/// Every category is a distinct `os.Logger` so that `log stream --predicate` can
/// isolate a subsystem while debugging. Sensitive values (passwords, embeddings,
/// face imagery, Keychain payloads) must never be passed to these loggers, not
/// even behind `privacy: .private` — see `SECURITY.md`.
public enum AppLogger {
    public static let subsystem = "de.faceunlock.mac"

    public static let lifecycle = Logger(subsystem: subsystem, category: "AppLifecycle")
    public static let camera = Logger(subsystem: subsystem, category: "Camera")
    public static let recognition = Logger(subsystem: subsystem, category: "Recognition")
    public static let liveness = Logger(subsystem: subsystem, category: "Liveness")
    public static let permissions = Logger(subsystem: subsystem, category: "Permissions")
    public static let unlock = Logger(subsystem: subsystem, category: "Unlock")
    public static let security = Logger(subsystem: subsystem, category: "Security")
    public static let keychain = Logger(subsystem: subsystem, category: "Keychain")
    public static let update = Logger(subsystem: subsystem, category: "Update")
}
