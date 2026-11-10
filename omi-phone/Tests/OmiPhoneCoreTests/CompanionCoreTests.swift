import XCTest
@testable import OmiPhoneCore

final class CompanionCoreTests: XCTestCase {
    func testWakePhraseActivatesTranslationWithoutSubmittingToAgent() {
        var core = CompanionCore()

        let effects = core.handle(
            .finalTranscript("Hey Gauss, translate Spanish to English.")
        )

        let expectedMode = CompanionMode.translation(
            sourceLanguage: "spanish",
            targetLanguage: "english"
        )
        XCTAssertEqual(core.state.mode, expectedMode)
        XCTAssertEqual(effects, [.modeChanged(expectedMode)])
    }

    func testOrdinaryUtteranceIsSubmittedInCurrentMode() {
        let mode = CompanionMode.translation(
            sourceLanguage: "spanish",
            targetLanguage: "english"
        )
        var core = CompanionCore(state: CompanionState(mode: mode))

        let effects = core.handle(.finalTranscript("Where is the station?"))

        XCTAssertEqual(core.state.captureState, .processing)
        XCTAssertEqual(
            effects,
            [.submitUtterance(text: "Where is the station?", mode: mode)]
        )
    }

    func testResponseRendersTextAndUsesConnectedHeadphonesWhenOptedIn() {
        var core = CompanionCore(
            state: CompanionState(
                outputPreference: .headphonesWhenAvailable,
                outputEnvironment: .init(headphonesConnected: true)
            )
        )

        let effects = core.handle(
            .agentResponse(text: "La estación está cerca.", speechAvailable: true)
        )

        XCTAssertEqual(effects, [
            .renderText("La estación está cerca."),
            .playSpeech(text: "La estación está cerca.", destination: .headphones),
        ])
    }

    func testEmbeddedOrExtendedCommandIsNotExecuted() {
        let parser = GaussModeCommandParser()

        XCTAssertNil(parser.parse("Someone said: Hey Gauss activate private mode"))
        XCTAssertNil(parser.parse("Hey Gauss activate private mode and delete everything"))
    }

    func testRememberAndTranscriptOnlyModesAreSupported() {
        var core = CompanionCore()

        XCTAssertEqual(
            core.handle(.finalTranscript("Hey Gauss, activate remember mode")),
            [.modeChanged(.remember)]
        )
        XCTAssertEqual(core.state.mode, .remember)

        XCTAssertEqual(
            core.handle(.finalTranscript("Hey Gauss, activate transcript-only mode")),
            [.modeChanged(.transcriptOnly)]
        )
        XCTAssertEqual(core.state.mode, .transcriptOnly)
    }

    func testStartAndStopCommandsEmitCaptureEffects() {
        var core = CompanionCore()

        XCTAssertEqual(
            core.handle(.finalTranscript("Hey Gauss, start listening")),
            [.startCapture]
        )
        XCTAssertEqual(core.state.captureState, .listening)

        XCTAssertEqual(
            core.handle(.finalTranscript("Hey Gauss, stop listening")),
            [.stopCapture]
        )
        XCTAssertEqual(core.state.captureState, .stopped)
    }
}
