import SwiftUI

struct RecognitionSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SettingsPane {
            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Sensitivity").font(.headline)
                    Picker("Sensitivity", selection: sensitivityBinding) {
                        ForEach(SensitivityPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Text(environment.preferences.recognitionSettings.sensitivity.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("FaceUnlock deliberately offers presets rather than a raw threshold: an arbitrary value makes it far too easy to configure a setting that accepts the wrong person.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let summary = environment.profileSummary {
                        Divider()
                        Text(String(
                            format: "Your calibrated threshold is %.3f, measured from %d enrolled samples.",
                            summary.threshold,
                            summary.sampleCount
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text("Changing the preset takes effect on the next enrolment. Re-run setup to recalibrate against the new preset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Liveness").font(.headline)
                    Picker("Liveness", selection: livenessBinding) {
                        ForEach(LivenessMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    Text(environment.preferences.recognitionSettings.livenessMode.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Text("Timing").font(.headline)
                    LabeledContent("Give up after") {
                        Slider(
                            value: timeoutBinding,
                            in: 5...30,
                            step: 1
                        ) {
                            Text("Attempt timeout")
                        }
                        .frame(width: 220)
                    }
                    Text("\(Int(environment.preferences.recognitionSettings.attemptTimeout)) seconds. FaceUnlock stops the camera when the attempt ends and retries when you wake the Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    Button("Set up my face again…") { environment.windows.show(.onboarding) }
                    Button("Test face recognition…") { environment.windows.show(.recognitionTest) }
                    Button("Forget my face", role: .destructive) { environment.forgetFace() }
                }
            }
        }
    }

    private var sensitivityBinding: Binding<SensitivityPreset> {
        Binding(
            get: { environment.preferences.recognitionSettings.sensitivity },
            set: { environment.preferences.recognitionSettings.sensitivity = $0 }
        )
    }

    private var livenessBinding: Binding<LivenessMode> {
        Binding(
            get: { environment.preferences.recognitionSettings.livenessMode },
            set: { environment.preferences.recognitionSettings.livenessMode = $0 }
        )
    }

    private var timeoutBinding: Binding<Double> {
        Binding(
            get: { environment.preferences.recognitionSettings.attemptTimeout },
            set: { environment.preferences.recognitionSettings.attemptTimeout = $0 }
        )
    }
}
