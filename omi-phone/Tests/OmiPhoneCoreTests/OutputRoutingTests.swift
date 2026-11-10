import XCTest
@testable import OmiPhoneCore

final class OutputRoutingTests: XCTestCase {
    private let router = DefaultOutputRouter()

    func testTextOnlyIsDefault() {
        let state = CompanionState()
        XCTAssertEqual(state.outputPreference, .textOnly)

        XCTAssertEqual(
            router.plan(
                preference: state.outputPreference,
                environment: .init(headphonesConnected: true, phoneSpeakerEnabledInApp: true),
                speechAvailable: true
            ),
            OutputPlan()
        )
    }

    func testHeadphonesRequireOptInAndConnection() {
        XCTAssertEqual(
            router.plan(
                preference: .headphonesWhenAvailable,
                environment: .init(headphonesConnected: true),
                speechAvailable: true
            ),
            OutputPlan(speechDestination: .headphones)
        )
    }

    func testDisconnectedHeadphonesNeverFallBackToSpeaker() {
        XCTAssertEqual(
            router.plan(
                preference: .headphonesWhenAvailable,
                environment: .init(
                    headphonesConnected: false,
                    phoneSpeakerEnabledInApp: true
                ),
                speechAvailable: true
            ),
            OutputPlan()
        )
    }

    func testPhoneSpeakerRequiresExplicitInAppPermission() {
        XCTAssertEqual(
            router.plan(
                preference: .phoneSpeaker,
                environment: .init(phoneSpeakerEnabledInApp: false),
                speechAvailable: true
            ),
            OutputPlan()
        )
        XCTAssertEqual(
            router.plan(
                preference: .phoneSpeaker,
                environment: .init(phoneSpeakerEnabledInApp: true),
                speechAvailable: true
            ),
            OutputPlan(speechDestination: .phoneSpeaker)
        )
    }

    func testUnavailableSpeechAlwaysLeavesText() {
        XCTAssertEqual(
            router.plan(
                preference: .phoneSpeaker,
                environment: .init(phoneSpeakerEnabledInApp: true),
                speechAvailable: false
            ),
            OutputPlan()
        )
    }
}
