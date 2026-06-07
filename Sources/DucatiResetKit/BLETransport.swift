import Foundation
#if canImport(CoreBluetooth)
import CoreBluetooth

/// A discovered Bluetooth-LE peripheral (for the UI device list).
public struct BLEDevice: Identifiable, Hashable {
    public let id: UUID
    public let name: String
}

/// Bluetooth-LE transport for ELM327 adapters (generic BLE dongles; possibly
/// Carista). EXPERIMENTAL — validate with a real adapter.
///
/// Most BLE ELM327s expose a single GATT service (commonly FFF0 / FFE0) with a
/// write characteristic and a notify characteristic. This implementation does
/// not hard-code UUIDs: after connecting it picks the first writable and first
/// notifying characteristic it finds, which covers the common variants.
public final class BLETransport: NSObject, Transport, CBCentralManagerDelegate, CBPeripheralDelegate {

    public static let shared = BLETransport()

    private var central: CBCentralManager!
    private let bleQueue = DispatchQueue(label: "moto.ble")

    // discovery
    private var found: [UUID: CBPeripheral] = [:]
    public var onDiscover: ((BLEDevice) -> Void)?
    private var wantScan = false

    // active connection
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var rx = Data()
    private let lock = NSLock()
    private var readySem: DispatchSemaphore?
    private(set) public var isReady = false

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue)
    }

    // MARK: - Discovery

    /// Begin scanning for BLE peripherals. `onDiscover` fires for each named one.
    public func startScan() {
        wantScan = true
        if central.state == .poweredOn { central.scanForPeripherals(withServices: nil) }
    }

    public func stopScan() {
        wantScan = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connection (Transport.open equivalent)

    /// Connects to a discovered peripheral and waits until a usable
    /// write+notify characteristic pair is ready. Returns false on timeout.
    @discardableResult
    public func connect(_ id: UUID, timeout: TimeInterval = 12) -> Bool {
        stopScan()
        guard let p = found[id] else { return false }
        isReady = false; writeChar = nil; notifyChar = nil
        lock.lock(); rx.removeAll(); lock.unlock()
        peripheral = p
        p.delegate = self
        let sem = DispatchSemaphore(value: 0)
        readySem = sem
        central.connect(p, options: nil)
        let ok = sem.wait(timeout: .now() + timeout) == .success
        return ok && isReady
    }

    // MARK: - Transport

    public func write(_ data: Data) throws {
        guard let p = peripheral, let ch = writeChar else { throw TransportError.notOpen }
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let maxLen = max(20, p.maximumWriteValueLength(for: type))
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: maxLen, limitedBy: data.endIndex) ?? data.endIndex
            p.writeValue(data.subdata(in: i..<j), for: ch, type: type)
            i = j
        }
    }

    public func read(timeout: TimeInterval) -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            lock.lock()
            if !rx.isEmpty { let out = rx; rx.removeAll(); lock.unlock(); return out }
            lock.unlock()
            usleep(15_000)
        } while Date() < deadline
        return Data()
    }

    public func close() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; writeChar = nil; notifyChar = nil; isReady = false
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && wantScan {
            central.scanForPeripherals(withServices: nil)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard !name.isEmpty else { return }
        if found[p.identifier] == nil {
            found[p.identifier] = p
            let dev = BLEDevice(id: p.identifier, name: name)
            DispatchQueue.main.async { self.onDiscover?(dev) }
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        readySem?.signal()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            if writeChar == nil,
               ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse) {
                writeChar = ch
            }
            if notifyChar == nil,
               ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                notifyChar = ch
                p.setNotifyValue(true, for: ch)
            }
        }
        if writeChar != nil && notifyChar != nil && !isReady {
            isReady = true
            readySem?.signal()
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value, !d.isEmpty else { return }
        lock.lock(); rx.append(d); lock.unlock()
    }
}
#endif
