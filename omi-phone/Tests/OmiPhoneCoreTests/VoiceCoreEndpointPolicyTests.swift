import Foundation
import XCTest
@testable import OmiPhoneCore

final class VoiceCoreEndpointPolicyTests: XCTestCase {
    private let policy = VoiceCoreEndpointPolicy(
        allowedHost: "spark-example.tail-example.ts.net",
        allowedPath: "/voice/v2/voice/realtime"
    )

    func testAcceptsOnlyExactProductionEndpoint() throws {
        let endpoint = try XCTUnwrap(URL(
            string: "wss://spark-example.tail-example.ts.net/voice/v2/voice/realtime"
        ))
        XCTAssertNoThrow(try policy.validate(endpoint))
    }

    func testRejectsCleartextAndLookalikeHosts() throws {
        let cleartext = try XCTUnwrap(URL(
            string: "ws://spark-example.tail-example.ts.net/voice/v2/voice/realtime"
        ))
        let lookalike = try XCTUnwrap(URL(
            string: "wss://spark-example.tail-example.ts.net.attacker.example/voice/v2/voice/realtime"
        ))
        XCTAssertThrowsError(try policy.validate(cleartext)) {
            XCTAssertEqual($0 as? VoiceCoreEndpointPolicyError, .insecureScheme)
        }
        XCTAssertThrowsError(try policy.validate(lookalike)) {
            XCTAssertEqual($0 as? VoiceCoreEndpointPolicyError, .hostNotAllowed)
        }
    }

    func testRejectsAlternatePortPathAndURLMetadata() throws {
        let cases: [(String, VoiceCoreEndpointPolicyError)] = [
            ("wss://spark-example.tail-example.ts.net:8443/voice/v2/voice/realtime", .portNotAllowed),
            ("wss://spark-example.tail-example.ts.net/other", .pathNotAllowed),
            ("wss://spark-example.tail-example.ts.net/voice/v2/voice/realtime?forward=1", .ambiguousEndpoint),
            ("wss://user@spark-example.tail-example.ts.net/voice/v2/voice/realtime", .ambiguousEndpoint),
        ]

        for (rawURL, expectedError) in cases {
            let endpoint = try XCTUnwrap(URL(string: rawURL))
            XCTAssertThrowsError(try policy.validate(endpoint), rawURL) {
                XCTAssertEqual($0 as? VoiceCoreEndpointPolicyError, expectedError)
            }
        }
    }
}
