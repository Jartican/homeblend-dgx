import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OmiPhoneCore

final class VoiceCoreTransportTests: XCTestCase {
    func testReconnectConfigurationBoundsAttemptsAndDelay() {
        let configuration = VoiceCoreTransportConfiguration(
            reconnectDelaysMilliseconds: Array(repeating: .max, count: 20)
        )
        XCTAssertEqual(
            configuration.reconnectDelaysMilliseconds,
            Array(
                repeating: VoiceCoreTransportConfiguration.maximumReconnectDelayMilliseconds,
                count: VoiceCoreTransportConfiguration.maximumReconnectAttempts
            )
        )
    }

    func testUsesExternallyAuthorizedRequestAndStartsPhoneSessionAfterReady() async throws {
        let socket = FakeWebSocket()
        let factory = FakeWebSocketFactory(sockets: [socket])
        var authorizedRequest = URLRequest(url: try XCTUnwrap(URL(string: "wss://voice.example.test/voice")))
        authorizedRequest.setValue("Bearer short-lived-token", forHTTPHeaderField: "Authorization")
        let request = authorizedRequest
        let transport = VoiceCoreTransport(requestProvider: { request }, factory: factory)

        await transport.start()
        try await waitUntil { await factory.requestCount == 1 }
        let observedRequest = await factory.request(at: 0)
        XCTAssertEqual(observedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer short-lived-token")

        await socket.enqueue(control: .sessionReady)
        try await waitUntil { await socket.sentCount == 1 }
        let sentMessage = await socket.sent(at: 0)
        let sent = try XCTUnwrap(sentMessage)
        guard case let .text(json) = sent else {
            return XCTFail("Expected JSON session.start")
        }
        guard case let .sessionStart(start) = try VoiceCoreControlCodec.decode(Data(json.utf8)) else {
            return XCTFail("Expected session.start")
        }
        XCTAssertEqual(start.device, "phone")
        let state = await transport.state()
        XCTAssertEqual(state, .active)
        await transport.stop()
    }

    func testPCMIsAcceptedOnlyWhileRemoteStateIsCapturing() async throws {
        let socket = FakeWebSocket()
        let transport = VoiceCoreTransport(
            requestProvider: { URLRequest(url: URL(string: "wss://voice.example.test")!) },
            factory: FakeWebSocketFactory(sockets: [socket])
        )
        await transport.start()
        await socket.enqueue(control: .sessionReady)
        try await waitUntil { await transport.state() == .active }

        await socket.enqueue(control: .sessionState(.armed))
        try await waitUntil { await transport.sessionState() == .armed }
        let firstChunk = try PCM16LEAudioChunk(payload: Data([1, 2]), timestampMilliseconds: 1)
        await XCTAssertThrowsErrorAsync(try await transport.sendInputPCM(firstChunk)) {
            XCTAssertEqual($0 as? VoiceCoreTransportError, .inputAudioRequiresCapturing)
        }

        await socket.enqueue(control: .sessionState(.capturing))
        try await waitUntil { await transport.sessionState() == .capturing }
        let acceptedChunk = try PCM16LEAudioChunk(payload: Data([3, 4]), timestampMilliseconds: 2)
        try await transport.sendInputPCM(acceptedChunk)
        let audio = await socket.sentMessages().compactMap { message -> VoiceCoreAudioFrame? in
            guard case let .data(data) = message else { return nil }
            return try? VoiceCoreAudioCodec.decode(data)
        }
        XCTAssertEqual(audio.map(\.payload), [Data([3, 4])])

        await socket.enqueue(control: .sessionState(.thinking))
        try await waitUntil { await transport.sessionState() == .thinking }
        let finalChunk = try PCM16LEAudioChunk(payload: Data([5, 6]), timestampMilliseconds: 3)
        await XCTAssertThrowsErrorAsync(try await transport.sendInputPCM(finalChunk)) {
            XCTAssertEqual($0 as? VoiceCoreTransportError, .inputAudioRequiresCapturing)
        }
        await transport.stop()
    }

    func testClientControlsAreGatedByAuthoritativeServerState() async throws {
        let socket = FakeWebSocket()
        let transport = VoiceCoreTransport(
            requestProvider: { URLRequest(url: URL(string: "wss://voice.example.test")!) },
            factory: FakeWebSocketFactory(sockets: [socket])
        )
        await transport.start()
        await socket.enqueue(control: .sessionReady)
        await socket.enqueue(control: .sessionState(.armed))
        try await waitUntil { await transport.sessionState() == .armed }

        await XCTAssertThrowsErrorAsync(try await transport.sendControl(.turnCommit)) {
            XCTAssertEqual(
                $0 as? VoiceCoreTransportError,
                .invalidControlForState(control: "turn.commit", state: .armed)
            )
        }
        try await transport.sendControl(.turnStart(turnID: "turn-1"))

        await socket.enqueue(control: .sessionState(.capturing))
        try await waitUntil { await transport.sessionState() == .capturing }
        try await transport.sendControl(.turnCommit)

        let controls = await socket.sentMessages().compactMap { message -> VoiceCoreControl? in
            guard case let .text(text) = message else { return nil }
            return try? VoiceCoreControlCodec.decode(Data(text.utf8))
        }
        XCTAssertEqual(
            controls,
            [.sessionStart(.init()), .turnStart(turnID: "turn-1"), .turnCommit]
        )
        await transport.stop()
    }

    func testDisconnectNeverReplaysUncommittedAudio() async throws {
        let first = FakeWebSocket()
        let second = FakeWebSocket()
        let factory = FakeWebSocketFactory(sockets: [first, second])
        let sleeper = RecordingImmediateSleeper()
        let transport = VoiceCoreTransport(
            configuration: .init(reconnectDelaysMilliseconds: [10]),
            requestProvider: { URLRequest(url: URL(string: "wss://voice.example.test")!) },
            factory: factory,
            sleeper: sleeper
        )
        await transport.start()
        await first.enqueue(control: .sessionReady)
        await first.enqueue(control: .sessionState(.capturing))
        try await waitUntil { await transport.sessionState() == .capturing }
        try await transport.sendInputPCM(
            PCM16LEAudioChunk(payload: Data([9, 9]), timestampMilliseconds: 1)
        )

        await first.failReceive()
        try await waitUntil { await factory.requestCount == 2 }
        await second.enqueue(control: .sessionReady)
        await second.enqueue(control: .sessionState(.capturing))
        try await waitUntil { await transport.sessionState() == .capturing }

        let messagesBeforeNewAudio = await second.sentMessages()
        XCTAssertFalse(messagesBeforeNewAudio.contains { message in
            if case .data = message { return true }
            return false
        })
        try await transport.sendInputPCM(
            PCM16LEAudioChunk(payload: Data([7, 0]), timestampMilliseconds: 2)
        )
        let frames = await second.sentMessages().compactMap { message -> VoiceCoreAudioFrame? in
            guard case let .data(data) = message else { return nil }
            return try? VoiceCoreAudioCodec.decode(data)
        }
        XCTAssertEqual(frames.map(\.payload), [Data([7, 0])])
        XCTAssertEqual(frames.map(\.sequence), [0])
        let delays = await sleeper.recordedDelays
        XCTAssertEqual(delays, [10])
        await transport.stop()
    }

    func testReconnectBackoffIsBoundedAndStopsAfterConfiguredAttempts() async throws {
        let first = FakeWebSocket()
        let second = FakeWebSocket()
        let third = FakeWebSocket()
        let factory = FakeWebSocketFactory(sockets: [first, second, third])
        let sleeper = RecordingImmediateSleeper()
        let transport = VoiceCoreTransport(
            configuration: .init(reconnectDelaysMilliseconds: [5, 10]),
            requestProvider: { URLRequest(url: URL(string: "wss://voice.example.test")!) },
            factory: factory,
            sleeper: sleeper
        )
        await transport.start()
        await first.failReceive()
        try await waitUntil { await factory.requestCount == 2 }
        await second.failReceive()
        try await waitUntil { await factory.requestCount == 3 }
        await third.failReceive()
        try await waitUntil { await transport.state() == .disconnected }

        let delays = await sleeper.recordedDelays
        let requestCount = await factory.requestCount
        XCTAssertEqual(delays, [5, 10])
        XCTAssertEqual(requestCount, 3)
        await transport.stop()
    }

    func testStopClosesSocketAndPreventsReconnect() async throws {
        let socket = FakeWebSocket()
        let factory = FakeWebSocketFactory(sockets: [socket, FakeWebSocket()])
        let transport = VoiceCoreTransport(
            configuration: .init(reconnectDelaysMilliseconds: [1]),
            requestProvider: { URLRequest(url: URL(string: "wss://voice.example.test")!) },
            factory: factory,
            sleeper: RecordingImmediateSleeper()
        )
        await transport.start()
        try await waitUntil { await factory.requestCount == 1 }
        await transport.stop()
        await socket.failReceive()
        for _ in 0..<10 { await Task.yield() }

        let closed = await socket.isClosed
        let requestCount = await factory.requestCount
        let state = await transport.state()
        XCTAssertTrue(closed)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(state, .stopped)
    }

    private func waitUntil(
        attempts: Int = 500,
        _ condition: @escaping () async -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous condition")
    }
}

private enum FakeSocketError: Error { case disconnected }

private actor FakeWebSocket: VoiceCoreWebSocket {
    private var sent: [VoiceCoreWebSocketMessage] = []
    private var inbound: [Result<VoiceCoreWebSocketMessage, Error>] = []
    private var waiter: CheckedContinuation<VoiceCoreWebSocketMessage, Error>?
    private(set) var isClosed = false

    var sentCount: Int { sent.count }

    func sent(at index: Int) -> VoiceCoreWebSocketMessage? {
        sent.indices.contains(index) ? sent[index] : nil
    }

    func sentMessages() -> [VoiceCoreWebSocketMessage] { sent }

    func send(_ message: VoiceCoreWebSocketMessage) async throws {
        guard !isClosed else { throw FakeSocketError.disconnected }
        sent.append(message)
    }

    func receive() async throws -> VoiceCoreWebSocketMessage {
        if !inbound.isEmpty { return try inbound.removeFirst().get() }
        guard !isClosed else { throw FakeSocketError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {
        isClosed = true
        waiter?.resume(throwing: FakeSocketError.disconnected)
        waiter = nil
    }

    func enqueue(control: VoiceCoreControl) async {
        let data = try! VoiceCoreControlCodec.encode(control)
        enqueue(.success(.text(String(decoding: data, as: UTF8.self))))
    }

    func failReceive() async {
        enqueue(.failure(FakeSocketError.disconnected))
    }

    private func enqueue(_ result: Result<VoiceCoreWebSocketMessage, Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        } else {
            inbound.append(result)
        }
    }
}

private actor FakeWebSocketFactory: VoiceCoreWebSocketFactory {
    private var sockets: [FakeWebSocket]
    private var requests: [URLRequest] = []

    init(sockets: [FakeWebSocket]) { self.sockets = sockets }

    var requestCount: Int { requests.count }

    func request(at index: Int) -> URLRequest? {
        requests.indices.contains(index) ? requests[index] : nil
    }

    func makeWebSocket(for request: URLRequest) async throws -> any VoiceCoreWebSocket {
        requests.append(request)
        guard !sockets.isEmpty else { throw FakeSocketError.disconnected }
        return sockets.removeFirst()
    }
}

private actor RecordingImmediateSleeper: VoiceCoreReconnectSleeping {
    private(set) var recordedDelays: [UInt64] = []

    func sleep(milliseconds: UInt64) async throws {
        recordedDelays.append(milliseconds)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
