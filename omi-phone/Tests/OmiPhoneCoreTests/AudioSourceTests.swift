import Foundation
import XCTest
@testable import OmiPhoneCore

final class AudioSourceTests: XCTestCase {
    func testPhoneFormatRequires16kMonoPCM16LE() async {
        await assertSourceInitFails(
            format: .init(
                sampleRateHz: 48_000,
                channelCount: 1,
                encoding: .pcmSignedInt16LittleEndian
            ),
            expected: .unsupportedSampleRate(48_000)
        )
        await assertSourceInitFails(
            format: .init(
                sampleRateHz: 16_000,
                channelCount: 2,
                encoding: .pcmSignedInt16LittleEndian
            ),
            expected: .unsupportedChannelCount(2)
        )
        await assertSourceInitFails(
            format: .init(
                sampleRateHz: 16_000,
                channelCount: 1,
                encoding: .pcmFloat32LittleEndian
            ),
            expected: .unsupportedEncoding(.pcmFloat32LittleEndian)
        )
    }

    func testChunkRejectsEmptyOddAndOversizedPayloads() {
        XCTAssertThrowsError(
            try PCM16LEAudioChunk(payload: Data(), timestampMilliseconds: 0)
        ) { error in
            XCTAssertEqual(error as? AudioSourceError, .emptyPCMFrame)
        }

        XCTAssertThrowsError(
            try PCM16LEAudioChunk(payload: Data(repeating: 0, count: 3), timestampMilliseconds: 0)
        ) { error in
            XCTAssertEqual(error as? AudioSourceError, .misalignedPCM16Frame(byteCount: 3))
        }

        let byteCount = PCM16LEAudioChunk.maximumPayloadBytes + 2
        XCTAssertThrowsError(
            try PCM16LEAudioChunk(
                payload: Data(repeating: 0, count: byteCount),
                timestampMilliseconds: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? AudioSourceError,
                .pcmFrameTooLarge(
                    byteCount: byteCount,
                    maximum: PCM16LEAudioChunk.maximumPayloadBytes
                )
            )
        }
    }

    func testChunkAcceptsMaximumEvenPayload() throws {
        let chunk = try PCM16LEAudioChunk(
            payload: Data(repeating: 0x7f, count: PCM16LEAudioChunk.maximumPayloadBytes),
            timestampMilliseconds: 42
        )

        XCTAssertEqual(chunk.payload.count, PCM16LEAudioChunk.maximumPayloadBytes)
        XCTAssertEqual(chunk.timestampMilliseconds, 42)
    }

    func testFixtureEmitsFramesAndTimestampsInDeterministicOrder() async throws {
        let payloads = [
            Data([0x01, 0x00]),
            Data([0x02, 0x00, 0x03, 0x00]),
            Data([0x04, 0x00]),
        ]
        let source = try FixtureAudioSource(
            payloads: payloads,
            startTimestampMilliseconds: 1_000,
            frameDurationMilliseconds: 20
        )

        let stream = try await source.audioChunks()
        var received: [PCM16LEAudioChunk] = []
        for try await chunk in stream {
            received.append(chunk)
        }

        XCTAssertEqual(received.map(\.payload), payloads)
        XCTAssertEqual(received.map(\.timestampMilliseconds), [1_000, 1_020, 1_040])
    }

    func testFixtureRejectsNonMonotonicTimestamps() throws {
        let later = try PCM16LEAudioChunk(
            payload: Data([0, 0]),
            timestampMilliseconds: 100
        )
        let earlier = try PCM16LEAudioChunk(
            payload: Data([0, 0]),
            timestampMilliseconds: 99
        )

        XCTAssertThrowsError(try FixtureAudioSource(chunks: [later, earlier])) { error in
            XCTAssertEqual(
                error as? AudioSourceError,
                .nonMonotonicTimestamp(previous: 100, next: 99)
            )
        }
    }

    func testStopCancelsPendingProductionAndFinishesStream() async throws {
        let source = try FixtureAudioSource(
            payloads: [Data([1, 0]), Data([2, 0])],
            interChunkDelayNanoseconds: 60_000_000_000
        )
        let stream = try await source.audioChunks()
        var iterator = stream.makeAsyncIterator()

        let first = try await iterator.next()
        XCTAssertEqual(first?.payload, Data([1, 0]))

        await source.stop()
        let afterStop = try await iterator.next()
        XCTAssertNil(afterStop)
        let isStopped = await source.isStopped()
        XCTAssertTrue(isStopped)
    }

    func testCancellingConsumerStopsSource() async throws {
        let source = try FixtureAudioSource(
            payloads: [Data([1, 0]), Data([2, 0])],
            interChunkDelayNanoseconds: 60_000_000_000
        )
        let stream = try await source.audioChunks()
        let consumer = Task {
            for try await _ in stream {
                try Task.checkCancellation()
            }
        }

        consumer.cancel()
        _ = try? await consumer.value

        for _ in 0..<20 {
            if await source.isStopped() { break }
            await Task.yield()
        }
        let isStopped = await source.isStopped()
        XCTAssertTrue(isStopped)
    }

    private func assertSourceInitFails(
        format: AudioStreamFormat,
        expected: AudioSourceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try FixtureAudioSource(format: format, chunks: [])
            XCTFail("Expected fixture initialization to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AudioSourceError, expected, file: file, line: line)
        }
    }
}
