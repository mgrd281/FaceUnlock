import Foundation

/// The result of asking whether a newer build exists.
public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(version: String, releaseNotesURL: URL?, downloadURL: URL?)
    case failed(String)
    case disabled
}

public protocol UpdateChecking: Sendable {
    func checkForUpdates() async -> UpdateCheckResult
}

/// The only component in FaceUnlock that is allowed to use the network.
///
/// It is isolated on purpose: nothing in the recognition, enrolment, liveness or
/// unlock paths can reach it, so a failed match can never cause a network
/// request. The request carries no identifier of any kind — no machine ID, no
/// account, no install UUID — just an unauthenticated GET of a version manifest,
/// and only when the user has switched update checks on.
///
/// The manifest is expected to be a JSON document of the form:
/// ```json
/// { "version": "1.2.0", "notes": "https://…", "download": "https://…" }
/// ```
public struct UpdateChecker: UpdateChecking {
    private let feedURL: URL
    private let currentVersion: String
    private let isEnabled: @Sendable () -> Bool
    private let session: URLSession

    public init(
        feedURL: URL,
        currentVersion: String,
        isEnabled: @escaping @Sendable () -> Bool,
        session: URLSession = UpdateChecker.makeSession()
    ) {
        self.feedURL = feedURL
        self.currentVersion = currentVersion
        self.isEnabled = isEnabled
        self.session = session
    }

    /// A session with cookies, caching and credential storage switched off, so a
    /// version check cannot become a tracking channel.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    public func checkForUpdates() async -> UpdateCheckResult {
        guard isEnabled() else { return .disabled }
        var request = URLRequest(url: feedURL)
        request.httpMethod = "GET"
        request.setValue("FaceUnlock", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed("The update service returned an unexpected response.")
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            AppLogger.update.notice("Update manifest fetched")
            guard Self.isNewer(manifest.version, than: currentVersion) else {
                return .upToDate(currentVersion: currentVersion)
            }
            return .updateAvailable(
                version: manifest.version,
                releaseNotesURL: manifest.notes.flatMap(URL.init(string:)),
                downloadURL: manifest.download.flatMap(URL.init(string:))
            )
        } catch is CancellationError {
            return .failed("The update check was cancelled.")
        } catch {
            AppLogger.update.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed("FaceUnlock could not reach the update service.")
        }
    }

    struct Manifest: Decodable {
        let version: String
        let notes: String?
        let download: String?
    }

    /// Numeric, component-wise comparison so "1.10.0" sorts above "1.9.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}

/// Test double.
public struct StubUpdateChecker: UpdateChecking {
    public let result: UpdateCheckResult
    public init(result: UpdateCheckResult) { self.result = result }
    public func checkForUpdates() async -> UpdateCheckResult { result }
}
