import Foundation

/// Fail-closed allowlist for the only network destination permitted to receive
/// wearable or microphone content from the private companion.
public struct VoiceCoreEndpointPolicy: Equatable, Sendable {
    public let allowedHost: String
    public let allowedPath: String

    public init(allowedHost: String, allowedPath: String) {
        self.allowedHost = allowedHost.lowercased()
        self.allowedPath = allowedPath
    }

    public func validate(_ endpoint: URL) throws {
        guard endpoint.scheme?.lowercased() == "wss" else {
            throw VoiceCoreEndpointPolicyError.insecureScheme
        }
        guard endpoint.host?.lowercased() == allowedHost else {
            throw VoiceCoreEndpointPolicyError.hostNotAllowed
        }
        guard endpoint.port == nil || endpoint.port == 443 else {
            throw VoiceCoreEndpointPolicyError.portNotAllowed
        }
        guard endpoint.path == allowedPath else {
            throw VoiceCoreEndpointPolicyError.pathNotAllowed
        }
        guard endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw VoiceCoreEndpointPolicyError.ambiguousEndpoint
        }
    }
}

public enum VoiceCoreEndpointPolicyError: Error, Equatable, Sendable {
    case insecureScheme
    case hostNotAllowed
    case portNotAllowed
    case pathNotAllowed
    case ambiguousEndpoint
}
