import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum VoiceCoreWebSocketMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// Small seam around URLSessionWebSocketTask so transport behavior can be
/// verified without a network connection.
public protocol VoiceCoreWebSocket: AnyObject, Sendable {
    func send(_ message: VoiceCoreWebSocketMessage) async throws
    func receive() async throws -> VoiceCoreWebSocketMessage
    func close() async
}

public protocol VoiceCoreWebSocketFactory: Sendable {
    func makeWebSocket(for request: URLRequest) async throws -> any VoiceCoreWebSocket
}

public protocol VoiceCoreReconnectSleeping: Sendable {
    func sleep(milliseconds: UInt64) async throws
}

public struct VoiceCoreTaskSleeper: VoiceCoreReconnectSleeping {
    public init() {}

    public func sleep(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}

public enum VoiceCoreTransportState: Equatable, Sendable {
    case stopped
    case disconnected
    case connecting
    case awaitingReady
    case active
    case reconnecting(attempt: Int, delayMilliseconds: UInt64)
}

public enum VoiceCoreTransportEvent: Equatable, Sendable {
    case stateChanged(VoiceCoreTransportState)
    case control(VoiceCoreControl)
    case audio(VoiceCoreAudioFrame)
    case disconnected(willReconnect: Bool)
    case failed(String)
}

public enum VoiceCoreTransportError: Error, Equatable, Sendable {
    case notConnected
    case sessionNotReady
    case invalidControlForState(control: String, state: VoiceCoreSessionState?)
    case inputAudioRequiresCapturing
    case inputAudioSendFailed
}

public struct VoiceCoreTransportConfiguration: Equatable, Sendable {
    public static let maximumReconnectAttempts = 8
    public static let maximumReconnectDelayMilliseconds: UInt64 = 30_000

    public let sessionStart: VoiceCoreSessionStart
    public let reconnectDelaysMilliseconds: [UInt64]

    public init(
        sessionStart: VoiceCoreSessionStart = .init(),
        reconnectDelaysMilliseconds: [UInt64] = [250, 500, 1_000, 2_000]
    ) {
        // The phone adapter always identifies itself as a phone, even if a
        // caller reused settings originating from another device adapter.
        self.sessionStart = VoiceCoreSessionStart(
            device: "phone",
            model: sessionStart.model,
            effort: sessionStart.effort,
            toolProfile: sessionStart.toolProfile,
            voice: sessionStart.voice,
            location: sessionStart.location,
            mode: sessionStart.mode,
            sourceLanguage: sessionStart.sourceLanguage,
            targetLanguage: sessionStart.targetLanguage
        )
        self.reconnectDelaysMilliseconds = reconnectDelaysMilliseconds
            .prefix(Self.maximumReconnectAttempts)
            .map { min($0, Self.maximumReconnectDelayMilliseconds) }
    }
}

/// Stateful Voice Core v2 transport.
///
/// Authentication is deliberately outside this type. `requestProvider` must
/// return a fresh URLRequest (normally with an Authorization header) for every
/// connection attempt. The transport never receives or stores a bearer token.
public actor VoiceCoreTransport {
    public typealias RequestProvider = @Sendable () async throws -> URLRequest

    public nonisolated let events: AsyncStream<VoiceCoreTransportEvent>

    private let requestProvider: RequestProvider
    private let factory: any VoiceCoreWebSocketFactory
    private let sleeper: any VoiceCoreReconnectSleeping
    private let configuration: VoiceCoreTransportConfiguration
    private let continuation: AsyncStream<VoiceCoreTransportEvent>.Continuation

    private var socket: (any VoiceCoreWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldRun = false
    private var reconnectAttempt = 0
    private var transportState: VoiceCoreTransportState = .stopped
    private var remoteState: VoiceCoreSessionState?
    private var nextSequence: UInt32 = 0

    public init(
        configuration: VoiceCoreTransportConfiguration = .init(),
        requestProvider: @escaping RequestProvider,
        factory: any VoiceCoreWebSocketFactory = URLSessionVoiceCoreWebSocketFactory(),
        sleeper: any VoiceCoreReconnectSleeping = VoiceCoreTaskSleeper()
    ) {
        let stream = AsyncStream.makeStream(of: VoiceCoreTransportEvent.self)
        events = stream.stream
        continuation = stream.continuation
        self.configuration = configuration
        self.requestProvider = requestProvider
        self.factory = factory
        self.sleeper = sleeper
    }

    deinit {
        continuation.finish()
    }

    public func state() -> VoiceCoreTransportState { transportState }

    public func sessionState() -> VoiceCoreSessionState? { remoteState }

    public func start() async {
        guard !shouldRun else { return }
        shouldRun = true
        reconnectAttempt = 0
        await openConnection()
    }

    public func stop() async {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        receiveTask?.cancel()
        receiveTask = nil

        if let socket {
            if transportState == .active,
               let data = try? VoiceCoreControlCodec.encode(.sessionClose) {
                try? await socket.send(.text(String(decoding: data, as: UTF8.self)))
            }
            await socket.close()
        }
        socket = nil
        remoteState = nil
        nextSequence = 0
        transition(to: .stopped)
    }

    public func sendControl(_ control: VoiceCoreControl) async throws {
        guard transportState == .active, let socket else {
            throw VoiceCoreTransportError.sessionNotReady
        }
        guard controlIsAllowed(control, in: remoteState) else {
            throw VoiceCoreTransportError.invalidControlForState(
                control: controlName(control),
                state: remoteState
            )
        }
        let data = try VoiceCoreControlCodec.encode(control)
        do {
            try await socket.send(.text(String(decoding: data, as: UTF8.self)))
            if startsCapture(control) { nextSequence = 0 }
        } catch {
            await connectionFailed(socket)
            throw VoiceCoreTransportError.notConnected
        }
    }

    /// Sends one input frame immediately. Frames are never queued, retained,
    /// or replayed across a disconnect.
    public func sendInputPCM(_ chunk: PCM16LEAudioChunk) async throws {
        guard transportState == .active, let socket else {
            throw VoiceCoreTransportError.notConnected
        }
        guard remoteState == .capturing else {
            throw VoiceCoreTransportError.inputAudioRequiresCapturing
        }

        let frame = VoiceCoreAudioFrame(
            kind: .inputPCM,
            sequence: nextSequence,
            timestampMs: chunk.timestampMilliseconds,
            payload: chunk.payload
        )
        let encoded = try VoiceCoreAudioCodec.encode(frame)
        do {
            try await socket.send(.data(encoded))
            nextSequence &+= 1
        } catch {
            await connectionFailed(socket)
            throw VoiceCoreTransportError.inputAudioSendFailed
        }
    }

    private func openConnection() async {
        guard shouldRun else { return }
        transition(to: .connecting)
        do {
            let request = try await requestProvider()
            guard shouldRun else { return }
            let newSocket = try await factory.makeWebSocket(for: request)
            guard shouldRun else {
                await newSocket.close()
                return
            }
            socket = newSocket
            remoteState = nil
            nextSequence = 0
            transition(to: .awaitingReady)
            receiveTask = Task { [weak self, newSocket] in
                await self?.receiveLoop(newSocket)
            }
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(.failed(String(describing: error)))
            await scheduleReconnect()
        }
    }

    private func receiveLoop(_ connectedSocket: any VoiceCoreWebSocket) async {
        do {
            while shouldRun, socket === connectedSocket {
                let message = try await connectedSocket.receive()
                try await handle(message, from: connectedSocket)
            }
        } catch is CancellationError {
            return
        } catch {
            continuation.yield(.failed(String(describing: error)))
            await connectionFailed(connectedSocket)
        }
    }

    private func handle(
        _ message: VoiceCoreWebSocketMessage,
        from connectedSocket: any VoiceCoreWebSocket
    ) async throws {
        guard socket === connectedSocket else { return }
        switch message {
        case let .text(text):
            try await handleControl(VoiceCoreControlCodec.decode(Data(text.utf8)), socket: connectedSocket)
        case let .data(data):
            if data.starts(with: [0x45, 0x58, 0x56, 0x32]) {
                continuation.yield(.audio(try VoiceCoreAudioCodec.decode(data)))
            } else {
                try await handleControl(VoiceCoreControlCodec.decode(data), socket: connectedSocket)
            }
        }
    }

    private func handleControl(
        _ control: VoiceCoreControl,
        socket connectedSocket: any VoiceCoreWebSocket
    ) async throws {
        if control == .sessionReady {
            guard transportState == .awaitingReady else { return }
            let data = try VoiceCoreControlCodec.encode(.sessionStart(configuration.sessionStart))
            try await connectedSocket.send(.text(String(decoding: data, as: UTF8.self)))
            reconnectAttempt = 0
            transition(to: .active)
        } else if case let .sessionState(state) = control {
            remoteState = state
        }
        continuation.yield(.control(control))
    }

    private func connectionFailed(_ failedSocket: any VoiceCoreWebSocket) async {
        guard socket === failedSocket else { return }
        receiveTask?.cancel()
        receiveTask = nil
        await failedSocket.close()
        socket = nil
        remoteState = nil
        nextSequence = 0
        await scheduleReconnect()
    }

    private func scheduleReconnect() async {
        guard shouldRun else {
            transition(to: .stopped)
            return
        }
        guard reconnectAttempt < configuration.reconnectDelaysMilliseconds.count else {
            shouldRun = false
            transition(to: .disconnected)
            continuation.yield(.disconnected(willReconnect: false))
            return
        }

        let delay = configuration.reconnectDelaysMilliseconds[reconnectAttempt]
        reconnectAttempt += 1
        transition(to: .reconnecting(attempt: reconnectAttempt, delayMilliseconds: delay))
        continuation.yield(.disconnected(willReconnect: true))
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self, sleeper] in
            do {
                try await sleeper.sleep(milliseconds: delay)
                guard !Task.isCancelled else { return }
                await self?.openConnection()
            } catch {
                // Cancellation is expected during stop(); no reconnect follows.
            }
        }
    }

    private func transition(to newState: VoiceCoreTransportState) {
        transportState = newState
        continuation.yield(.stateChanged(newState))
    }

    private func controlIsAllowed(
        _ control: VoiceCoreControl,
        in state: VoiceCoreSessionState?
    ) -> Bool {
        switch control {
        case .turnStart, .wakeDetected:
            return state == .armed
        case .speechStarted:
            return state == .followUp
        case .turnCommit:
            return state == .capturing
        case .bargeIn:
            return state == .thinking || state == .speaking
        case .playbackFinished:
            return state == .speaking
        case .followupTimeout:
            return state == .followUp
        case .sessionClose:
            return true
        case .textTurn:
            return state == .armed || state == .followUp
        default:
            return false
        }
    }

    private func startsCapture(_ control: VoiceCoreControl) -> Bool {
        switch control {
        case .turnStart, .wakeDetected, .speechStarted, .bargeIn: return true
        default: return false
        }
    }

    private func controlName(_ control: VoiceCoreControl) -> String {
        switch control {
        case .turnStart: return "turn.start"
        case .wakeDetected: return "wake.detected"
        case .speechStarted: return "speech.started"
        case .turnCommit: return "turn.commit"
        case .bargeIn: return "barge_in"
        case .playbackFinished: return "playback.finished"
        case .followupTimeout: return "followup.timeout"
        case .sessionClose: return "session.close"
        case .textTurn: return "text.turn"
        default: return "inbound-only"
        }
    }
}

public struct URLSessionVoiceCoreWebSocketFactory: VoiceCoreWebSocketFactory {
    private let session: URLSession

    public init(session: URLSession = URLSessionVoiceCoreWebSocketFactory.privateSession()) {
        self.session = session
    }

    /// Ephemeral networking prevents cookies, credentials, and response caches
    /// from becoming an accidental second persistence layer on the phone.
    public static func privateSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }

    public func makeWebSocket(for request: URLRequest) async throws -> any VoiceCoreWebSocket {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionVoiceCoreWebSocket(task: task)
    }
}

private final class URLSessionVoiceCoreWebSocket: VoiceCoreWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ message: VoiceCoreWebSocketMessage) async throws {
        switch message {
        case let .text(text): try await task.send(.string(text))
        case let .data(data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> VoiceCoreWebSocketMessage {
        switch try await task.receive() {
        case let .string(text): return .text(text)
        case let .data(data): return .data(data)
        @unknown default: throw VoiceCoreTransportError.notConnected
        }
    }

    func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
