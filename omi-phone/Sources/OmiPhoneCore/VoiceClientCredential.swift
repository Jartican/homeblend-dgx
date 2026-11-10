import Foundation

public enum VoiceClientCredentialError: Error, Equatable, Sendable {
    case invalidLength
    case invalidCharacter
}

public enum VoiceClientCredential {
    public static let minimumCharacters = 32
    public static let maximumCharacters = 256

    /// Validates an opaque bearer token without retaining it.
    public static func validate(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (minimumCharacters...maximumCharacters).contains(token.count) else {
            throw VoiceClientCredentialError.invalidLength
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard token.unicodeScalars.allSatisfy(allowed.contains) else {
            throw VoiceClientCredentialError.invalidCharacter
        }
        return token
    }
}
