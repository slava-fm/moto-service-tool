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
    /// Human-readable progress / state for the UI ("what it's doing now").
    public var onStatus: ((String) -> Void)?
    private func status(_ s: String) { let cb = onStatus; DispatchQueue.main.async { cb?(s) } }
    /// Detailed log sink (GATT layout, etc.) — appended to the log, not the status line.
    public var onLog: ((String) -> Void)?
    private func dlog(_ s: String) { let cb = onLog; DispatchQueue.main.async { cb?(s) } }

    private func propsString(_ p: CBCharacteristicProperties) -> String {
        var t: [String] = []
        if p.contains(.read) { t.append("read") }
        if p.contains(.write) { t.append("write") }
        if p.contains(.writeWithoutResponse) { t.append("writeNR") }
        if p.contains(.notify) { t.append("notify") }
        if p.contains(.indicate) { t.append("indicate") }
        return t.joined(separator: ",")
    }
    private var wantScan = false

    // active connection
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var expectedServices = 0
    private var scannedServices = 0
    private var allChars: [CBCharacteristic] = []
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
        guard let p = found[id] else { status("Adapter no longer visible — rescan"); return false }
        isReady = false; writeChar = nil; notifyChar = nil
        lock.lock(); rx.removeAll(); lock.unlock()
        peripheral = p
        p.delegate = self
        let sem = DispatchSemaphore(value: 0)
        readySem = sem
        status("Connecting to \(p.name ?? "adapter") over Bluetooth…")
        central.connect(p, options: nil)
        let ok = sem.wait(timeout: .now() + timeout) == .success
        if !ok { status("Bluetooth connect timed out") }
        else if !isReady { status("Connected, but no ELM327 service found on this adapter") }
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
        switch central.state {
        case .poweredOn:
            if wantScan { status("Scanning for Bluetooth adapters…"); central.scanForPeripherals(withServices: nil) }
        case .poweredOff:    status("Bluetooth is OFF — turn it on in Control Center / System Settings")
        case .unauthorized:  status("Bluetooth permission denied — enable in System Settings ▸ Privacy ▸ Bluetooth")
        case .unsupported:   status("Bluetooth LE not available on this device (e.g. Simulator)")
        default:             status("Bluetooth not ready (\(central.state.rawValue))…")
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
        status("Connected — discovering services…")
        p.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        readySem?.signal()
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        expectedServices = services.count
        scannedServices = 0
        allChars.removeAll()
        for s in services {
            dlog("service \(s.uuid)")
            p.discoverCharacteristics(nil, for: s)
        }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for ch in service.characteristics ?? [] {
            dlog("  char \(ch.uuid) [\(propsString(ch.properties))]")
            allChars.append(ch)
        }
        scannedServices += 1
        guard scannedServices >= expectedServices, !isReady else { return }
        chooseCharacteristics(p)
    }

    /// Pick the data characteristics once ALL services are known, preferring the
    /// canonical ELM327 BLE UUIDs (FFF2 write / FFF1 notify, or FFE1) over any
    /// vendor service that happens to be discovered first.
    private func chooseCharacteristics(_ p: CBPeripheral) {
        func pick(_ prefs: [String], _ need: (CBCharacteristicProperties) -> Bool) -> CBCharacteristic? {
            for u in prefs {
                if let c = allChars.first(where: {
                    $0.uuid.uuidString.caseInsensitiveCompare(u) == .orderedSame && need($0.properties)
                }) { return c }
            }
            return allChars.first { need($0.properties) }
        }
        notifyChar = pick(["FFF1", "FFE1", "FFE0"], { $0.contains(.notify) || $0.contains(.indicate) })
        writeChar  = pick(["FFF2", "FFE1", "FFF1"], { $0.contains(.write) || $0.contains(.writeWithoutResponse) })

        guard let n = notifyChar, let w = writeChar else {
            status("No usable ELM327 characteristics found on this adapter")
            readySem?.signal(); return
        }
        dlog("→ WRITE \(w.uuid) [\(propsString(w.properties))]")
        dlog("→ NOTIFY \(n.uuid) [\(propsString(n.properties))]")
        p.setNotifyValue(true, for: n)
        isReady = true
        status("Bluetooth link ready — talking to adapter…")
        readySem?.signal()
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        dlog("notify \(ch.uuid) = \(ch.isNotifying ? "ON" : "off")\(error.map { " err: \($0.localizedDescription)" } ?? "")")
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value, !d.isEmpty else { return }
        lock.lock(); rx.append(d); lock.unlock()
    }
}
#endif
