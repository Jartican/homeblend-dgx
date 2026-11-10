import Foundation

public enum VoiceCoreWireError: Error, Equatable, Sendable {
    case malformedControl
    case unsupportedProtocolVersion(Int)
    case unsupportedControlType(String)
    case invalidAudioMagic
    case unsupportedAudioKind(UInt8)
    case unsupportedAudioFlags(UInt16)
    case invalidAudioPayloadLength
}

public enum VoiceCoreAgentModel: String, Codable, Equatable, Sendable {
    case automatic = "auto"
    case eightB = "8b"
    case twentySevenB = "27b"
}

public enum VoiceCoreToolProfile: String, Codable, Equatable, Sendable {
    case none
    case web
}

public enum VoiceCoreVoiceMode: String, Codable, Equatable, Sendable {
    case assistant
    case translation
    case privateSession = "private"
}

public enum VoiceCoreSessionState: String, Codable, Equatable, Sendable {
    case new
    case armed
    case capturing
    case thinking
    case speaking
    case followUp = "follow_up"
    case closed
}

public struct VoiceCoreLocation: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct VoiceCoreSessionStart: Equatable, Sendable {
    public let device: String
    public let model: VoiceCoreAgentModel
    public let effort: Int
    public let toolProfile: VoiceCoreToolProfile
    public let voice: String
    public let location: VoiceCoreLocation?
    public let mode: VoiceCoreVoiceMode
    public let sourceLanguage: String?
    public let targetLanguage: String?

    public init(
        device: String = "phone",
        model: VoiceCoreAgentModel = .automatic,
        effort: Int = 1,
        toolProfile: VoiceCoreToolProfile = .web,
        voice: String = "af_heart",
        location: VoiceCoreLocation? = nil,
        mode: VoiceCoreVoiceMode = .assistant,
        sourceLanguage: String? = nil,
        targetLanguage: String? = nil
    ) {
        self.device = device
        self.model = model
        self.effort = effort
        self.toolProfile = toolProfile
        self.voice = voice
        self.location = location
        self.mode = mode
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

/// All JSON controls currently documented by Voice Core v2. Unknown message
/// types are rejected instead of being silently ignored.
public enum VoiceCoreControl: Equatable, Sendable {
    case sessionReady
    case sessionStart(VoiceCoreSessionStart)
    case sessionState(VoiceCoreSessionState)
    case modeChanged(mode: VoiceCoreVoiceMode, sourceLanguage: String?, targetLanguage: String?)
    case textTurn(turnID: String, text: String)
    case turnStart(turnID: String)
    case turnCommit
    case wakeDetected(turnID: String)
    case speechStarted(turnID: String)
    case bargeIn
    case playbackFinished
    case followupTimeout
    case sessionClose
    case transcriptDelta(text: String, final: Bool)
    case responseTextDelta(delta: String, model: String?)
    case responseTextDone(text: String, model: String?)
    case responseAudioStarted(sampleRateHz: Int, channels: Int)
    case responseAudioDone(durationMs: Int?)
    case gatewayError(detail: String?, code: String?)
}

public enum VoiceCoreControlCodec {
    public static let protocolVersion = 1

    public static func encode(_ message: VoiceCoreControl) throws -> Data {
        let encoder = JSONEncoder()
        switch message {
        case .sessionReady:
            return try encoder.encode(Envelope(type: "session.ready"))
        case let .sessionStart(value):
            return try encoder.encode(SessionStartMessage(value))
        case let .sessionState(state):
            return try encoder.encode(StateMessage(state: state))
        case let .modeChanged(mode, sourceLanguage, targetLanguage):
            return try encoder.encode(ModeChangedMessage(
                mode: mode,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            ))
        case let .textTurn(turnID, text):
            return try encoder.encode(TextTurnMessage(turnID: turnID, text: text))
        case let .turnStart(turnID):
            return try encoder.encode(TurnMessage(type: "turn.start", turnID: turnID))
        case .turnCommit:
            return try encoder.encode(Envelope(type: "turn.commit"))
        case let .wakeDetected(turnID):
            return try encoder.encode(TurnMessage(type: "wake.detected", turnID: turnID))
        case let .speechStarted(turnID):
            return try encoder.encode(TurnMessage(type: "speech.started", turnID: turnID))
        case .bargeIn:
            return try encoder.encode(Envelope(type: "barge_in"))
        case .playbackFinished:
            return try encoder.encode(Envelope(type: "playback.finished"))
        case .followupTimeout:
            return try encoder.encode(Envelope(type: "followup.timeout"))
        case .sessionClose:
            return try encoder.encode(Envelope(type: "session.close"))
        case let .transcriptDelta(text, final):
            return try encoder.encode(TranscriptMessage(text: text, final: final))
        case let .responseTextDelta(delta, model):
            return try encoder.encode(TextDeltaMessage(delta: delta, model: model))
        case let .responseTextDone(text, model):
            return try encoder.encode(TextDoneMessage(text: text, model: model))
        case let .responseAudioStarted(sampleRateHz, channels):
            return try encoder.encode(AudioStartedMessage(sampleRateHz: sampleRateHz, channels: channels))
        case let .responseAudioDone(durationMs):
            return try encoder.encode(AudioDoneMessage(durationMs: durationMs))
        case let .gatewayError(detail, code):
            return try encoder.encode(ErrorMessage(detail: detail, code: code))
        }
    }

    public static func decode(_ data: Data) throws -> VoiceCoreControl {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw VoiceCoreWireError.malformedControl
        }
        guard envelope.protocolVersion == protocolVersion else {
            throw VoiceCoreWireError.unsupportedProtocolVersion(envelope.protocolVersion)
        }

        do {
            switch envelope.type {
            case "session.ready": return .sessionReady
            case "session.start":
                let value = try decoder.decode(SessionStartMessage.self, from: data)
                return .sessionStart(value.value)
            case "session.state":
                return .sessionState(try decoder.decode(StateMessage.self, from: data).state)
            case "mode.changed":
                let value = try decoder.decode(ModeChangedMessage.self, from: data)
                return .modeChanged(
                    mode: value.mode,
                    sourceLanguage: value.sourceLanguage,
                    targetLanguage: value.targetLanguage
                )
            case "text.turn":
                let value = try decoder.decode(TextTurnMessage.self, from: data)
                return .textTurn(turnID: value.turnID, text: value.text)
            case "turn.start":
                return .turnStart(turnID: try decoder.decode(TurnMessage.self, from: data).turnID)
            case "turn.commit": return .turnCommit
            case "wake.detected":
                return .wakeDetected(turnID: try decoder.decode(TurnMessage.self, from: data).turnID)
            case "speech.started":
                return .speechStarted(turnID: try decoder.decode(TurnMessage.self, from: data).turnID)
            case "barge_in": return .bargeIn
            case "playback.finished": return .playbackFinished
            case "followup.timeout": return .followupTimeout
            case "session.close": return .sessionClose
            case "transcript.delta":
                let value = try decoder.decode(TranscriptMessage.self, from: data)
                return .transcriptDelta(text: value.text, final: value.final)
            case "response.text.delta":
                let value = try decoder.decode(TextDeltaMessage.self, from: data)
                return .responseTextDelta(delta: value.delta, model: value.model)
            case "response.text.done":
                let value = try decoder.decode(TextDoneMessage.self, from: data)
                return .responseTextDone(text: value.text, model: value.model)
            case "response.audio.started":
                let value = try decoder.decode(AudioStartedMessage.self, from: data)
                return .responseAudioStarted(sampleRateHz: value.sampleRateHz, channels: value.channels)
            case "response.audio.done":
                return .responseAudioDone(durationMs: try decoder.decode(AudioDoneMessage.self, from: data).durationMs)
            case "error":
                let value = try decoder.decode(ErrorMessage.self, from: data)
                return .gatewayError(detail: value.detail, code: value.code)
            default:
                throw VoiceCoreWireError.unsupportedControlType(envelope.type)
            }
        } catch let error as VoiceCoreWireError {
            throw error
        } catch {
            throw VoiceCoreWireError.malformedControl
        }
    }
}

public enum VoiceCoreAudioKind: UInt8, Equatable, Sendable {
    case inputPCM = 1
    case responsePCM = 2
}

public struct VoiceCoreAudioFrame: Equatable, Sendable {
    public static let maximumPayloadSize = 65_536

    public let kind: VoiceCoreAudioKind
    public let sequence: UInt32
    public let timestampMs: UInt64
    public let payload: Data

    public init(kind: VoiceCoreAudioKind, sequence: UInt32, timestampMs: UInt64, payload: Data) {
        self.kind = kind
        self.sequence = sequence
        self.timestampMs = timestampMs
        self.payload = payload
    }
}

public enum VoiceCoreAudioCodec {
    private static let headerSize = 24
    private static let magic: [UInt8] = [0x45, 0x58, 0x56, 0x32]

    public static func encode(_ frame: VoiceCoreAudioFrame) throws -> Data {
        guard (1...VoiceCoreAudioFrame.maximumPayloadSize).contains(frame.payload.count) else {
            throw VoiceCoreWireError.invalidAudioPayloadLength
        }
        var bytes = magic
        bytes.append(UInt8(VoiceCoreControlCodec.protocolVersion))
        bytes.append(frame.kind.rawValue)
        append(UInt16(0), to: &bytes)
        append(frame.sequence, to: &bytes)
        append(frame.timestampMs, to: &bytes)
        append(UInt32(frame.payload.count), to: &bytes)
        bytes.append(contentsOf: frame.payload)
        return Data(bytes)
    }

    public static func decode(_ data: Data) throws -> VoiceCoreAudioFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { throw VoiceCoreWireError.invalidAudioPayloadLength }
        guard Array(bytes[0..<4]) == magic else { throw VoiceCoreWireError.invalidAudioMagic }
        let version = Int(bytes[4])
        guard version == VoiceCoreControlCodec.protocolVersion else {
            throw VoiceCoreWireError.unsupportedProtocolVersion(version)
        }
        guard let kind = VoiceCoreAudioKind(rawValue: bytes[5]) else {
            throw VoiceCoreWireError.unsupportedAudioKind(bytes[5])
        }
        let flags = readUInt16(bytes, at: 6)
        guard flags == 0 else { throw VoiceCoreWireError.unsupportedAudioFlags(flags) }
        let sequence = readUInt32(bytes, at: 8)
        let timestamp = readUInt64(bytes, at: 12)
        let payloadLength = Int(readUInt32(bytes, at: 20))
        guard (1...VoiceCoreAudioFrame.maximumPayloadSize).contains(payloadLength),
              payloadLength <= Int.max - headerSize,
              bytes.count == headerSize + payloadLength else {
            throw VoiceCoreWireError.invalidAudioPayloadLength
        }
        return VoiceCoreAudioFrame(
            kind: kind,
            sequence: sequence,
            timestampMs: timestamp,
            payload: Data(bytes[headerSize...])
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in offset..<(offset + 8) { result = (result << 8) | UInt64(bytes[index]) }
        return result
    }
}

private struct Envelope: Codable {
    let protocolVersion: Int
    let type: String

    init(type: String) {
        protocolVersion = VoiceCoreControlCodec.protocolVersion
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case type
    }
}

private struct SessionStartMessage: Codable {
    let protocolVersion: Int
    let type: String
    let device: String
    let model: VoiceCoreAgentModel
    let effort: Int
    let toolProfile: VoiceCoreToolProfile
    let voice: String
    let location: VoiceCoreLocation?
    let mode: VoiceCoreVoiceMode
    let sourceLanguage: String?
    let targetLanguage: String?

    init(_ value: VoiceCoreSessionStart) {
        protocolVersion = VoiceCoreControlCodec.protocolVersion
        type = "session.start"
        device = value.device
        model = value.model
        effort = value.effort
        toolProfile = value.toolProfile
        voice = value.voice
        location = value.location
        mode = value.mode
        sourceLanguage = value.sourceLanguage
        targetLanguage = value.targetLanguage
    }

    var value: VoiceCoreSessionStart {
        VoiceCoreSessionStart(
            device: device,
            model: model,
            effort: effort,
            toolProfile: toolProfile,
            voice: voice,
            location: location,
            mode: mode,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", type, device, model, effort
        case toolProfile = "tool_profile"
        case voice, location
        case mode
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
    }
}

private struct StateMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "session.state"
    let state: VoiceCoreSessionState

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type, state }
}

private struct ModeChangedMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "mode.changed"
    let mode: VoiceCoreVoiceMode
    let sourceLanguage: String?
    let targetLanguage: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", type, mode
        case sourceLanguage = "source_language"
        case targetLanguage = "target_language"
    }
}

private struct TurnMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type: String
    let turnID: String

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type; case turnID = "turn_id" }
}

private struct TextTurnMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "text.turn"
    let turnID: String
    let text: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", type, text
        case turnID = "turn_id"
    }
}

private struct TranscriptMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "transcript.delta"
    let text: String
    let final: Bool

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type, text, final }
}

private struct TextDeltaMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "response.text.delta"
    let delta: String
    let model: String?

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type, delta, model }
}

private struct TextDoneMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "response.text.done"
    let text: String
    let model: String?

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type, text, model }
}

private struct AudioStartedMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "response.audio.started"
    let sampleRateHz: Int
    let channels: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", type
        case sampleRateHz = "sample_rate_hz"
        case channels
    }
}

private struct AudioDoneMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "response.audio.done"
    let durationMs: Int?

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type; case durationMs = "duration_ms" }
}

private struct ErrorMessage: Codable {
    let protocolVersion = VoiceCoreControlCodec.protocolVersion
    let type = "error"
    let detail: String?
    let code: String?

    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", type, detail, code }
}
