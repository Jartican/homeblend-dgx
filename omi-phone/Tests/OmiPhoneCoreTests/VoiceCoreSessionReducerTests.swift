import XCTest
@testable import OmiPhoneCore

final class VoiceCoreSessionReducerTests: XCTestCase {
    func testPartialAndFinalTranscriptUpdateStateAndOutputs() {
        var state = VoiceCoreSessionViewState()

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .control(.transcriptDelta(text: "Where is", final: false))
            ),
            [.transcriptChanged(text: "Where is", isFinal: false)]
        )
        XCTAssertEqual(state.partialTranscript, "Where is")
        XCTAssertEqual(state.companion.liveTranscript, "Where is")

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .control(.transcriptDelta(text: "Where is lunch?", final: true))
            ),
            [
                .transcriptChanged(text: "Where is lunch?", isFinal: true),
                .companionEffect(.submitUtterance(text: "Where is lunch?", mode: .assistant)),
            ]
        )
        XCTAssertEqual(state.partialTranscript, "")
        XCTAssertEqual(state.finalTranscript, "Where is lunch?")
        XCTAssertEqual(state.companion.captureState, .processing)
    }

    func testFinalWakeCommandChangesModeWithoutSubmittingAgentContent() {
        var state = VoiceCoreSessionViewState()
        let mode = CompanionMode.translation(
            sourceLanguage: "spanish",
            targetLanguage: "english"
        )

        let outputs = VoiceCoreSessionReducer.reduce(
            state: &state,
            event: .control(.transcriptDelta(
                text: "Hey Gauss, translate Spanish to English.",
                final: true
            ))
        )

        XCTAssertEqual(outputs, [
            .transcriptChanged(
                text: "Hey Gauss, translate Spanish to English.",
                isFinal: true
            ),
            .companionEffect(.modeChanged(mode)),
        ])
        XCTAssertFalse(outputs.contains { output in
            if case .companionEffect(.submitUtterance(text: _, mode: _)) = output {
                return true
            }
            return false
        })
        XCTAssertEqual(state.companion.mode, mode)
    }

    func testResponseDeltasAccumulateAndDoneUsesAuthoritativeText() {
        var state = VoiceCoreSessionViewState()

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .control(.responseTextDelta(delta: "Hello ", model: "8b"))
            ),
            [.responseTextChanged(text: "Hello ", isFinal: false)]
        )
        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .control(.responseTextDelta(delta: "there", model: "8b"))
            ),
            [.responseTextChanged(text: "Hello there", isFinal: false)]
        )
        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .control(.responseTextDone(text: "Hello there!", model: "8b"))
            ),
            [
                .responseTextChanged(text: "Hello there!", isFinal: true),
                .companionEffect(.renderText("Hello there!")),
            ]
        )
        XCTAssertEqual(state.responseText, "Hello there!")
        XCTAssertEqual(state.finalResponseText, "Hello there!")
        XCTAssertEqual(state.companion.lastResponse, "Hello there!")
    }

    func testEmptyDoneFallsBackToAccumulatedResponse() {
        var state = VoiceCoreSessionViewState(responseText: "Complete answer")

        let outputs = VoiceCoreSessionReducer.reduce(
            state: &state,
            event: .control(.responseTextDone(text: "", model: nil))
        )

        XCTAssertEqual(outputs.first, .responseTextChanged(text: "Complete answer", isFinal: true))
        XCTAssertEqual(state.finalResponseText, "Complete answer")
    }

    func testSessionAndTransportStatusAreReduced() {
        var state = VoiceCoreSessionViewState()

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(state: &state, event: .stateChanged(.active)),
            [.transportStateChanged(.active)]
        )
        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                control: .sessionState(.capturing)
            ),
            [.sessionStateChanged(.capturing)]
        )
        XCTAssertEqual(state.transportState, .active)
        XCTAssertEqual(state.sessionState, .capturing)
    }

    func testServerModeChangeIsAuthoritative() {
        var state = VoiceCoreSessionViewState()
        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                control: .modeChanged(
                    mode: .translation,
                    sourceLanguage: "French",
                    targetLanguage: "English"
                )
            ),
            [.voiceModeChanged(
                mode: .translation,
                sourceLanguage: "French",
                targetLanguage: "English"
            )]
        )
        XCTAssertEqual(state.voiceMode, .translation)
        XCTAssertEqual(state.sourceLanguage, "French")
        XCTAssertEqual(state.targetLanguage, "English")
    }

    func testNewTurnClearsTurnDataAndStartsCompanionCapture() {
        var state = VoiceCoreSessionViewState(
            partialTranscript: "old partial",
            finalTranscript: "old question",
            responseText: "old response",
            finalResponseText: "old response",
            lastError: "old error"
        )

        let outputs = VoiceCoreSessionReducer.reduce(
            state: &state,
            event: .control(.wakeDetected(turnID: "turn-2"))
        )

        XCTAssertEqual(outputs, [])
        XCTAssertEqual(state.partialTranscript, "")
        XCTAssertNil(state.finalTranscript)
        XCTAssertEqual(state.responseText, "")
        XCTAssertNil(state.finalResponseText)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.companion.captureState, .listening)
    }

    func testErrorsUpdateBothSessionAndCompanionState() {
        var state = VoiceCoreSessionViewState(
            companion: CompanionState(captureState: .listening)
        )

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .control(.gatewayError(detail: "Provider unavailable", code: "upstream"))
            ),
            [.error("Provider unavailable")]
        )
        XCTAssertEqual(state.lastError, "Provider unavailable")
        XCTAssertEqual(state.companion.lastError, "Provider unavailable")
        XCTAssertEqual(state.companion.captureState, .stopped)
    }

    func testDisconnectReportsWhetherReconnectWillOccur() {
        var state = VoiceCoreSessionViewState()

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(
                state: &state,
                event: .disconnected(willReconnect: true)
            ),
            [.error("Voice connection interrupted; reconnecting.")]
        )
        XCTAssertEqual(state.lastError, "Voice connection interrupted; reconnecting.")
    }

    func testAudioFramesAreNotRetainedByUIReducer() {
        var state = VoiceCoreSessionViewState()
        let frame = VoiceCoreAudioFrame(
            kind: .responsePCM,
            sequence: 1,
            timestampMs: 2,
            payload: Data([1, 2])
        )

        XCTAssertEqual(
            VoiceCoreSessionReducer.reduce(state: &state, event: .audio(frame)),
            []
        )
        XCTAssertEqual(state, VoiceCoreSessionViewState())
    }
}
