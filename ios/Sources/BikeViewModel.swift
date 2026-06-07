import Foundation
import SwiftUI

/// iOS view model — Bluetooth-LE only. Reuses the shared engine (Elm327,
/// BLETransport, ResetProfile, …) compiled into the same target.
@MainActor
final class BikeViewModel: ObservableObject {
    // Bluetooth
    @Published var devices: [BLEDevice] = []
    @Published var scanning = false
    @Published var selectedDeviceID: UUID?

    // Connection state
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var adapterInfo = ""
    @Published var voltage = ""
    @Published var voltageValue: Double = 0
    @Published var engineReachable = false
    @Published var dashReachable = false
    @Published var log = ""

    // Reset profiles
    let profiles = ResetProfile.builtIn
    @Published var selectedProfileID = ResetProfile.builtIn[0].id
    @Published var customHeaderHex = "7E3"
    @Published var customRoutineHex = "09"
    @Published var resetting = false
    @Published var lastReset: ServiceResetResult?

    // Live data / VIN / DTC
    @Published var live: LiveData?
    @Published var polling = false
    @Published var vin: String?
    @Published var dtcs: [String] = []
    @Published var dtcRead = false

    private let io = DispatchQueue(label: "moto.io")
    private var elm: Elm327?
    private var transport: Transport?

    var isCustom: Bool { selectedProfileID == "custom" }
    var effectiveProfile: ResetProfile {
        if isCustom {
            return ResetProfile.custom(
                header: UInt32(customHeaderHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x7E3,
                routine: UInt8(customRoutineHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x09)
        }
        return profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    func append(_ s: String) { log += s.hasSuffix("\n") ? s : s + "\n" }

    // MARK: Bluetooth

    func scan() {
        devices = []; scanning = true; status = "Scanning for Bluetooth adapters…"
        BLETransport.shared.onDiscover = { [weak self] d in
            guard let self else { return }
            if !self.devices.contains(d) { self.devices.append(d) }
        }
        BLETransport.shared.startScan()
    }
    func stopScan() { BLETransport.shared.stopScan(); scanning = false }

    func connect() {
        guard let id = selectedDeviceID else { status = "Pick an adapter first"; return }
        stopScan(); busy = true; status = "Connecting…"
        io.async { [weak self] in
            guard let self else { return }
            guard BLETransport.shared.connect(id) else {
                Task { @MainActor in self.busy = false; self.status = "Bluetooth connect failed (permission/pairing?)" }
                return
            }
            let t: Transport = BLETransport.shared
            let e = Elm327(port: t)
            e.currentHeader = 0x7E0
            e.logger = { line in Task { @MainActor in self.append(line) } }
            do { try e.initialize(protocolCode: "6") }
            catch { Task { @MainActor in self.busy = false; self.status = "Init failed: \(error)" }; return }
            let ident = e.transact("ATI").trimmingCharacters(in: .whitespacesAndNewlines)
            let c = e.connectivity()
            Task { @MainActor in
                self.transport = t; self.elm = e; self.connected = true; self.busy = false
                self.adapterInfo = ident
                self.voltage = c.voltage; self.voltageValue = c.voltageValue
                self.engineReachable = c.engineReachable; self.dashReachable = c.dashReachable
                self.status = c.dashReachable ? "Dashboard ECU online — ready"
                    : (c.engineReachable ? "Engine online; dash asleep (ignition ON & Refresh)"
                                         : "Connected — no ECU yet (ignition ON & Refresh)")
            }
        }
    }

    func disconnect() {
        let t = transport
        io.async { [weak self] in
            t?.close()
            Task { @MainActor in self?.transport = nil; self?.elm = nil; self?.connected = false; self?.status = "Disconnected" }
        }
    }

    func refreshConnectivity() {
        guard let e = elm else { return }
        busy = true; status = "Checking connectivity…"
        io.async { [weak self] in
            let c = e.connectivity()
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.voltage = c.voltage; self.voltageValue = c.voltageValue
                self.engineReachable = c.engineReachable; self.dashReachable = c.dashReachable
                self.status = c.dashReachable ? "Dashboard ECU online — ready" : "Dash asleep — ignition ON & retry"
            }
        }
    }

    // MARK: Reset

    func serviceReset() {
        guard let e = elm else { return }
        let p = effectiveProfile
        resetting = true; busy = true; status = "Resetting service indicator…"
        append("— SERVICE RESET — \(p.name)")
        io.async { [weak self] in
            let r = e.serviceReset(profile: p, dryRun: false)
            Task { @MainActor in
                guard let self else { return }
                self.resetting = false; self.busy = false; self.lastReset = r
                r.transcript.forEach { self.append($0) }
                self.append(r.message)
                self.status = r.success ? "✅ \(r.message)" : "⚠️ \(r.message)"
            }
        }
    }

    // MARK: Live data / VIN / DTC

    func toggleLive() {
        if polling { polling = false; return }
        guard let e = elm else { return }
        polling = true
        io.async { e.obdBegin() }
        pollTick()
    }
    private func pollTick() {
        guard polling, let e = elm else { return }
        io.async { [weak self] in
            let d = e.readLive()
            Task { @MainActor in
                guard let self, self.polling else { return }
                self.live = d
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self.pollTick()
                }
            }
        }
    }

    func readVehicleInfo() {
        guard let e = elm else { return }
        let wasPolling = polling; polling = false
        busy = true; status = "Reading VIN…"
        io.async { [weak self] in
            let v = e.readVINString()
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.vin = v
                self.status = v != nil ? "VIN: \(v!)" : "VIN read failed (ignition ON?)"
                if wasPolling { self.toggleLive() }
            }
        }
    }

    func readDTCs() {
        guard let e = elm else { return }
        let wasPolling = polling; polling = false
        busy = true; status = "Reading fault codes…"
        io.async { [weak self] in
            let codes = e.readDTCs()
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.dtcRead = true; self.dtcs = codes
                self.status = codes.isEmpty ? "No fault codes ✅" : "\(codes.count) fault code(s)"
                if wasPolling { self.toggleLive() }
            }
        }
    }
}
