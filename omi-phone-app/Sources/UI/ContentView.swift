import Foundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: CompanionViewModel

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                conversationSection
                modeSection
                outputSection
                privacySection
                credentialSection
            }
            .navigationTitle("HomeBlend")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            Label(model.connectionStatus, systemImage: "lock.shield")
                .foregroundStyle(.secondary)
            LabeledContent("Voice Core", value: model.endpoint.host ?? "Unavailable")
            LabeledContent("Audio source", value: model.audioSourceStatus)

            Picker("Capture device", selection: $model.captureSourceChoice) {
                ForEach(CompanionViewModel.CaptureSourceChoice.allCases) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .disabled(model.sessionState == .capturing)

            HStack {
                Button(model.isTransportRunning ? "Disconnect" : "Connect") {
                    if model.isTransportRunning {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }

                Spacer()

                Button("Speak") {
                    model.beginCapture()
                }
                .disabled(!model.canBeginCapture)

                Button("Submit") {
                    model.commitCapture()
                }
                .disabled(!model.canCommitCapture)
            }
        }
    }

    private var conversationSection: some View {
        Section("Conversation") {
            VStack(alignment: .leading, spacing: 6) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.liveTranscript)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("HomeBlend")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.lastResponse)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }
    }

    private var modeSection: some View {
        Section("Mode") {
            Picker("Active mode", selection: $model.mode) {
                ForEach(CompanionViewModel.DisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Text("Planned voice control: “Hey Gauss, activate translation.”")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var outputSection: some View {
        Section(
            header: Text("Response output"),
            footer: Text("Headphone mode never falls back to the phone speaker. Text remains visible in every mode.")
        ) {
            Picker("Output", selection: $model.outputChoice) {
                ForEach(CompanionViewModel.OutputChoice.allCases) { choice in
                    Text(choice.rawValue).tag(choice)
                }
            }

            if model.outputChoice == .phoneSpeaker {
                Toggle("Explicitly enable phone speaker", isOn: $model.phoneSpeakerEnabled)
                    .tint(.orange)
            }
        }
    }

    private var privacySection: some View {
        Section(
            header: Text("Privacy"),
            footer: Text("Location is sent only with requests that need it. This shell does not record audio or persist transcripts.")
        ) {
            Toggle("Share phone location when needed", isOn: $model.sharePhoneLocation)
        }
    }

    private var credentialSection: some View {
        Section(
            header: Text("Voice Core credential"),
            footer: Text("Stored only in this phone’s Keychain. It is not synchronized or written to app logs. Removing it here does not revoke it on the DGX; revoke there first for a lost or replaced phone.")
        ) {
            SecureField("Bearer token", text: $model.credentialDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Text(model.credentialStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save securely") {
                    model.saveCredential()
                }
                .disabled(model.credentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Remove from phone", role: .destructive) {
                    model.removeCredential()
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(CompanionViewModel())
}
