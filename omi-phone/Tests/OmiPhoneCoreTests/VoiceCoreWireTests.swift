import Foundation
import XCTest
@testable import OmiPhoneCore

final class VoiceCoreWireTests: XCTestCase {
    func testControlRoundTripsEveryKnownMessage() throws {
        let messages: [VoiceCoreControl] = [
            .sessionReady,
            .sessionStart(.init(model: .twentySevenB, effort: 3, toolProfile: .web, location: .init(latitude: 33.45, longitude: -112.07))),
            .sessionState(.followUp),
            .modeChanged(mode: .translation, sourceLanguage: "Spanish", targetLanguage: "English"),
            .textTurn(turnID: "turn-inline", text: "Hey Gauss, activate translation."),
            .turnStart(turnID: "turn-1"), .turnCommit,
            .wakeDetected(turnID: "turn-2"), .speechStarted(turnID: "turn-3"),
            .bargeIn, .playbackFinished, .followupTimeout, .sessionClose,
            .transcriptDelta(text: "hello", final: true),
            .responseTextDelta(delta: "hi", model: "27b"),
            .responseTextDone(text: "hi there", model: nil),
            .responseAudioStarted(sampleRateHz: 24_000, channels: 1),
            .responseAudioDone(durationMs: 420),
            .gatewayError(detail: "try again", code: "recoverable"),
        ]

        for message in messages {
            XCTAssertEqual(try VoiceCoreControlCodec.decode(VoiceCoreControlCodec.encode(message)), message)
        }
    }

    func testModeChangedUsesProtocolFieldNames() throws {
        let data = try VoiceCoreControlCodec.encode(.modeChanged(
            mode: .translation,
            sourceLanguage: "Spanish",
            targetLanguage: "English"
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "mode.changed")
        XCTAssertEqual(json["mode"] as? String, "translation")
        XCTAssertEqual(json["source_language"] as? String, "Spanish")
        XCTAssertEqual(json["target_language"] as? String, "English")
    }

    func testSessionStartUsesProtocolFieldNamesAndOmitsAbsentLocation() throws {
        let data = try VoiceCoreControlCodec.encode(.sessionStart(.init(toolProfile: .none)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["protocol_version"] as? Int, 1)
        XCTAssertEqual(json["type"] as? String, "session.start")
        XCTAssertEqual(json["device"] as? String, "phone")
        XCTAssertEqual(json["model"] as? String, "auto")
        XCTAssertEqual(json["tool_profile"] as? String, "none")
        XCTAssertEqual(json["mode"] as? String, "assistant")
        XCTAssertNil(json["location"])
        XCTAssertNil(json["source_language"])
        XCTAssertNil(json["target_language"])
    }

    func testSessionStartCarriesTranslationLanguages() throws {
        let value = VoiceCoreSessionStart(
            mode: .translation,
            sourceLanguage: "Spanish",
            targetLanguage: "English"
        )
        let data = try VoiceCoreControlCodec.encode(.sessionStart(value))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["mode"] as? String, "translation")
        XCTAssertEqual(json["source_language"] as? String, "Spanish")
        XCTAssertEqual(json["target_language"] as? String, "English")
    }

    func testControlRejectsMalformedUnknownVersionAndUnknownType() {
        assertControlError("not json", .malformedControl)
        assertControlError("{}", .malformedControl)
        assertControlError(#"{"protocol_version":"1","type":"session.ready"}"#, .malformedControl)
        assertControlError(#"{"protocol_version":2,"type":"session.ready"}"#, .unsupportedProtocolVersion(2))
        assertControlError(#"{"protocol_version":1,"type":"future.event"}"#, .unsupportedControlType("future.event"))
        assertControlError(#"{"protocol_version":1,"type":"session.state","state":"future"}"#, .malformedControl)
        assertControlError(#"{"protocol_version":1,"type":"turn.start"}"#, .malformedControl)
    }

    func testBinaryGoldenVectorAndRoundTrip() throws {
        let frame = VoiceCoreAudioFrame(
            kind: .inputPCM,
            sequence: 0x0102_0304,
            timestampMs: 0x0102_0304_0506_0708,
            payload: Data([0xaa, 0xbb])
        )
        let encoded = try VoiceCoreAudioCodec.encode(frame)
        XCTAssertEqual([UInt8](encoded), [
            0x45, 0x58, 0x56, 0x32, 0x01, 0x01, 0x00, 0x00,
            0x01, 0x02, 0x03, 0x04,
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x00, 0x00, 0x00, 0x02, 0xaa, 0xbb,
        ])
        XCTAssertEqual(try VoiceCoreAudioCodec.decode(encoded), frame)
    }

    func testBinarySupportsMaximumPayloadAndBothKinds() throws {
        let frame = VoiceCoreAudioFrame(kind: .responsePCM, sequence: .max, timestampMs: .max, payload: Data(repeating: 7, count: 65_536))
        XCTAssertEqual(try VoiceCoreAudioCodec.decode(VoiceCoreAudioCodec.encode(frame)), frame)
    }

    func testBinaryEncoderRejectsEmptyAndOversizedPayloads() {
        assertAudioEncodeError(Data(), .invalidAudioPayloadLength)
        assertAudioEncodeError(Data(repeating: 0, count: 65_537), .invalidAudioPayloadLength)
    }

    func testBinaryDecoderFailsClosedForMalformedFrames() throws {
        let valid = try VoiceCoreAudioCodec.encode(.init(kind: .inputPCM, sequence: 0, timestampMs: 0, payload: Data([1])))
        assertMutatedFrame(valid, index: 0, value: 0, expected: .invalidAudioMagic)
        assertMutatedFrame(valid, index: 4, value: 2, expected: .unsupportedProtocolVersion(2))
        assertMutatedFrame(valid, index: 5, value: 3, expected: .unsupportedAudioKind(3))
        assertMutatedFrame(valid, index: 7, value: 1, expected: .unsupportedAudioFlags(1))
        XCTAssertThrowsError(try VoiceCoreAudioCodec.decode(Data([1, 2, 3]))) {
            XCTAssertEqual($0 as? VoiceCoreWireError, .invalidAudioPayloadLength)
        }

        var zeroLength = [UInt8](valid)
        zeroLength.replaceSubrange(20...23, with: [0, 0, 0, 0])
        assertAudioDecodeError(Data(zeroLength), .invalidAudioPayloadLength)

        var declaredTooLarge = [UInt8](valid)
        declaredTooLarge.replaceSubrange(20...23, with: [0, 1, 0, 1])
        assertAudioDecodeError(Data(declaredTooLarge), .invalidAudioPayloadLength)
        assertAudioDecodeError(Data(valid.dropLast()), .invalidAudioPayloadLength)
        assertAudioDecodeError(valid + Data([0]), .invalidAudioPayloadLength)
    }

    private func assertControlError(_ json: String, _ expected: VoiceCoreWireError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try VoiceCoreControlCodec.decode(Data(json.utf8)), file: file, line: line) {
            XCTAssertEqual($0 as? VoiceCoreWireError, expected, file: file, line: line)
        }
    }

    private func assertAudioEncodeError(_ payload: Data, _ expected: VoiceCoreWireError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try VoiceCoreAudioCodec.encode(.init(kind: .inputPCM, sequence: 0, timestampMs: 0, payload: payload)), file: file, line: line) {
            XCTAssertEqual($0 as? VoiceCoreWireError, expected, file: file, line: line)
        }
    }

    private func assertAudioDecodeError(_ data: Data, _ expected: VoiceCoreWireError, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try VoiceCoreAudioCodec.decode(data), file: file, line: line) {
            XCTAssertEqual($0 as? VoiceCoreWireError, expected, file: file, line: line)
        }
    }

    private func assertMutatedFrame(_ data: Data, index: Int, value: UInt8, expected: VoiceCoreWireError) {
        var bytes = [UInt8](data)
        bytes[index] = value
        assertAudioDecodeError(Data(bytes), expected)
    }
}
