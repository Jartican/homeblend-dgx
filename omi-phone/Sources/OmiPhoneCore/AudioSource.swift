import Foundation

public enum AudioSampleEncoding: String, Equatable, Sendable {
    case pcmSignedInt16LittleEndian
    case pcmFloat32LittleEndian
}

public struct AudioStreamFormat: Equatable, Sendable {
    public let sampleRateHz: Int
    public let channelCount: Int
    public let encoding: AudioSampleEncoding

    public init(
        sampleRateHz: Int,
        channelCount: Int,
        encoding: AudioSampleEncoding
    ) {
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
        self.encoding = encoding
    }

    public static let phonePCM16Mono16k = AudioStreamFormat(
        sampleRateHz: 16_000,
        channelCount: 1,
        encoding: .pcmSignedInt16LittleEndian
    )

    public func validateForPhoneCapture() throws {
        guard sampleRateHz == 16_000 else {
            throw AudioSourceError.unsupportedSampleRate(sampleRateHz)
        }
        guard channelCount == 1 else {
            throw AudioSourceError.unsupportedChannelCount(channelCount)
        }
        guard encoding == .pcmSignedInt16LittleEndian else {
            throw AudioSourceError.unsupportedEncoding(encoding)
        }
    }
}

public enum AudioSourceError: Error, Equatable, Sendable {
    case unsupportedSampleRate(Int)
    case unsupportedChannelCount(Int)
    case unsupportedEncoding(AudioSampleEncoding)
    case emptyPCMFrame
    case misalignedPCM16Frame(byteCount: Int)
    case pcmFrameTooLarge(byteCount: Int, maximum: Int)
    case nonMonotonicTimestamp(previous: UInt64, next: UInt64)
    case alreadyStreaming
    case sourceStopped
}

/// One device-neutral Voice Core input frame.
///
/// The payload contains raw signed PCM16 little-endian samples. It has no WAV
/// header and is bounded to the Voice Core v2 input-frame limit.
public struct PCM16LEAudioChunk: Equatable, Sendable {
    public static let maximumPayloadBytes = 65_536

    public let payload: Data
    public let timestampMilliseconds: UInt64

    public init(payload: Data, timestampMilliseconds: UInt64) throws {
        guard !payload.isEmpty else {
            throw AudioSourceError.emptyPCMFrame
        }
        guard payload.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw AudioSourceError.misalignedPCM16Frame(byteCount: payload.count)
        }
        guard payload.count <= Self.maximumPayloadBytes else {
            throw AudioSourceError.pcmFrameTooLarge(
                byteCount: payload.count,
                maximum: Self.maximumPayloadBytes
            )
        }

        self.payload = payload
        self.timestampMilliseconds = timestampMilliseconds
    }
}

/// Boundary between audio capture hardware and the HomeBlend transport.
///
/// AVFoundation, an Omi SDK adapter, or a test fixture can implement this
/// protocol without changing the transport. Implementations must expose 16 kHz
/// mono PCM16LE and must finish their stream when `stop()` is called.
public protocol AudioSource: Sendable {
    var format: AudioStreamFormat { get }

    func audioChunks() async throws -> AsyncThrowingStream<PCM16LEAudioChunk, Error>
    func stop() async
}

/// Deterministic, dependency-free microphone substitute for tests and the
/// first phone-to-DGX integration pass.
///
/// Each instance supports one stream. A real phone or Omi adapter should be a
/// separate `AudioSource` implementation rather than adding device behavior to
/// this fixture.
public actor FixtureAudioSource: AudioSource {
    public nonisolated let format: AudioStreamFormat

    private let chunks: [PCM16LEAudioChunk]
    private let interChunkDelayNanoseconds: UInt64
    private var producer: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<PCM16LEAudioChunk, Error>.Continuation?
    private var stopped = false
    private var streamCreated = false

    public init(
        format: AudioStreamFormat = .phonePCM16Mono16k,
        chunks: [PCM16LEAudioChunk],
        interChunkDelayNanoseconds: UInt64 = 0
    ) throws {
        try format.validateForPhoneCapture()
        try Self.validateMonotonicTimestamps(chunks)
        self.format = format
        self.chunks = chunks
        self.interChunkDelayNanoseconds = interChunkDelayNanoseconds
    }

    /// Convenience initializer for raw fixture frames. Timestamps are derived
    /// deterministically from `startTimestampMilliseconds` and
    /// `frameDurationMilliseconds`.
    public init(
        format: AudioStreamFormat = .phonePCM16Mono16k,
        payloads: [Data],
        startTimestampMilliseconds: UInt64 = 0,
        frameDurationMilliseconds: UInt64 = 20,
        interChunkDelayNanoseconds: UInt64 = 0
    ) throws {
        try format.validateForPhoneCapture()
        self.format = format
        self.chunks = try payloads.enumerated().map { index, payload in
            let offset = UInt64(index).multipliedReportingOverflow(
                by: frameDurationMilliseconds
            )
            guard !offset.overflow else {
                throw AudioSourceError.nonMonotonicTimestamp(
                    previous: startTimestampMilliseconds,
                    next: 0
                )
            }
            let timestamp = startTimestampMilliseconds.addingReportingOverflow(offset.partialValue)
            guard !timestamp.overflow else {
                throw AudioSourceError.nonMonotonicTimestamp(
                    previous: startTimestampMilliseconds,
                    next: timestamp.partialValue
                )
            }
            return try PCM16LEAudioChunk(
                payload: payload,
                timestampMilliseconds: timestamp.partialValue
            )
        }
        self.interChunkDelayNanoseconds = interChunkDelayNanoseconds
    }

    public func audioChunks() async throws -> AsyncThrowingStream<PCM16LEAudioChunk, Error> {
        guard !stopped else { throw AudioSourceError.sourceStopped }
        guard !streamCreated else { throw AudioSourceError.alreadyStreaming }
        streamCreated = true

        let pair = AsyncThrowingStream<PCM16LEAudioChunk, Error>.makeStream(
            of: PCM16LEAudioChunk.self,
            throwing: Error.self
        )
        continuation = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cancelProduction() }
        }
        producer = Task { [weak self] in
            await self?.emitFixture()
        }
        return pair.stream
    }

    public func stop() async {
        guard !stopped else { return }
        stopped = true
        producer?.cancel()
        producer = nil
        continuation?.finish()
        continuation = nil
    }

    public func isStopped() -> Bool {
        stopped
    }

    private func emitFixture() async {
        for (index, chunk) in chunks.enumerated() {
            guard !Task.isCancelled, !stopped else { return }
            continuation?.yield(chunk)

            guard index < chunks.index(before: chunks.endIndex),
                  interChunkDelayNanoseconds > 0 else { continue }
            do {
                try await Task.sleep(nanoseconds: interChunkDelayNanoseconds)
            } catch {
                return
            }
        }

        guard !Task.isCancelled, !stopped else { return }
        continuation?.finish()
        continuation = nil
        producer = nil
    }

    private func cancelProduction() {
        guard !stopped else { return }
        stopped = true
        producer?.cancel()
        producer = nil
        continuation = nil
    }

    private static func validateMonotonicTimestamps(
        _ chunks: [PCM16LEAudioChunk]
    ) throws {
        for pair in zip(chunks, chunks.dropFirst()) {
            guard pair.1.timestampMilliseconds >= pair.0.timestampMilliseconds else {
                throw AudioSourceError.nonMonotonicTimestamp(
                    previous: pair.0.timestampMilliseconds,
                    next: pair.1.timestampMilliseconds
                )
            }
        }
    }
}
