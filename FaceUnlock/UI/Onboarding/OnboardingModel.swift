import Foundation
import Observation
import SwiftUI

/// Drives the setup assistant.
///
/// The model owns the flow; the step views are stateless renderings of it. That
/// keeps the camera lifecycle in exactly one place: a step that needs the camera
/// starts it on appear and the model stops it on every transition, so leaving the
/// assistant at any point releases the device.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Step: Int, CaseIterable, Identifiable {
        case welcome
        case compatibility
        case cameraPermission
        case accessibility
        case enrollment
        case calibration
        case password
        case finished

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .compatibility: return "Compatibility"
            case .cameraPermission: return "Camera"
            case .accessibility: return "Accessibility"
            case .enrollment: return "Your face"
            case .calibration: return "Calibration"
            case .password: return "Password"
            case .finished: return "Done"
            }
        }
    }

    public private(set) var step: Step = .welcome
    public private(set) var enrollmentUpdate: EnrollmentUpdate?
    public private(set) var previewImage: CGImage?
    public private(set) var calibrationScores: [Double] = []
    public private(set) var calibrationTarget = 20
    public private(set) var isWorking = false
    public private(set) var isRequestingCamera = false
    public private(set) var draft: EnrollmentDraft?
    public private(set) var savedProfile: BiometricProfile?
    public var error: FaceUnlockError?

    private let environment: AppEnvironment
    private var coordinator: EnrollmentCoordinator?
    private var updatesTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var compatibility: SystemCompatibilityReport? { environment.compatibility }
    // Read from the environment's observed mirrors, not from `PermissionManager`
    // directly: a plain function call would not invalidate the view.
    public var cameraPermission: PermissionState { environment.cameraPermission }
    public var accessibilityPermission: PermissionState { environment.accessibilityPermission }

    public var canAdvance: Bool {
        switch step {
        case .welcome: return true
        case .compatibility: return compatibility?.canProceed ?? false
        case .cameraPermission: return cameraPermission == .granted
        case .accessibility: return true
        case .enrollment: return draft?.isUsable ?? false
        case .calibration: return savedProfile != nil
        case .password, .finished: return true
        }
    }

    public var calibrationProgress: Double {
        guard calibrationTarget > 0 else { return 0 }
        return min(1, Double(calibrationScores.count) / Double(calibrationTarget))
    }

    public var latestConfidence: Double? { calibrationScores.last }

    // MARK: Navigation

    public func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        transition(to: next)
    }

    public func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        transition(to: previous)
    }

    private func transition(to next: Step) {
        cancelWork()
        step = next
    }

    public func cancelWork() {
        updatesTask?.cancel()
        updatesTask = nil
        workTask?.cancel()
        workTask = nil
        let coordinator = self.coordinator
        self.coordinator = nil
        Task { await coordinator?.cancel() }
    }

    // MARK: Steps

    public func requestCameraAccess() {
        guard !isRequestingCamera else { return }
        isRequestingCamera = true
        Task {
            let state = await self.environment.permissions.requestCameraAccess()
            self.environment.refreshPermissions()
            self.isRequestingCamera = false
            if state == .granted {
                // Nothing left to decide on this step, so move on rather than
                // making the user find the Next button.
                self.advance()
            } else {
                self.error = .cameraPermissionDenied
            }
            await self.environment.refreshEverything()
        }
    }

    public func promptForAccessibility() {
        environment.permissions.promptForAccessibility()
    }

    public func startEnrollment() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        draft = nil
        let coordinator = environment.makeEnrollmentCoordinator()
        self.coordinator = coordinator

        updatesTask = Task { [weak self] in
            for await update in await coordinator.updates() {
                guard let self else { return }
                self.enrollmentUpdate = update
                if let preview = update.preview { self.previewImage = preview.image }
            }
        }

        workTask = Task { [weak self] in
            do {
                let result = try await coordinator.capture()
                guard let self else { return }
                self.draft = result
                self.isWorking = false
                self.advance()
            } catch is CancellationError {
                self?.isWorking = false
            } catch let failure as FaceUnlockError {
                self?.error = failure
                self?.isWorking = false
            } catch {
                self?.error = .enrollmentQualityTooLow(error.localizedDescription)
                self?.isWorking = false
            }
        }
    }

    public func startCalibration() {
        guard let draft, !isWorking else { return }
        isWorking = true
        error = nil
        calibrationScores = []
        let coordinator = self.coordinator ?? environment.makeEnrollmentCoordinator()
        self.coordinator = coordinator
        let settings = environment.preferences.recognitionSettings
        let environment = self.environment
        let sampleTarget = calibrationTarget

        // Built here, at method scope, and binding the weak reference to an
        // immutable local before the inner `Task`.
        //
        // A `[weak self]` capture is a mutable box — it can become nil — so a
        // nested closure that reads it while running concurrently is a data race,
        // which Swift 6 rejects with "reference to captured var 'self' in
        // concurrently-executing code". Reading it once, synchronously, and letting
        // the inner task capture the resulting `let` removes the race entirely.
        let onScore: @Sendable (Double, PreviewImage?) -> Void = { [weak self] score, preview in
            guard let model = self else { return }
            Task { @MainActor in
                if let preview { model.previewImage = preview.image }
                if score >= 0 { model.calibrationScores.append(score) }
            }
        }

        workTask = Task { [weak self] in
            do {
                let profile = try await coordinator.calibrate(
                    draft: draft,
                    sensitivity: settings.sensitivity,
                    livenessMode: settings.livenessMode,
                    sampleTarget: sampleTarget,
                    onScore: onScore
                )
                await environment.profileDidChange(profile)
                guard let self else { return }
                self.savedProfile = profile
                self.isWorking = false
                self.advance()
            } catch is CancellationError {
                self?.isWorking = false
            } catch let failure as FaceUnlockError {
                self?.error = failure
                self?.isWorking = false
            } catch {
                self?.error = .enrollmentQualityTooLow(error.localizedDescription)
                self?.isWorking = false
            }
        }
    }

    public func finish() {
        environment.preferences.hasCompletedOnboarding = true
        cancelWork()
        Task { await self.environment.refreshEverything() }
    }
}
