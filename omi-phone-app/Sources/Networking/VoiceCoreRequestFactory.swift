import Foundation
import OmiPhoneCore

enum VoiceCoreRequestError: LocalizedError {
    case endpointNotAllowed

    var errorDescription: String? {
        "Voice Core endpoint is outside the private DGX allowlist."
    }
}

/// Produces a fresh authorized request for each WebSocket connection attempt.
/// The credential never enters transport state, logs, defaults, or source.
struct VoiceCoreRequestFactory: Sendable {
    static let defaultHost = (
        Bundle.main.object(forInfoDictionaryKey: "VoiceCoreHost") as? String
    )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ?? "voice-core.invalid"
    static let defaultEndpoint = URL(
        string: "wss://\(defaultHost)/voice/v2/voice/realtime"
    )!
    static let endpointPolicy = VoiceCoreEndpointPolicy(
        allowedHost: defaultHost,
        allowedPath: "/voice/v2/voice/realtime"
    )

    let endpoint: URL
    let credentials: any VoiceCoreCredentialProviding

    init(
        endpoint: URL = Self.defaultEndpoint,
        credentials: any VoiceCoreCredentialProviding = KeychainVoiceCoreCredentialProvider.shared
    ) {
        self.endpoint = endpoint
        self.credentials = credentials
    }

    func makeRequest() throws -> URLRequest {
        do {
            try Self.endpointPolicy.validate(endpoint)
        } catch {
            throw VoiceCoreRequestError.endpointNotAllowed
        }
        let token = try credentials.bearerToken()
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 20
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }
}
