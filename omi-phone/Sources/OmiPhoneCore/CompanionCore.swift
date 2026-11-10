public enum CompanionEvent: Equatable, Sendable {
    case captureStarted
    case partialTranscript(String)
    case finalTranscript(String)
    case agentResponse(text: String, speechAvailable: Bool)
    case headphonesChanged(connected: Bool)
    case outputPreferenceChanged(AudioOutputPreference)
    case phoneSpeakerPermissionChanged(enabledInApp: Bool)
    case modeCommand(ModeCommand)
    case failed(message: String)
    case reset
}

public enum CompanionEffect: Equatable, Sendable {
    case startCapture
    case stopCapture
    case submitUtterance(text: String, mode: CompanionMode)
    case modeChanged(CompanionMode)
    case renderText(String)
    case playSpeech(text: String, destination: SpeechDestination)
}

public protocol CompanionEventHandling {
    var state: CompanionState { get }
    mutating func handle(_ event: CompanionEvent) -> [CompanionEffect]
}

/// Pure state machine. Bluetooth, Omi, AVAudioSession, transport, storage, and
/// SwiftUI adapters can be added around it without entering the core package.
public struct CompanionCore<Parser: ModeCommandParsing, Router: OutputRouting>: CompanionEventHandling {
    public private(set) var state: CompanionState
    private let parser: Parser
    private let outputRouter: Router

    public init(
        state: CompanionState = .init(),
        parser: Parser,
        outputRouter: Router
    ) {
        self.state = state
        self.parser = parser
        self.outputRouter = outputRouter
    }

    public mutating func handle(_ event: CompanionEvent) -> [CompanionEffect] {
        switch event {
        case .captureStarted:
            state.captureState = .listening
            state.liveTranscript = ""
            state.lastError = nil
            return []

        case let .partialTranscript(text):
            state.liveTranscript = text
            return []

        case let .finalTranscript(text):
            state.liveTranscript = text
            if let command = parser.parse(text) {
                return apply(command)
            }
            state.captureState = .processing
            return [.submitUtterance(text: text, mode: state.mode)]

        case let .agentResponse(text, speechAvailable):
            state.captureState = .stopped
            state.lastResponse = text
            let plan = outputRouter.plan(
                preference: state.outputPreference,
                environment: state.outputEnvironment,
                speechAvailable: speechAvailable
            )
            var effects: [CompanionEffect] = []
            if plan.renderText { effects.append(.renderText(text)) }
            if let destination = plan.speechDestination {
                effects.append(.playSpeech(text: text, destination: destination))
            }
            return effects

        case let .headphonesChanged(connected):
            state.outputEnvironment.headphonesConnected = connected
            return []

        case let .outputPreferenceChanged(preference):
            state.outputPreference = preference
            return []

        case let .phoneSpeakerPermissionChanged(enabledInApp):
            state.outputEnvironment.phoneSpeakerEnabledInApp = enabledInApp
            return []

        case let .modeCommand(command):
            return apply(command)

        case let .failed(message):
            state.captureState = .stopped
            state.lastError = message
            return []

        case .reset:
            let preference = state.outputPreference
            let environment = state.outputEnvironment
            state = CompanionState(
                outputPreference: preference,
                outputEnvironment: environment
            )
            return []
        }
    }

    private mutating func apply(_ command: ModeCommand) -> [CompanionEffect] {
        switch command {
        case .activateAssistant:
            state.mode = .assistant
            state.captureState = .stopped
            return [.modeChanged(.assistant)]

        case let .activateTranslation(sourceLanguage, targetLanguage):
            let mode = CompanionMode.translation(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            state.mode = mode
            state.captureState = .stopped
            return [.modeChanged(mode)]

        case .activateRemember:
            state.mode = .remember
            state.captureState = .stopped
            return [.modeChanged(.remember)]

        case .activateTranscriptOnly:
            state.mode = .transcriptOnly
            state.captureState = .stopped
            return [.modeChanged(.transcriptOnly)]

        case .activatePrivateMode:
            state.mode = .privateSession
            state.captureState = .stopped
            return [.modeChanged(.privateSession)]

        case .startListening:
            state.captureState = .listening
            state.liveTranscript = ""
            return [.startCapture]

        case .stopListening:
            state.captureState = .stopped
            return [.stopCapture]
        }
    }
}

public extension CompanionCore where Parser == GaussModeCommandParser, Router == DefaultOutputRouter {
    init(state: CompanionState = .init()) {
        self.init(
            state: state,
            parser: GaussModeCommandParser(),
            outputRouter: DefaultOutputRouter()
        )
    }
}
