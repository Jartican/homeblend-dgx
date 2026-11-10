import AVFoundation
import Foundation
import OmiPhoneCore
import Opus

/// Minimal adapter around the exact swift-opus revision pinned in project.yml.
/// The decoder is stateful and serialized because consecutive Opus packets may
/// depend on prior decoder state. It returns in-memory PCM only.
final class SwiftOpusDecoder: OmiOpusDecoding, @unchecked Sendable {
    private let decoder: Opus.Decoder
    private let lock = NSLock()

    init() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw PhoneMicrophoneError.outputFormatUnavailable
        }
        decoder = try Opus.Decoder(format: format, application: .voip)
    }

    func decodeToPCM16LE(_ encodedFrame: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try decoder.decodeToData(encodedFrame)
    }

    func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        try decoder.reset()
    }
}
