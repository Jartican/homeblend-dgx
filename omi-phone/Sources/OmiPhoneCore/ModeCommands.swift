import Foundation

public enum ModeCommand: Equatable, Sendable {
    case activateAssistant
    case activateTranslation(sourceLanguage: String?, targetLanguage: String?)
    case activateRemember
    case activateTranscriptOnly
    case activatePrivateMode
    case startListening
    case stopListening
}

public protocol ModeCommandParsing: Sendable {
    /// Returns a command only when the entire utterance is a supported command.
    func parse(_ utterance: String) -> ModeCommand?
}

/// A deterministic wake-phrase parser. It intentionally does not ask a model
/// whether arbitrary text is a control command.
public struct GaussModeCommandParser: ModeCommandParsing {
    public init() {}

    public func parse(_ utterance: String) -> ModeCommand? {
        let command = normalizedCommand(utterance)

        switch command {
        case "activate assistant", "activate assistant mode":
            return .activateAssistant
        case "activate translation", "activate translation mode":
            return .activateTranslation(sourceLanguage: nil, targetLanguage: nil)
        case "activate remember", "activate remember mode":
            return .activateRemember
        case "activate transcript only", "activate transcript-only",
             "activate transcript only mode", "activate transcript-only mode":
            return .activateTranscriptOnly
        case "activate private mode":
            return .activatePrivateMode
        case "start listening":
            return .startListening
        case "stop listening":
            return .stopListening
        default:
            return parseTranslationPair(command)
        }
    }

    private func normalizedCommand(_ utterance: String) -> String {
        let folded = utterance
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutTrailingPunctuation = folded.replacingOccurrences(
            of: #"[.!?]+$"#,
            with: "",
            options: .regularExpression
        )
        let collapsedWhitespace = withoutTrailingPunctuation.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        for prefix in ["hey gauss, ", "hey gauss "] {
            if collapsedWhitespace.hasPrefix(prefix) {
                return String(collapsedWhitespace.dropFirst(prefix.count))
            }
        }
        return ""
    }

    private func parseTranslationPair(_ command: String) -> ModeCommand? {
        let prefix = "translate "
        guard command.hasPrefix(prefix) else { return nil }

        let pair = String(command.dropFirst(prefix.count))
        guard let separator = pair.range(of: " to ") else { return nil }

        let source = pair[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
        let target = pair[separator.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, !target.isEmpty, !target.contains(" to ") else { return nil }

        return .activateTranslation(
            sourceLanguage: source,
            targetLanguage: target
        )
    }
}
