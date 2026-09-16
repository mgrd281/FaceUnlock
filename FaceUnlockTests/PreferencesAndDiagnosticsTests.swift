import XCTest
@testable import FaceUnlock

final class PreferencesAndDiagnosticsTests: XCTestCase {
    /// Runs `body` against a private, throwaway `UserDefaults` suite.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "faceunlock.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    func testDefaultsAreTheSafeOnes() throws {
        try withScratchDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            XCTAssertTrue(preferences.unlockEnabled)
            XCTAssertFalse(preferences.showInDock)
            XCTAssertFalse(preferences.hasCompletedOnboarding)
            XCTAssertTrue(preferences.protectSettings)
            XCTAssertFalse(preferences.analyticsEnabled, "analytics must default to off")
            XCTAssertFalse(preferences.automaticUpdateChecks, "network access must default to off")
            XCTAssertFalse(
                preferences.allowAssistedLockScreenEntry,
                "assisted lock-screen entry must be opt-in"
            )
            XCTAssertFalse(preferences.isPaused)
            XCTAssertEqual(preferences.recognitionSettings, .default)
        }
    }

    @MainActor
    func testSettingsSurviveAReload() throws {
        try withScratchDefaults { defaults in
            let first = Preferences(defaults: defaults)
            first.recognitionSettings.sensitivity = .strict
            first.showInDock = true

            let second = Preferences(defaults: defaults)
            XCTAssertEqual(second.recognitionSettings.sensitivity, .strict)
            XCTAssertTrue(second.showInDock)
        }
    }

    @MainActor
    func testPauseAndResume() throws {
        try withScratchDefaults { defaults in
            let preferences = Preferences(defaults: defaults)
            preferences.pause(until: Date().addingTimeInterval(60))
            XCTAssertTrue(preferences.isPaused)
            preferences.resume()
            XCTAssertFalse(preferences.isPaused)

            preferences.pause(until: Date().addingTimeInterval(-60))
            XCTAssertFalse(preferences.isPaused, "an elapsed pause must not still count as paused")
        }
    }

    /// A hand-edited preferences file must not be able to widen the envelope.
    func testOutOfRangeSettingsAreClamped() {
        let hostile = RecognitionSettings(
            sensitivity: .convenient,
            livenessMode: .passive,
            attemptTimeout: 100_000,
            startDelayAfterLock: -50,
            processingFrameRate: 240
        ).sanitized()
        XCTAssertEqual(hostile.attemptTimeout, 30)
        XCTAssertEqual(hostile.startDelayAfterLock, 0)
        XCTAssertEqual(hostile.processingFrameRate, 15)

        let tiny = RecognitionSettings(
            sensitivity: .strict, livenessMode: .passive,
            attemptTimeout: 0, startDelayAfterLock: 0, processingFrameRate: 0
        ).sanitized()
        XCTAssertEqual(tiny.attemptTimeout, 5)
        XCTAssertEqual(tiny.processingFrameRate, 2)
    }

    func testPresetsAreOrderedFromStrictToPermissive() {
        for source in [FaceEmbedding.Source.visionFeaturePrint, .coreMLModel] {
            XCTAssertGreaterThan(
                SensitivityPreset.strict.scoreFloor(for: source), SensitivityPreset.balanced.scoreFloor(for: source)
            )
            XCTAssertGreaterThan(
                SensitivityPreset.balanced.scoreFloor(for: source), SensitivityPreset.convenient.scoreFloor(for: source)
            )
        }
        XCTAssertGreaterThan(
            SensitivityPreset.strict.requiredConsecutiveMatches,
            SensitivityPreset.convenient.requiredConsecutiveMatches
        )
        XCTAssertGreaterThan(
            SensitivityPreset.strict.livenessFloor, SensitivityPreset.convenient.livenessFloor
        )
    }

    /// Even the most permissive preset must stay well clear of a coin flip.
    func testEvenTheMostPermissivePresetIsNotWeak() {
        XCTAssertGreaterThan(SensitivityPreset.convenient.scoreFloor(for: .visionFeaturePrint), 0.8)
        XCTAssertGreaterThan(SensitivityPreset.convenient.scoreFloor(for: .coreMLModel), 0.7)
        XCTAssertGreaterThanOrEqual(SensitivityPreset.convenient.requiredConsecutiveMatches, 3)
        XCTAssertGreaterThan(SensitivityPreset.convenient.livenessFloor, 0.5)
    }

    // MARK: Diagnostics

    private func makeSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0", buildNumber: "1",
            osVersion: "15.0.0", hardwareArchitecture: "arm64", hardwareModel: "Mac15,3",
            cameraDetected: true, cameraIsBuiltIn: true,
            cameraPermission: "granted", accessibilityPermission: "denied",
            loginItemStatus: "Enabled",
            recognitionEngine: "VNFeaturePrint.r2+geometry.v1",
            descriptorDimension: 2114, profileSampleCount: 18,
            profileCreatedAt: Date(timeIntervalSince1970: 1_699_000_000),
            profileUpdatedAt: Date(timeIntervalSince1970: 1_699_500_000),
            recognitionThreshold: 0.9123, sensitivityPreset: "balanced",
            livenessMode: "adaptiveChallenge",
            lastRecognitionResult: "recognized", lastRecognitionAt: Date(),
            lastError: nil, lastErrorAt: nil,
            averageRecognitionLatency: 1.75, attemptSummary: "4 of 5 (80%)",
            unlockCapability: "Limited",
            unlockProviders: [
                .init(identifier: "presence", capability: "Supported", availableNow: true)
            ],
            credentialStored: true, analyticsEnabled: false,
            networkUsage: "No network access"
        )
    }

    func testDiagnosticsExportContainsTheUsefulFacts() {
        let text = makeSnapshot().plainText()
        XCTAssertTrue(text.contains("macOS 15.0.0"))
        XCTAssertTrue(text.contains("VNFeaturePrint.r2+geometry.v1"))
        XCTAssertTrue(text.contains("Recognition threshold: 0.9123"))
        XCTAssertTrue(text.contains("presence"))
    }

    /// The export is a privacy boundary, so assert on what it must never contain.
    func testDiagnosticsExportLeaksNothingSensitive() {
        let snapshot = makeSnapshot()
        let text = snapshot.plainText().lowercased()
        for forbidden in ["embedding", "descriptor value", "0.6, 0.8", "keychain payload"] {
            XCTAssertFalse(text.contains(forbidden), "export must not mention \(forbidden)")
        }
        // It may say whether a password exists, never what it is.
        XCTAssertTrue(text.contains("password stored in keychain: yes"))
        XCTAssertFalse(text.contains("hunter2"))
    }

    func testDiagnosticsSnapshotIsCodable() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    func testEveryErrorHasAUsableMessage() {
        let errors: [FaceUnlockError] = [
            .cameraPermissionDenied, .cameraUnavailable, .cameraBusy, .cameraStartFailed("x"),
            .accessibilityPermissionRequired, .noEnrolledProfile, .profileCorrupted,
            .enrollmentIncomplete(capturedSamples: 1, requiredSamples: 18),
            .enrollmentQualityTooLow("x"),
            .recognitionConfidenceTooLow(score: 0.5, threshold: 0.9),
            .livenessFailed(reason: "x"), .unlockUnavailableOnThisSystem,
            .unlockVerificationFailed("x"), .unlockAlreadyInProgress, .timedOut,
            .keychainFailure(status: -1), .credentialMissing, .credentialValidationFailed,
            .localAuthenticationFailed("x"), .loginItemRegistrationFailed("x"),
            .embeddingFailed("x"), .cancelled
        ]
        var codes = Set<String>()
        for error in errors {
            XCTAssertGreaterThan(
                error.message.count, 15,
                "\(error.code) should read as a sentence a user can act on"
            )
            codes.insert(error.code)
        }
        XCTAssertEqual(codes.count, errors.count, "error codes must be unique")
    }
}
