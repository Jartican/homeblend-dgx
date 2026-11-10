import Foundation

/// UI-facing state derived from Voice Core events. This type deliberately has
/// no references to WebSockets, SwiftUI, AVFoundation, or a particular wearable.
public struct VoiceCoreSessionViewState: Equatable, Sendable {
    public var transportState: VoiceCoreTransportState
    public var sessionState: VoiceCoreSessionState?
    public var voiceMode: VoiceCoreVoiceMode
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var partialTranscript: String
    public var finalTranscript: String?
    public var responseText: String
    public var finalResponseText: String?
    public var lastError: String?
    public var companion: CompanionState

    public init(
        transportState: VoiceCoreTransportState = .stopped,
        sessionState: VoiceCoreSessionState? = nil,
        voiceMode: VoiceCoreVoiceMode = .assistant,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil,
        partialTranscript: String = "",
        finalTranscript: String? = nil,
        responseText: String = "",
        finalResponseText: String? = nil,
        lastError: String? = nil,
        companion: CompanionState = .init()
    ) {
        self.transportState = transportState
        self.sessionState = sessionState
        self.voiceMode = voiceMode
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.partialTranscript = partialTranscript
        self.finalTranscript = finalTranscript
        self.responseText = responseText
        self.finalResponseText = finalResponseText
        self.lastError = lastError
        self.companion = companion
    }
}

/// Device-neutral outputs for thin transport and presentation adapters.
public enum VoiceCoreSessionOutput: Equatable, Sendable {
    case transportStateChanged(VoiceCoreTransportState)
    case sessionStateChanged(VoiceCoreSessionState)
    case voiceModeChanged(mode: VoiceCoreVoiceMode, sourceLanguage: String?, targetLanguage: String?)
    case transcriptChanged(text: String, isFinal: Bool)
    case responseTextChanged(text: String, isFinal: Bool)
    case companionEffect(CompanionEffect)
    case error(String)
}

/// Pure reducer joining Voice Core wire events to the companion domain.
///
/// The caller owns the state and executes returned outputs. In particular, the
/// reducer never sends a request itself. A final wake command is interpreted by
/// `CompanionCore`; only an ordinary utterance can produce `submitUtterance`.
public enum VoiceCoreSessionReducer {
    public static func reduce(
        state: inout VoiceCoreSessionViewState,
        event: VoiceCoreTransportEvent
    ) -> [VoiceCoreSessionOutput] {
        switch event {
        case let .stateChanged(transportState):
            state.transportState = transportState
            if transportState == .connecting || transportState == .active {
                state.lastError = nil
            }
            return [.transportStateChanged(transportState)]

        case let .control(control):
            return reduce(state: &state, control: control)

        case .audio:
            // PCM belongs to an audio adapter and is intentionally not retained.
            return []

        case let .disconnected(willReconnect):
            let message = willReconnect
                ? "Voice connection interrupted; reconnecting."
                : "Voice connection closed."
            state.lastError = message
            return [.error(message)]

        case let .failed(message):
            return fail(state: &state, message: message)
        }
    }

    /// Reduces an already-decoded control message. This overload lets tests and
    /// non-WebSocket adapters share the exact same session behavior.
    public static func reduce(
        state: inout VoiceCoreSessionViewState,
        control: VoiceCoreControl
    ) -> [VoiceCoreSessionOutput] {
        switch control {
        case let .sessionState(sessionState):
            state.sessionState = sessionState
            return [.sessionStateChanged(sessionState)]

        case let .modeChanged(mode, sourceLanguage, targetLanguage):
            state.voiceMode = mode
            state.sourceLanguage = sourceLanguage
            state.targetLanguage = targetLanguage
            return [.voiceModeChanged(
                mode: mode,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )]

        case .turnStart, .wakeDetected, .speechStarted:
            beginTurn(state: &state)
            return companionOutputs(state: &state, event: .captureStarted)

        case let .transcriptDelta(text, final):
            if final {
                state.partialTranscript = ""
                state.finalTranscript = text
                var outputs: [VoiceCoreSessionOutput] = [
                    .transcriptChanged(text: text, isFinal: true),
                ]
                outputs.append(contentsOf: companionOutputs(
                    state: &state,
                    event: .finalTranscript(text)
                ))
                return outputs
            }

            state.partialTranscript = text
            return [
                .transcriptChanged(text: text, isFinal: false),
            ] + companionOutputs(state: &state, event: .partialTranscript(text))

        case let .responseTextDelta(delta, _):
            state.responseText += delta
            return [.responseTextChanged(text: state.responseText, isFinal: false)]

        case let .responseTextDone(text, _):
            let finalText = text.isEmpty ? state.responseText : text
            state.responseText = finalText
            state.finalResponseText = finalText
            var outputs: [VoiceCoreSessionOutput] = [
                .responseTextChanged(text: finalText, isFinal: true),
            ]
            outputs.append(contentsOf: companionOutputs(
                state: &state,
                event: .agentResponse(text: finalText, speechAvailable: false)
            ))
            return outputs

        case let .gatewayError(detail, code):
            let message = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = (message?.isEmpty == false ? message : nil)
                ?? code
                ?? "Voice Core reported an error."
            return fail(state: &state, message: normalized)

        case .sessionClose:
            state.sessionState = .closed
            return [.sessionStateChanged(.closed)]

        case .sessionReady, .sessionStart, .textTurn, .turnCommit, .bargeIn,
             .playbackFinished, .followupTimeout, .responseAudioStarted,
             .responseAudioDone:
            return []
        }
    }

    private static func beginTurn(state: inout VoiceCoreSessionViewState) {
        state.partialTranscript = ""
        state.finalTranscript = nil
        state.responseText = ""
        state.finalResponseText = nil
        state.lastError = nil
    }

    private static func fail(
        state: inout VoiceCoreSessionViewState,
        message: String
    ) -> [VoiceCoreSessionOutput] {
        state.lastError = message
        var outputs: [VoiceCoreSessionOutput] = [.error(message)]
        outputs.append(contentsOf: companionOutputs(
            state: &state,
            event: .failed(message: message)
        ))
        return outputs
    }

    private static func companionOutputs(
        state: inout VoiceCoreSessionViewState,
        event: CompanionEvent
    ) -> [VoiceCoreSessionOutput] {
        var core = CompanionCore(state: state.companion)
        let effects = core.handle(event)
        state.companion = core.state
        return effects.map(VoiceCoreSessionOutput.companionEffect)
    }
}
