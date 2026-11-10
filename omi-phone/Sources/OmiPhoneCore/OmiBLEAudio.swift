import Foundation

/// Audio codecs reported by the Omi firmware codec characteristic.
///
/// The adapter deliberately models only documented wire values. Unknown values
/// are rejected instead of being guessed, because decoding bytes with the wrong
/// codec can turn malformed input into plausible-looking audio.
public enum OmiAudioCodec: UInt8, CaseIterable, Equatable, Sendable {
    case pcm16kHz = 0
    case pcm8kHz = 1
    case muLaw16kHz = 10
    case muLaw8kHz = 11
    case opus16kHz = 20

    public var sampleRateHz: Int {
        switch self {
        case .pcm16kHz, .muLaw16kHz, .opus16kHz:
            return 16_000
        case .pcm8kHz, .muLaw8kHz:
            return 8_000
        }
    }
}

public enum OmiBLEAudioError: Error, Equatable, Sendable {
    case unknownCodec(UInt8)
    case notificationTooShort(byteCount: Int)
    case orphanContinuation(fragmentIndex: UInt8)
    case unexpectedFragment(expected: Int, actual: UInt8)
}

public extension OmiAudioCodec {
    init(firmwareValue: UInt8) throws {
        guard let codec = Self(rawValue: firmwareValue) else {
            throw OmiBLEAudioError.unknownCodec(firmwareValue)
        }
        self = codec
    }
}

/// One decoded Omi BLE audio notification.
///
/// Notifications contain a little-endian packet number, a frame-local fragment
/// index, and zero or more encoded audio bytes. No audio is logged or persisted.
public struct OmiBLEAudioPacket: Equatable, Sendable {
    public let packetNumber: UInt16
    public let fragmentIndex: UInt8
    public let payload: Data

    public init(notification: Data) throws {
        guard notification.count >= 3 else {
            throw OmiBLEAudioError.notificationTooShort(byteCount: notification.count)
        }

        self.packetNumber = UInt16(notification[notification.startIndex])
            | (UInt16(notification[notification.index(after: notification.startIndex)]) << 8)
        self.fragmentIndex = notification[notification.index(notification.startIndex, offsetBy: 2)]
        self.payload = notification.dropFirst(3)
    }

    public init(packetNumber: UInt16, fragmentIndex: UInt8, payload: Data) {
        self.packetNumber = packetNumber
        self.fragmentIndex = fragmentIndex
        self.payload = payload
    }
}

/// Reassembles encoded frames from Omi BLE notification fragments.
///
/// Fragment zero starts a new frame and emits the preceding valid, nonempty
/// frame. Any gap, duplicate, or out-of-order continuation discards the whole
/// partial frame. Continuations are ignored until another fragment zero starts
/// a clean frame. Packet numbers remain metadata; Omi's fragment index is the
/// authoritative frame-order field.
public struct OmiBLEAudioFrameAssembler: Sendable {
    private var frame = Data()
    private var expectedFragmentIndex: Int?

    public init() {}

    public var hasPartialFrame: Bool {
        expectedFragmentIndex != nil
    }

    @discardableResult
    public mutating func consume(notification: Data) throws -> Data? {
        do {
            return try consume(OmiBLEAudioPacket(notification: notification))
        } catch {
            reset()
            throw error
        }
    }

    @discardableResult
    public mutating func consume(_ packet: OmiBLEAudioPacket) throws -> Data? {
        if packet.fragmentIndex == 0 {
            let completed = frame.isEmpty ? nil : frame
            frame = packet.payload
            expectedFragmentIndex = 1
            return completed
        }

        guard let expectedFragmentIndex else {
            throw OmiBLEAudioError.orphanContinuation(fragmentIndex: packet.fragmentIndex)
        }
        guard Int(packet.fragmentIndex) == expectedFragmentIndex else {
            reset()
            throw OmiBLEAudioError.unexpectedFragment(
                expected: expectedFragmentIndex,
                actual: packet.fragmentIndex
            )
        }

        frame.append(packet.payload)
        self.expectedFragmentIndex = expectedFragmentIndex + 1
        return nil
    }

    /// Emits the current valid frame, if nonempty, and clears all state.
    public mutating func flush() -> Data? {
        defer { reset() }
        guard expectedFragmentIndex != nil, !frame.isEmpty else { return nil }
        return frame
    }

    public mutating func reset() {
        frame.removeAll(keepingCapacity: false)
        expectedFragmentIndex = nil
    }
}

/// Dependency-free G.711 mu-law decoding used by Omi's documented fallback
/// codecs. Output is raw signed PCM16 little-endian with no file header.
public enum MuLawDecoder {
    public static func decodeSample(_ encoded: UInt8) -> Int16 {
        let value = ~encoded
        let sign = value & 0x80
        let exponent = Int((value >> 4) & 0x07)
        let mantissa = Int(value & 0x0f)
        let magnitude = ((mantissa << 3) + 0x84) << exponent
        let sample = sign == 0 ? magnitude - 0x84 : 0x84 - magnitude
        return Int16(sample)
    }

    public static func decodeToPCM16LE(_ encoded: Data) -> Data {
        var result = Data()
        result.reserveCapacity(encoded.count * MemoryLayout<Int16>.size)

        for byte in encoded {
            let bits = UInt16(bitPattern: decodeSample(byte))
            result.append(UInt8(truncatingIfNeeded: bits))
            result.append(UInt8(truncatingIfNeeded: bits >> 8))
        }
        return result
    }
}

public enum OmiAudioNormalizationError: Error, Equatable, Sendable {
    case emptyFrame
    case misalignedPCM16(byteCount: Int)
    case normalizedFrameTooLarge(byteCount: Int, maximum: Int)
    case opusDecoderUnavailable
    case opusDecodeFailed
}

/// Narrow seam for the one native dependency needed by Opus-capable Omi
/// firmware. The concrete adapter can wrap a pinned `swift-opus` version
/// without importing Omi cloud, logging, STT, or temporary-file behavior.
public protocol OmiOpusDecoding: Sendable {
    func decodeToPCM16LE(_ encodedFrame: Data) throws -> Data
}

/// Converts one complete Omi encoded frame to Voice Core's 16 kHz mono
/// PCM16LE input contract. All transforms are in-memory and bounded.
public struct OmiAudioFrameNormalizer: Sendable {
    private let opusDecoder: (any OmiOpusDecoding)?

    public init(opusDecoder: (any OmiOpusDecoding)? = nil) {
        self.opusDecoder = opusDecoder
    }

    public func normalize(
        _ encodedFrame: Data,
        codec: OmiAudioCodec
    ) throws -> Data {
        guard !encodedFrame.isEmpty else {
            throw OmiAudioNormalizationError.emptyFrame
        }

        let normalized: Data
        switch codec {
        case .pcm16kHz:
            normalized = try validatePCM(encodedFrame)

        case .pcm8kHz:
            normalized = try upsample8kTo16k(validatePCM(encodedFrame))

        case .muLaw16kHz:
            normalized = MuLawDecoder.decodeToPCM16LE(encodedFrame)

        case .muLaw8kHz:
            normalized = try upsample8kTo16k(
                MuLawDecoder.decodeToPCM16LE(encodedFrame)
            )

        case .opus16kHz:
            guard let opusDecoder else {
                throw OmiAudioNormalizationError.opusDecoderUnavailable
            }
            do {
                normalized = try validatePCM(
                    opusDecoder.decodeToPCM16LE(encodedFrame)
                )
            } catch let error as OmiAudioNormalizationError {
                throw error
            } catch {
                throw OmiAudioNormalizationError.opusDecodeFailed
            }
        }

        return try validatePCM(normalized)
    }

    private func validatePCM(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty else {
            throw OmiAudioNormalizationError.emptyFrame
        }
        guard pcm.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw OmiAudioNormalizationError.misalignedPCM16(byteCount: pcm.count)
        }
        guard pcm.count <= PCM16LEAudioChunk.maximumPayloadBytes else {
            throw OmiAudioNormalizationError.normalizedFrameTooLarge(
                byteCount: pcm.count,
                maximum: PCM16LEAudioChunk.maximumPayloadBytes
            )
        }
        return pcm
    }

    /// Deterministic fallback resampling. Repeating each sample preserves
    /// amplitude and duration without synthesizing or persisting audio.
    private func upsample8kTo16k(_ pcm8k: Data) throws -> Data {
        let outputSize = pcm8k.count.multipliedReportingOverflow(by: 2)
        guard !outputSize.overflow,
              outputSize.partialValue <= PCM16LEAudioChunk.maximumPayloadBytes else {
            throw OmiAudioNormalizationError.normalizedFrameTooLarge(
                byteCount: outputSize.partialValue,
                maximum: PCM16LEAudioChunk.maximumPayloadBytes
            )
        }

        var result = Data()
        result.reserveCapacity(outputSize.partialValue)
        var index = pcm8k.startIndex
        while index < pcm8k.endIndex {
            let next = pcm8k.index(after: index)
            let low = pcm8k[index]
            let high = pcm8k[next]
            result.append(contentsOf: [low, high, low, high])
            index = pcm8k.index(after: next)
        }
        return result
    }
}
