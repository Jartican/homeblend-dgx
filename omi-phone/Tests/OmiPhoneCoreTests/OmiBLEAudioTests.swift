import Foundation
import XCTest
@testable import OmiPhoneCore

final class OmiBLEAudioTests: XCTestCase {
    func testCodecValuesAndSampleRatesMatchFirmwareContract() throws {
        XCTAssertEqual(try OmiAudioCodec(firmwareValue: 0), .pcm16kHz)
        XCTAssertEqual(try OmiAudioCodec(firmwareValue: 1), .pcm8kHz)
        XCTAssertEqual(try OmiAudioCodec(firmwareValue: 10), .muLaw16kHz)
        XCTAssertEqual(try OmiAudioCodec(firmwareValue: 11), .muLaw8kHz)
        XCTAssertEqual(try OmiAudioCodec(firmwareValue: 20), .opus16kHz)
        XCTAssertEqual(OmiAudioCodec.opus16kHz.sampleRateHz, 16_000)
        XCTAssertEqual(OmiAudioCodec.muLaw8kHz.sampleRateHz, 8_000)

        XCTAssertThrowsError(try OmiAudioCodec(firmwareValue: 99)) { error in
            XCTAssertEqual(error as? OmiBLEAudioError, .unknownCodec(99))
        }
    }

    func testPacketParserUsesLittleEndianHeaderAndPreservesPayload() throws {
        let packet = try OmiBLEAudioPacket(notification: Data([0x34, 0x12, 0x07, 0xaa, 0xbb]))

        XCTAssertEqual(packet.packetNumber, 0x1234)
        XCTAssertEqual(packet.fragmentIndex, 7)
        XCTAssertEqual(packet.payload, Data([0xaa, 0xbb]))
    }

    func testPacketParserAllowsEmptyPayloadButRejectsShortHeaders() throws {
        XCTAssertEqual(
            try OmiBLEAudioPacket(notification: Data([1, 0, 0])).payload,
            Data()
        )

        for byteCount in 0...2 {
            XCTAssertThrowsError(
                try OmiBLEAudioPacket(notification: Data(repeating: 0, count: byteCount))
            ) { error in
                XCTAssertEqual(
                    error as? OmiBLEAudioError,
                    .notificationTooShort(byteCount: byteCount)
                )
            }
        }
    }

    func testAssemblerEmitsPreviousFrameWhenNextFrameStarts() throws {
        var assembler = OmiBLEAudioFrameAssembler()

        XCTAssertNil(try assembler.consume(packet(1, 0, [0xaa])))
        XCTAssertNil(try assembler.consume(packet(2, 1, [0xbb])))
        XCTAssertNil(try assembler.consume(packet(3, 2, [0xcc])))
        XCTAssertEqual(try assembler.consume(packet(4, 0, [0xdd])), Data([0xaa, 0xbb, 0xcc]))
        XCTAssertEqual(assembler.flush(), Data([0xdd]))
        XCTAssertFalse(assembler.hasPartialFrame)
    }

    func testAssemblerHandlesEmptyFragmentsAndConsecutiveStarts() throws {
        var assembler = OmiBLEAudioFrameAssembler()

        XCTAssertNil(try assembler.consume(packet(1, 0, [])))
        XCTAssertNil(try assembler.consume(packet(2, 1, [0xaa])))
        XCTAssertEqual(try assembler.consume(packet(3, 0, [0xbb])), Data([0xaa]))
        XCTAssertEqual(try assembler.consume(packet(4, 0, [0xcc])), Data([0xbb]))
        XCTAssertEqual(assembler.flush(), Data([0xcc]))
    }

    func testGapDuplicateAndOutOfOrderFragmentsDiscardCorruptedFrame() throws {
        let invalidSequences: [(prefix: [UInt8], invalid: UInt8)] = [
            ([], 2),    // gap: expected 1
            ([1], 1),   // duplicate: expected 2 after the first 1
            ([1], 3),   // out of order: expected 2 when 3 arrives
        ]

        for fragments in invalidSequences {
            var assembler = OmiBLEAudioFrameAssembler()
            XCTAssertNil(try assembler.consume(packet(1, 0, [0xaa])))

            for validIndex in fragments.prefix {
                XCTAssertNil(try assembler.consume(packet(2, validIndex, [0xbb])))
            }

            XCTAssertThrowsError(
                try assembler.consume(packet(3, fragments.invalid, [0xcc]))
            )
            XCTAssertFalse(assembler.hasPartialFrame)
            XCTAssertNil(assembler.flush())

            XCTAssertThrowsError(try assembler.consume(packet(4, 1, [0xdd])))
            XCTAssertNil(try assembler.consume(packet(5, 0, [0xee])))
            XCTAssertEqual(try assembler.consume(packet(6, 0, [0xff])), Data([0xee]))
        }
    }

    func testMalformedNotificationInvalidatesPartialFrame() throws {
        var assembler = OmiBLEAudioFrameAssembler()
        XCTAssertNil(try assembler.consume(packet(1, 0, [0xaa])))

        XCTAssertThrowsError(try assembler.consume(notification: Data([1, 2])))
        XCTAssertFalse(assembler.hasPartialFrame)
        XCTAssertNil(try assembler.consume(packet(2, 0, [0xbb])))
        XCTAssertEqual(assembler.flush(), Data([0xbb]))
    }

    func testFragmentIndexBoundaryFailsClosedAfter255() throws {
        var assembler = OmiBLEAudioFrameAssembler()
        XCTAssertNil(try assembler.consume(packet(0, 0, [0])))
        for index in UInt16(1)...UInt16(255) {
            XCTAssertNil(try assembler.consume(packet(index, UInt8(index), [UInt8(index)])))
        }

        XCTAssertThrowsError(try assembler.consume(packet(0, 255, [0]))) { error in
            XCTAssertEqual(
                error as? OmiBLEAudioError,
                .unexpectedFragment(expected: 256, actual: 255)
            )
        }
        XCTAssertNil(assembler.flush())
    }

    func testPacketNumberWrapDoesNotCorruptFragmentAssembly() throws {
        var assembler = OmiBLEAudioFrameAssembler()
        XCTAssertNil(try assembler.consume(packet(.max, 0, [0xaa])))
        XCTAssertNil(try assembler.consume(packet(0, 1, [0xbb])))
        XCTAssertEqual(try assembler.consume(packet(1, 0, [0xcc])), Data([0xaa, 0xbb]))
    }

    func testMuLawKnownVectorsAndLittleEndianEncoding() {
        let vectors: [(UInt8, Int16)] = [
            (0xff, 0), (0x7f, 0),
            (0xfe, 8), (0x7e, -8),
            (0xf0, 120), (0x70, -120),
            (0xd5, 716), (0x55, -716),
            (0x80, 32_124), (0x00, -32_124),
        ]

        for (encoded, expected) in vectors {
            XCTAssertEqual(MuLawDecoder.decodeSample(encoded), expected)
        }

        XCTAssertEqual(
            MuLawDecoder.decodeToPCM16LE(Data([0xfe, 0x7e, 0x80, 0x00])),
            Data([0x08, 0x00, 0xf8, 0xff, 0x7c, 0x7d, 0x84, 0x82])
        )
    }

    func testMuLawAllByteInvariants() {
        for raw in UInt16(0)...UInt16(255) {
            let byte = UInt8(raw)
            let sample = MuLawDecoder.decodeSample(byte)
            let opposite = MuLawDecoder.decodeSample(byte ^ 0x80)
            XCTAssertEqual(Int(sample), -Int(opposite))
            XCTAssertLessThanOrEqual(abs(Int(sample)), 32_124)
        }

        XCTAssertEqual(MuLawDecoder.decodeToPCM16LE(Data((0...255).map(UInt8.init))).count, 512)
    }

    func testNormalizerPassesThroughValidPCM16k() throws {
        let input = Data([0x34, 0x12, 0xcc, 0xff])
        XCTAssertEqual(
            try OmiAudioFrameNormalizer().normalize(input, codec: .pcm16kHz),
            input
        )
    }

    func testNormalizerUpsamplesPCM8kByDuplicatingSamples() throws {
        let input = Data([0x34, 0x12, 0xcc, 0xff])
        XCTAssertEqual(
            try OmiAudioFrameNormalizer().normalize(input, codec: .pcm8kHz),
            Data([0x34, 0x12, 0x34, 0x12, 0xcc, 0xff, 0xcc, 0xff])
        )
    }

    func testNormalizerDecodesBothMuLawRates() throws {
        let normalizer = OmiAudioFrameNormalizer()
        XCTAssertEqual(
            try normalizer.normalize(Data([0xfe, 0x7e]), codec: .muLaw16kHz),
            Data([0x08, 0x00, 0xf8, 0xff])
        )
        XCTAssertEqual(
            try normalizer.normalize(Data([0xfe]), codec: .muLaw8kHz),
            Data([0x08, 0x00, 0x08, 0x00])
        )
    }

    func testNormalizerRejectsEmptyOddAndOversizedPCM() {
        let normalizer = OmiAudioFrameNormalizer()
        XCTAssertThrowsError(try normalizer.normalize(Data(), codec: .pcm16kHz)) { error in
            XCTAssertEqual(error as? OmiAudioNormalizationError, .emptyFrame)
        }
        XCTAssertThrowsError(try normalizer.normalize(Data([1]), codec: .pcm16kHz)) { error in
            XCTAssertEqual(
                error as? OmiAudioNormalizationError,
                .misalignedPCM16(byteCount: 1)
            )
        }

        let oversized8k = Data(
            repeating: 0,
            count: PCM16LEAudioChunk.maximumPayloadBytes / 2 + 2
        )
        XCTAssertThrowsError(try normalizer.normalize(oversized8k, codec: .pcm8kHz)) { error in
            XCTAssertEqual(
                error as? OmiAudioNormalizationError,
                .normalizedFrameTooLarge(
                    byteCount: oversized8k.count * 2,
                    maximum: PCM16LEAudioChunk.maximumPayloadBytes
                )
            )
        }
    }

    func testNormalizerRequiresOpusDecoderAndValidatesItsOutput() throws {
        XCTAssertThrowsError(
            try OmiAudioFrameNormalizer().normalize(Data([1]), codec: .opus16kHz)
        ) { error in
            XCTAssertEqual(
                error as? OmiAudioNormalizationError,
                .opusDecoderUnavailable
            )
        }

        let decoded = Data([0x11, 0x00, 0x22, 0x00])
        XCTAssertEqual(
            try OmiAudioFrameNormalizer(opusDecoder: OpusFixture(output: decoded))
                .normalize(Data([0xaa]), codec: .opus16kHz),
            decoded
        )

        for invalid in [Data(), Data([1]), Data(repeating: 0, count: 65_538)] {
            XCTAssertThrowsError(
                try OmiAudioFrameNormalizer(opusDecoder: OpusFixture(output: invalid))
                    .normalize(Data([0xaa]), codec: .opus16kHz)
            )
        }

        XCTAssertThrowsError(
            try OmiAudioFrameNormalizer(opusDecoder: ThrowingOpusFixture())
                .normalize(Data([0xaa]), codec: .opus16kHz)
        ) { error in
            XCTAssertEqual(error as? OmiAudioNormalizationError, .opusDecodeFailed)
        }
    }

    private func packet(
        _ number: UInt16,
        _ fragmentIndex: UInt8,
        _ payload: [UInt8]
    ) -> OmiBLEAudioPacket {
        OmiBLEAudioPacket(
            packetNumber: number,
            fragmentIndex: fragmentIndex,
            payload: Data(payload)
        )
    }
}

private struct OpusFixture: OmiOpusDecoding {
    let output: Data

    func decodeToPCM16LE(_ encodedFrame: Data) throws -> Data {
        output
    }
}

private struct ThrowingOpusFixture: OmiOpusDecoding {
    struct Failure: Error {}

    func decodeToPCM16LE(_ encodedFrame: Data) throws -> Data {
        throw Failure()
    }
}
