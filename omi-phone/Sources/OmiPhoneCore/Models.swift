import Foundation

public enum CompanionMode: Equatable, Sendable {
    case assistant
    case translation(sourceLanguage: String?, targetLanguage: String?)
    case remember
    case transcriptOnly
    case privateSession
}

public enum CaptureState: Equatable, Sendable {
    case stopped
    case listening
    case processing
}

public enum AudioOutputPreference: Equatable, Sendable {
    /// Render text only. This is the safe default.
    case textOnly
    /// Speak only while headphones are connected; never fall back to speakers.
    case headphonesWhenAvailable
    /// Allow the app to use the phone speaker. The app must also be explicitly enabled.
    case phoneSpeaker
}

public struct OutputEnvironment: Equatable, Sendable {
    public var headphonesConnected: Bool
    public var phoneSpeakerEnabledInApp: Bool

    public init(
        headphonesConnected: Bool = false,
        phoneSpeakerEnabledInApp: Bool = false
    ) {
        self.headphonesConnected = headphonesConnected
        self.phoneSpeakerEnabledInApp = phoneSpeakerEnabledInApp
    }
}

public enum SpeechDestination: Equatable, Sendable {
    case headphones
    case phoneSpeaker
}

public struct OutputPlan: Equatable, Sendable {
    /// Text is always rendered, including when speech is enabled.
    public let renderText: Bool
    public let speechDestination: SpeechDestination?

    public init(renderText: Bool = true, speechDestination: SpeechDestination? = nil) {
        self.renderText = renderText
        self.speechDestination = speechDestination
    }
}

public struct CompanionState: Equatable, Sendable {
    public var mode: CompanionMode
    public var captureState: CaptureState
    public var liveTranscript: String
    public var lastResponse: String?
    public var outputPreference: AudioOutputPreference
    public var outputEnvironment: OutputEnvironment
    public var lastError: String?

    public init(
        mode: CompanionMode = .assistant,
        captureState: CaptureState = .stopped,
        liveTranscript: String = "",
        lastResponse: String? = nil,
        outputPreference: AudioOutputPreference = .textOnly,
        outputEnvironment: OutputEnvironment = .init(),
        lastError: String? = nil
    ) {
        self.mode = mode
        self.captureState = captureState
        self.liveTranscript = liveTranscript
        self.lastResponse = lastResponse
        self.outputPreference = outputPreference
        self.outputEnvironment = outputEnvironment
        self.lastError = lastError
    }
}
