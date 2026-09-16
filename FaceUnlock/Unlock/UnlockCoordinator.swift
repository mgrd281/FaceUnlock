import Foundation

public struct UnlockOutcome: Equatable, Sendable {
    public let providerIdentifier: String
    public let providerName: String
    public let capability: SessionUnlockCapability
    public let completedAt: Date
}

public protocol UnlockCoordinating: Sendable {
    func bestAvailableCapability() async -> SessionUnlockCapability
    func unlock() async throws -> UnlockOutcome
    func providerSummaries() async -> [ProviderSummary]
}

public struct ProviderSummary: Identifiable, Equatable, Sendable {
    public var id: String { identifier }
    public let identifier: String
    public let displayName: String
    public let explanation: String
    public let capability: SessionUnlockCapability
    public let availableNow: Bool
}

/// Chooses and runs exactly one unlock provider per attempt.
///
/// Two invariants this type exists to guarantee:
/// 1. **The safest provider always wins.** Providers are sorted by `safetyRank`
///    and the first one that reports it can act is used; there is no scoring, no
///    preference setting and no way for a less safe provider to jump the queue.
/// 2. **Never two attempts at once.** A second call while an attempt is running
///    throws instead of queueing, so a burst of recognised frames cannot turn into
///    a burst of password entries.
public actor UnlockCoordinator: UnlockCoordinating {
    private let providers: [any UnlockProvider]
    private var attemptInProgress = false
    private var lastAttemptAt: Date?
    /// Minimum spacing between attempts, so a flapping lock state cannot drive a
    /// tight loop of unlock attempts.
    private let minimumInterval: TimeInterval = 2.0

    public init(providers: [any UnlockProvider]) {
        self.providers = providers.sorted { $0.safetyRank < $1.safetyRank }
    }

    public func bestAvailableCapability() async -> SessionUnlockCapability {
        var best = SessionUnlockCapability.unsupported
        for provider in providers {
            let capability = await provider.capability()
            switch capability {
            case .supported:
                return .supported
            case .limited:
                best = .limited
            case .unsupported:
                continue
            }
        }
        return best
    }

    public func providerSummaries() async -> [ProviderSummary] {
        var summaries: [ProviderSummary] = []
        for provider in providers {
            summaries.append(
                ProviderSummary(
                    identifier: provider.identifier,
                    displayName: provider.displayName,
                    explanation: provider.explanation,
                    capability: await provider.capability(),
                    availableNow: await provider.canUnlockCurrentState()
                )
            )
        }
        return summaries
    }

    public func unlock() async throws -> UnlockOutcome {
        guard !attemptInProgress else {
            throw FaceUnlockError.unlockAlreadyInProgress
        }
        if let lastAttemptAt, Date().timeIntervalSince(lastAttemptAt) < minimumInterval {
            throw FaceUnlockError.unlockAlreadyInProgress
        }
        attemptInProgress = true
        defer {
            attemptInProgress = false
            lastAttemptAt = Date()
        }

        for provider in providers {
            guard await provider.canUnlockCurrentState() else { continue }
            AppLogger.unlock.notice(
                "Using unlock provider \(provider.identifier, privacy: .public)"
            )
            try await provider.attemptUnlock()
            return UnlockOutcome(
                providerIdentifier: provider.identifier,
                providerName: provider.displayName,
                capability: await provider.capability(),
                completedAt: Date()
            )
        }

        AppLogger.unlock.error("No unlock provider could act on the current session state")
        throw FaceUnlockError.unlockUnavailableOnThisSystem
    }
}
