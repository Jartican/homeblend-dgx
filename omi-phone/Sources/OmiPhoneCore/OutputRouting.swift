public protocol OutputRouting: Sendable {
    func plan(
        preference: AudioOutputPreference,
        environment: OutputEnvironment,
        speechAvailable: Bool
    ) -> OutputPlan
}

/// Centralizes privacy-preserving audio behavior so UI and hardware adapters
/// cannot accidentally invent their own speaker fallback.
public struct DefaultOutputRouter: OutputRouting {
    public init() {}

    public func plan(
        preference: AudioOutputPreference,
        environment: OutputEnvironment,
        speechAvailable: Bool
    ) -> OutputPlan {
        guard speechAvailable else { return OutputPlan() }

        switch preference {
        case .textOnly:
            return OutputPlan()

        case .headphonesWhenAvailable:
            guard environment.headphonesConnected else {
                // Deliberately remain text-only; there is no speaker fallback.
                return OutputPlan()
            }
            return OutputPlan(speechDestination: .headphones)

        case .phoneSpeaker:
            guard environment.phoneSpeakerEnabledInApp else {
                return OutputPlan()
            }
            return OutputPlan(speechDestination: .phoneSpeaker)
        }
    }
}
