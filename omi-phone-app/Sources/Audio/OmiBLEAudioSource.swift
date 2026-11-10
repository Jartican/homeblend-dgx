import CoreBluetooth
import Foundation
import OmiPhoneCore

enum OmiBLESourceError: LocalizedError {
    case bluetoothUnavailable(CBManagerState)
    case audioServiceMissing
    case audioCharacteristicMissing
    case codecCharacteristicMissing
    case codecValueMissing
    case protocolFailure(String)

    var errorDescription: String? {
        switch self {
        case let .bluetoothUnavailable(state):
            return "Bluetooth is unavailable (state \(state.rawValue))."
        case .audioServiceMissing:
            return "The Omi audio service was not found."
        case .audioCharacteristicMissing:
            return "The Omi audio stream characteristic was not found."
        case .codecCharacteristicMissing:
            return "The Omi codec characteristic was not found."
        case .codecValueMissing:
            return "Omi did not report an audio codec."
        case let .protocolFailure(message):
            return "Omi audio protocol error: \(message)"
        }
    }
}

enum OmiBLEUUIDs {
    static let audioService = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    static let audioStream = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    static let codec = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    static let alternateCodec = CBUUID(string: "19B10003-E8F2-537E-4F6C-D104768A1214")
}

/// Private CoreBluetooth adapter for the documented Omi audio service.
///
/// CoreBluetooth performs any OS pairing required by the peripheral. This
/// adapter scans only for Omi's audio service, reads the firmware codec before
/// subscribing, and emits bounded PCM chunks without files or audio logs.
final class OmiBLEAudioSource: NSObject, AudioSource, @unchecked Sendable {
    let format: AudioStreamFormat = .phonePCM16Mono16k

    private let queue = DispatchQueue(label: "com.homeblend.omi-ble-audio")
    private let lock = NSLock()
    private let normalizer: OmiAudioFrameNormalizer
    private lazy var central = CBCentralManager(
        delegate: self,
        queue: queue,
        options: [CBCentralManagerOptionRestoreIdentifierKey: "com.homeblend.omi-audio"]
    )

    private var continuation: AsyncThrowingStream<PCM16LEAudioChunk, Error>.Continuation?
    private var peripheral: CBPeripheral?
    private var audioCharacteristic: CBCharacteristic?
    private var codec: OmiAudioCodec?
    private var assembler = OmiBLEAudioFrameAssembler()
    private var streamCreated = false
    private var stopped = false

    init(normalizer: OmiAudioFrameNormalizer = .init()) {
        self.normalizer = normalizer
        super.init()
    }

    func audioChunks() async throws -> AsyncThrowingStream<PCM16LEAudioChunk, Error> {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            throw AudioSourceError.sourceStopped
        }
        guard !streamCreated else {
            lock.unlock()
            throw AudioSourceError.alreadyStreaming
        }
        streamCreated = true
        let stream = AsyncThrowingStream.makeStream(
            of: PCM16LEAudioChunk.self,
            throwing: Error.self
        )
        continuation = stream.continuation
        lock.unlock()

        stream.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.stop() }
        }
        queue.async { [weak self] in self?.startScanningIfReady() }
        return stream.stream
    }

    func stop() async {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.audioCharacteristic = nil
            self.codec = nil
            self.assembler.reset()
        }
        continuation?.finish()
    }

    private func startScanningIfReady() {
        guard !isStopped else { return }
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [OmiBLEUUIDs.audioService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func subscribeWhenReady() {
        guard let peripheral, let audioCharacteristic, codec != nil else { return }
        peripheral.setNotifyValue(true, for: audioCharacteristic)
    }

    private func receiveAudioNotification(_ data: Data) {
        guard let codec else {
            fail(OmiBLESourceError.codecValueMissing)
            return
        }
        do {
            if let encodedFrame = try assembler.consume(notification: data) {
                let pcm = try normalizer.normalize(encodedFrame, codec: codec)
                let chunk = try PCM16LEAudioChunk(
                    payload: pcm,
                    timestampMilliseconds: DispatchTime.now().uptimeNanoseconds / 1_000_000
                )
                currentContinuation()?.yield(chunk)
            }
        } catch {
            fail(OmiBLESourceError.protocolFailure(String(describing: error)))
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func currentContinuation() -> AsyncThrowingStream<PCM16LEAudioChunk, Error>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }

    private func fail(_ error: Error) {
        currentContinuation()?.finish(throwing: error)
        Task { [weak self] in await self?.stop() }
    }
}

extension OmiBLEAudioSource: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanningIfReady()
        case .unknown, .resetting:
            break
        case .unsupported, .unauthorized, .poweredOff:
            fail(OmiBLESourceError.bluetoothUnavailable(central.state))
        @unknown default:
            fail(OmiBLESourceError.bluetoothUnavailable(central.state))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil, !isStopped else { return }
        self.peripheral = peripheral
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([OmiBLEUUIDs.audioService])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        self.peripheral = nil
        startScanningIfReady()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        self.peripheral = nil
        audioCharacteristic = nil
        codec = nil
        assembler.reset()
        startScanningIfReady()
    }
}

extension OmiBLEAudioSource: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            fail(error)
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == OmiBLEUUIDs.audioService
        }) else {
            fail(OmiBLESourceError.audioServiceMissing)
            return
        }
        peripheral.discoverCharacteristics(
            [OmiBLEUUIDs.audioStream, OmiBLEUUIDs.codec, OmiBLEUUIDs.alternateCodec],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            fail(error)
            return
        }
        let characteristics = service.characteristics ?? []
        guard let audio = characteristics.first(where: {
            $0.uuid == OmiBLEUUIDs.audioStream
        }) else {
            fail(OmiBLESourceError.audioCharacteristicMissing)
            return
        }
        audioCharacteristic = audio

        guard let codecCharacteristic = characteristics.first(where: {
            $0.uuid == OmiBLEUUIDs.codec
        }) ?? characteristics.first(where: {
            $0.uuid == OmiBLEUUIDs.alternateCodec
        }) else {
            fail(OmiBLESourceError.codecCharacteristicMissing)
            return
        }
        peripheral.readValue(for: codecCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            fail(error)
            return
        }
        guard let value = characteristic.value else {
            fail(OmiBLESourceError.codecValueMissing)
            return
        }

        if characteristic.uuid == OmiBLEUUIDs.codec
            || characteristic.uuid == OmiBLEUUIDs.alternateCodec {
            guard let firmwareValue = value.first else {
                fail(OmiBLESourceError.codecValueMissing)
                return
            }
            do {
                codec = try OmiAudioCodec(firmwareValue: firmwareValue)
                subscribeWhenReady()
            } catch {
                fail(error)
            }
        } else if characteristic.uuid == OmiBLEUUIDs.audioStream {
            receiveAudioNotification(value)
        }
    }
}
