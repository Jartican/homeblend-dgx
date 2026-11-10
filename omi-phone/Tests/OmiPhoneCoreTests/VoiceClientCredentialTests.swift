import XCTest
@testable import OmiPhoneCore

final class VoiceClientCredentialTests: XCTestCase {
    func testAcceptsGeneratedBase64URLToken() throws {
        let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789_-abcde"
        XCTAssertEqual(try VoiceClientCredential.validate("  \(token)\n"), token)
    }

    func testRejectsShortOversizedOrHeaderUnsafeTokens() {
        let cases: [(String, VoiceClientCredentialError)] = [
            ("short", .invalidLength),
            (String(repeating: "a", count: 257), .invalidLength),
            (String(repeating: "a", count: 31) + "\nInjected", .invalidCharacter),
            (String(repeating: "a", count: 16) + " " + String(repeating: "b", count: 16), .invalidCharacter),
        ]
        for (value, expected) in cases {
            XCTAssertThrowsError(try VoiceClientCredential.validate(value)) {
                XCTAssertEqual($0 as? VoiceClientCredentialError, expected)
            }
        }
    }
}
