import Combine
import Foundation
import OmiPhoneCore

@MainActor
final class CompanionViewModel: ObservableObject {
    enum DisplayMode: String, CaseIterable, Identifiable {
        case assistant = "Assistant"
        case translation = "Translation"
        case remember = "Remember"
        case transcriptOnly = "Transcript only"
        case privateSession = "Private"

        var id: Self { self }
    }

    enum OutputChoice: String, CaseIterable, Identifiable {
        case textOnly = "Text only"
        case headphones = "Headphones when connected"
        case phoneSpeaker = "Phone speaker"

        var id: Self { self }
    }

    enum CaptureSourceChoice: String, CaseIterable, Identifiable {
        case phone = "Phone microphone"
        case omi = "Omi pendant"

        var id: Self { self }
    }

    @Published var mode: DisplayMode = .assistant
    @Published var outputChoice: OutputChoice = .textOnly
    @Published var captureSourceChoice: CaptureSourceChoice = .phone
    @Published var phoneSpeakerEnabled = false
    @Published var sharePhoneLocation = false
    @Published var credentialDraft = ""
    @Published private(set) var credentialStatus = "Not configured"
    @Published private(set) var connectionStatus = "Offline — transport not connected"
    @Published private(set) var liveTranscript = "Your live transcription will appear here."
    @Published private(set) var lastResponse = "HomeBlend responses will appear here."
    @Published private(set) var sessionState: VoiceCoreSessionState?
    @Published private(set) var isTransportRunning = false
    @Published private(set) var audioSourceStatus = "Not connected"

    let endpoint = VoiceCoreRequestFactory.defaultEndpoint
    private let credentialProvider = KeychainVoiceCoreCredentialProvider.shared
    private var sessionViewState = VoiceCoreSessionViewState()
    private var transport: VoiceCoreTransport?
    private var eventTask: Task<Void, Never>?
    private var activeAudioSource: (any AudioSource)?
    private var activeAudioSourceID: UUID?
    private var audioTask: Task<Void, Never>?

    init() {
        credentialStatus = ((try? credentialProvider.bearerToken()) == nil)
            ? "Not configured"
            : "Saved securely on this device"
    }

    func saveCredential() {
        do {
            try credentialProvider.save(credentialDraft)
            credentialDraft = ""
            credentialStatus = "Saved securely on this device"
        } catch {
            credentialDraft = ""
            credentialStatus = error.localizedDescription
        }
    }

    func removeCredential() {
        do {
            try credentialProvider.delete()
            credentialDraft = ""
            credentialStatus = "Not configured"
        } catch {
            credentialStatus = error.localizedDescription
        }
    }

    func outputPreference() -> AudioOutputPreference {
        switch outputChoice {
        case .textOnly: return .textOnly
        case .headphones: return .headphonesWhenAvailable
        case .phoneSpeaker: return .phoneSpeaker
        }
    }

    var canBeginCapture: Bool {
        isTransportRunning && sessionState == .armed
    }

    var canCommitCapture: Bool {
        isTransportRunning && sessionState == .capturing
    }

    func connect() {
        guard transport == nil else { return }

        let requestFactory = VoiceCoreRequestFactory(credentials: credentialProvider)
        let voiceMode: VoiceCoreVoiceMode = switch mode {
        case .translation: .translation
        case .privateSession: .privateSession
        case .assistant, .remember, .transcriptOnly: .assistant
        }
        let configuration = VoiceCoreTransportConfiguration(
            sessionStart: VoiceCoreSessionStart(
                model: .automatic,
                effort: 1,
                toolProfile: .web,
                location: nil,
                mode: voiceMode,
                targetLanguage: voiceMode == .translation ? "English" : nil
            )
        )
        let transport = VoiceCoreTransport(
            configuration: configuration,
            requestProvider: { try requestFactory.makeRequest() }
        )
        self.transport = transport
        isTransportRunning = true
        connectionStatus = "Connecting securely…"

        eventTask = Task { [weak self, transport] in
            for await event in transport.events {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
        }

        Task { [weak self, transport] in
            await transport.start()
            guard !Task.isCancelled else { return }
            if await transport.state() == .stopped {
                self?.isTransportRunning = false
            }
        }
    }

    func disconnect() {
        guard let transport else { return }
        self.transport = nil
        isTransportRunning = false
        eventTask?.cancel()
        eventTask = nil
        sessionState = nil
        connectionStatus = "Disconnecting…"
        stopAudioSource()

        Task { [weak self] in
            await transport.stop()
            self?.connectionStatus = "Offline"
        }
    }

    func beginCapture() {
        guard let transport, canBeginCapture else { return }
        Task { [weak self] in
            do {
                try await transport.sendControl(.turnStart(turnID: UUID().uuidString))
            } catch {
                self?.report(error)
            }
        }
    }

    func commitCapture() {
        guard let transport, canCommitCapture else { return }
        Task { [weak self] in
            do {
                await self?.stopAudioSourceAndWait()
                try await transport.sendControl(.turnCommit)
            } catch {
                self?.report(error)
            }
        }
    }

    func stopSession() {
        disconnect()
    }

    private func receive(_ event: VoiceCoreTransportEvent) {
        let outputs = VoiceCoreSessionReducer.reduce(
            state: &sessionViewState,
            event: event
        )

        sessionState = sessionViewState.sessionState
        if !sessionViewState.partialTranscript.isEmpty {
            liveTranscript = sessionViewState.partialTranscript
        } else if let finalTranscript = sessionViewState.finalTranscript {
            liveTranscript = finalTranscript
        }
        if !sessionViewState.responseText.isEmpty {
            lastResponse = sessionViewState.responseText
        }

        for output in outputs {
            apply(output)
        }
    }

    private func apply(_ output: VoiceCoreSessionOutput) {
        switch output {
        case let .transportStateChanged(state):
            connectionStatus = description(for: state)
            if state == .disconnected {
                // Reconnect attempts are exhausted. Release the terminal
                // transport so the Connect button can create a fresh session.
                isTransportRunning = false
                transport = nil
                eventTask = nil
            } else if state == .stopped {
                isTransportRunning = false
            }

        case let .sessionStateChanged(state):
            sessionState = state
            connectionStatus = "Connected — \(state.rawValue.replacingOccurrences(of: "_", with: " "))"
            if state == .capturing {
                startAudioSourceIfNeeded()
            } else {
                stopAudioSource()
            }

        case let .voiceModeChanged(mode, _, _):
            switch mode {
            case .assistant: self.mode = .assistant
            case .translation: self.mode = .translation
            case .privateSession: self.mode = .privateSession
            }

        case let .transcriptChanged(text, _):
            liveTranscript = text

        case let .responseTextChanged(text, _):
            lastResponse = text

        case let .companionEffect(effect):
            apply(effect)

        case let .error(message):
            connectionStatus = "Error — \(message)"
        }
    }

    private func apply(_ effect: CompanionEffect) {
        switch effect {
        case let .modeChanged(mode):
            self.mode = displayMode(for: mode)
        case let .renderText(text):
            lastResponse = text
        case .startCapture:
            beginCapture()
        case .stopCapture:
            commitCapture()
        case .submitUtterance, .playSpeech:
            // Voice Core owns agent submission and playback. Dedicated audio
            // routing is added by the AVFoundation adapter, never by SwiftUI.
            break
        }
    }

    private func report(_ error: Error) {
        connectionStatus = "Error — \(error.localizedDescription)"
    }

    private func startAudioSourceIfNeeded() {
        guard audioTask == nil, let transport else { return }

        let source: any AudioSource
        do {
            source = try makeAudioSource()
        } catch {
            report(error)
            audioSourceStatus = "Audio source error"
            return
        }
        let sourceID = UUID()
        activeAudioSource = source
        activeAudioSourceID = sourceID
        audioSourceStatus = captureSourceChoice == .phone
            ? "Requesting microphone…"
            : "Scanning for Omi…"
        audioTask = Task { [weak self, source, transport] in
            do {
                let chunks = try await source.audioChunks()
                self?.audioSourceStatus = self?.captureSourceChoice == .phone
                    ? "Phone microphone — private live stream"
                    : "Omi pendant — private live stream"
                for try await chunk in chunks {
                    try Task.checkCancellation()
                    try await transport.sendInputPCM(chunk)
                }
            } catch is CancellationError {
                // Expected when the user commits or disconnects.
            } catch {
                self?.report(error)
                self?.audioSourceStatus = "Audio source error"
            }
            await source.stop()
            if self?.activeAudioSourceID == sourceID {
                self?.activeAudioSource = nil
                self?.activeAudioSourceID = nil
                self?.audioTask = nil
                if self?.audioSourceStatus != "Audio source error" {
                    self?.audioSourceStatus = "Not connected"
                }
            }
        }
    }

    private func stopAudioSource() {
        audioTask?.cancel()
        audioTask = nil
        activeAudioSourceID = nil
        guard let source = activeAudioSource else {
            audioSourceStatus = "Not connected"
            return
        }
        activeAudioSource = nil
        audioSourceStatus = "Not connected"
        Task { await source.stop() }
    }

    private func stopAudioSourceAndWait() async {
        audioTask?.cancel()
        audioTask = nil
        activeAudioSourceID = nil
        let source = activeAudioSource
        activeAudioSource = nil
        audioSourceStatus = "Not connected"
        await source?.stop()
    }

    private func makeAudioSource() throws -> any AudioSource {
        switch captureSourceChoice {
        case .phone:
            return PhoneMicrophoneAudioSource()
        case .omi:
            let opus = try SwiftOpusDecoder()
            return OmiBLEAudioSource(
                normalizer: OmiAudioFrameNormalizer(opusDecoder: opus)
            )
        }
    }

    private func description(for state: VoiceCoreTransportState) -> String {
        switch state {
        case .stopped: return "Offline"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting securely…"
        case .awaitingReady: return "Connected — authenticating session…"
        case .active: return "Connected — awaiting Voice Core state"
        case let .reconnecting(attempt, _): return "Reconnecting (attempt \(attempt))…"
        }
    }

    private func displayMode(for mode: CompanionMode) -> DisplayMode {
        switch mode {
        case .assistant: return .assistant
        case .translation: return .translation
        case .remember: return .remember
        case .transcriptOnly: return .transcriptOnly
        case .privateSession: return .privateSession
        }
    }
}
