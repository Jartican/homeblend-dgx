import AVFoundation
import Foundation
import OmiPhoneCore

enum PhoneMicrophoneError: LocalizedError {
    case permissionDenied
    case inputUnavailable
    case outputFormatUnavailable
    case converterUnavailable
    case convertedBufferUnavailable
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is not permitted."
        case .inputUnavailable:
            return "The phone microphone is unavailable."
        case .outputFormatUnavailable, .converterUnavailable, .convertedBufferUnavailable:
            return "The microphone audio format could not be prepared."
        case let .conversionFailed(message):
            return "Microphone audio conversion failed: \(message)"
        }
    }
}

/// One-shot AVFoundation microphone source for the phone-to-DGX path.
///
/// Audio is converted in memory to Voice Core's strict 16 kHz mono PCM16LE
/// contract. No WAV files, recordings, logs, or persistent buffers are made.
final class PhoneMicrophoneAudioSource: AudioSource, @unchecked Sendable {
    let format: AudioStreamFormat = .phonePCM16Mono16k

    private let engine = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<PCM16LEAudioChunk, Error>.Continuation?
    private var streamCreated = false
    private var stopped = false
    private var tapInstalled = false

    static func requestPermission() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func audioChunks() async throws -> AsyncThrowingStream<PCM16LEAudioChunk, Error> {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            throw AudioSourceError.sourceStopped
        }
        guard !streamCreated else {
            lock.unlock()
            throw AudioSourceError.alreadyStreaming
        }
        streamCreated = true
        lock.unlock()

        guard await Self.requestPermission() else {
            markStopped()
            throw PhoneMicrophoneError.permissionDenied
        }

        let stream = AsyncThrowingStream.makeStream(
            of: PCM16LEAudioChunk.self,
            throwing: Error.self
        )
        lock.lock()
        continuation = stream.continuation
        lock.unlock()
        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.stop() }
        }

        do {
            try startCapture()
            return stream.stream
        } catch {
            stream.continuation.finish(throwing: error)
            stopSynchronously()
            throw error
        }
    }

    func stop() async {
        stopSynchronously()
    }

    private func startCapture() throws {
        // Record-only mode cannot route response audio to a speaker. Playback
        // will be configured separately by the explicit TTS output adapter.
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PhoneMicrophoneError.inputUnavailable
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw PhoneMicrophoneError.outputFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw PhoneMicrophoneError.converterUnavailable
        }

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { [weak self] inputBuffer, _ in
            self?.convertAndYield(
                inputBuffer,
                using: converter,
                outputFormat: outputFormat
            )
        }
        lock.lock()
        tapInstalled = true
        lock.unlock()

        engine.prepare()
        try engine.start()
    }

    private func convertAndYield(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            fail(PhoneMicrophoneError.convertedBufferUnavailable)
            return
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error {
            fail(PhoneMicrophoneError.conversionFailed(
                conversionError?.localizedDescription ?? "unknown conversion error"
            ))
            return
        }
        guard outputBuffer.frameLength > 0,
              let samples = outputBuffer.int16ChannelData?.pointee else { return }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let payload = Data(bytes: samples, count: byteCount)
        do {
            let chunk = try PCM16LEAudioChunk(
                payload: payload,
                timestampMilliseconds: DispatchTime.now().uptimeNanoseconds / 1_000_000
            )
            currentContinuation()?.yield(chunk)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        currentContinuation()?.finish(throwing: error)
        Task { [weak self] in await self?.stop() }
    }

    private func currentContinuation() -> AsyncThrowingStream<PCM16LEAudioChunk, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }

    private func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    private func stopSynchronously() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let continuation = self.continuation
        self.continuation = nil
        let removeTap = tapInstalled
        tapInstalled = false
        lock.unlock()

        if removeTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        engine.reset()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        continuation?.finish()
    }
}
