import Foundation
import DucatiResetKit
#if canImport(Darwin)
import Darwin
#endif

/// All serial/ELM327 work runs on a private queue; published state is updated
/// back on the main thread for SwiftUI.
@MainActor
final class ResetViewModel: ObservableObject {
    // Connection settings
    @Published var ports: [String] = []
    @Published var selectedPort: String = ""
    @Published var baud: Int = 38400
    @Published var protocolCode: String = "6"          // HS-CAN 11b/500k
    @Published var headerHex: String = "7E0"

    // Live state
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Not connected"
    @Published var adapterInfo = ""
    @Published var voltage = ""
    @Published var log = ""

    // Connectivity panel + service reset
    @Published var voltageValue: Double = 0
    @Published var dashReachable = false
    @Published var engineReachable = false
    @Published var resetting = false
    @Published var lastReset: ServiceResetResult?

    // Model / reset profile
    let profiles: [ResetProfile] = ResetProfile.builtIn
    @Published var selectedProfileID: String = ResetProfile.builtIn[0].id
    @Published var customHeaderHex: String = "7E3"
    @Published var customRoutineHex: String = "09"
    var isCustomProfile: Bool { selectedProfileID == "custom" }
    var effectiveProfile: ResetProfile {
        if selectedProfileID == "custom" {
            return ResetProfile.custom(header: UInt32(customHeaderHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x7E3,
                                       routine: UInt8(customRoutineHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x09)
        }
        return profiles.first { $0.id == selectedProfileID } ?? profiles[0]
    }

    // Live data / vehicle info / DTC
    @Published var live: LiveData?
    @Published var polling = false
    @Published var vin: String?
    @Published var dtcs: [String] = []
    @Published var dtcRead = false

    // Reset sequence (editable; filled by capture/import or typed manually)
    @Published var resetScript = """
    # ELM327 commands, one per line. Lines starting with # are ignored.
    # Either paste a captured MelcoDiag sequence here, or import a capture log.
    # Example shape (NOT a confirmed reset — replace with your captured bytes):
    ATSH7E0
    1003
    3101FF00
    """

    // Capture proxy
    @Published var capturing = false
    @Published var virtualPort = ""
    private var proxy: SerialProxy?

    private let io = DispatchQueue(label: "ducati.io")
    private var port: SerialPort?
    private var elm: Elm327?

    private var header: UInt32 { UInt32(headerHex.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0x7E0 }

    func append(_ s: String) { log += s.hasSuffix("\n") ? s : s + "\n" }

    func refreshPorts() {
        ports = SerialPort.availablePorts()
        if selectedPort.isEmpty { selectedPort = ports.first ?? "" }
        else if !ports.contains(selectedPort) { selectedPort = ports.first ?? "" }
        status = ports.isEmpty ? "No serial adapters found" : "\(ports.count) port(s) found"
    }

    // MARK: - Connect

    func connect() {
        guard !selectedPort.isEmpty else { status = "Pick a serial port first"; return }
        busy = true; status = "Connecting…"
        let path = selectedPort, baud = self.baud, proto = self.protocolCode, hdr = self.header
        io.async { [weak self] in
            guard let self else { return }
            let p = SerialPort(path: path)
            do {
                try p.open(baud: speed_t(baudConst(baud)))
            } catch {
                Task { @MainActor in self.busy = false; self.status = "Open failed: \(error)" }
                return
            }
            let e = Elm327(port: p)
            e.currentHeader = hdr
            e.logger = { line in Task { @MainActor in self.append(line) } }
            do { try e.initialize(protocolCode: proto) }
            catch { Task { @MainActor in self.busy = false; self.status = "Init failed: \(error)" }; return }

            let id = e.transact("ATI").trimmingCharacters(in: .whitespacesAndNewlines)
            let dp = e.transact("ATDP").trimmingCharacters(in: .whitespacesAndNewlines)
            // Full connectivity probe (voltage + engine/dash ECU reachability).
            let c = e.connectivity()
            Task { @MainActor in
                self.port = p; self.elm = e
                self.connected = true; self.busy = false
                self.adapterInfo = "\(id)  ·  \(dp)"
                self.voltage = c.voltage
                self.voltageValue = c.voltageValue
                self.engineReachable = c.engineReachable
                self.dashReachable = c.dashReachable
                self.status = c.dashReachable ? "Connected — dashboard ECU online"
                    : (c.engineReachable ? "Connected — engine online, dash asleep (ignition ON & Refresh)"
                                         : "Connected to adapter — no ECU yet (ignition ON & Refresh)")
                self.append("Connected: \(id) | \(c.voltage) | engine \(c.engineReachable ? "✓" : "✗") | dash \(c.dashReachable ? "✓" : "✗")")
            }
        }
    }

    func disconnect() {
        io.async { [weak self] in
            self?.port?.close()
            Task { @MainActor in
                self?.port = nil; self?.elm = nil
                self?.connected = false; self?.status = "Disconnected"
            }
        }
    }

    // MARK: - Scan

    func scan() {
        guard let e = elm else { status = "Connect first"; return }
        busy = true; status = "Scanning ECUs…"
        io.async { [weak self] in
            var found: [String] = []
            for ecu in 0...7 {
                let tx = UInt32(0x7E0 + ecu)
                e.setHeader(tx)
                do {
                    let r = try e.request([0x10, 0x01], timeout: 1.2)
                    found.append(String(format: "0x%03X → %@", tx, r.hex as NSString))
                } catch { continue }
            }
            e.setHeader(self?.header ?? 0x7E0)
            Task { @MainActor in
                self?.busy = false
                if found.isEmpty { self?.status = "No ECU answered 7E0..7E7 (try another protocol)"; self?.append("Scan: no responders") }
                else { self?.status = "Found \(found.count) ECU(s)"; found.forEach { self?.append("ECU \($0)") } }
            }
        }
    }

    // MARK: - Connectivity + one-click service reset

    /// Refresh the connectivity panel: adapter id, voltage, dash/engine ECU reachable.
    func refreshConnectivity() {
        guard let e = elm else { status = "Connect first"; return }
        busy = true; status = "Checking connectivity…"
        io.async { [weak self] in
            let c = e.connectivity()
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.adapterInfo = c.adapterID
                self.voltage = c.voltage
                self.voltageValue = c.voltageValue
                self.engineReachable = c.engineReachable
                self.dashReachable = c.dashReachable
                self.status = c.dashReachable ? "Dashboard ECU online — ready to reset"
                    : (c.engineReachable ? "Engine ECU online; dash asleep — ignition ON & retry"
                                         : "No ECU response — check ignition / connection")
                self.append("Connectivity: \(c.adapterID) | \(c.voltage) | engine \(c.engineReachable ? "✓" : "✗") | dash \(c.dashReachable ? "✓" : "✗")")
            }
        }
    }

    /// One-click service-indicator reset using the selected model profile.
    func serviceReset() {
        guard let e = elm else { status = "Connect first"; return }
        let profile = effectiveProfile
        resetting = true; busy = true; status = "Resetting service indicator…"
        append("— SERVICE RESET — \(profile.name)")
        io.async { [weak self] in
            let result = e.serviceReset(profile: profile, dryRun: false)
            Task { @MainActor in
                guard let self else { return }
                self.resetting = false; self.busy = false
                self.lastReset = result
                result.transcript.forEach { self.append($0) }
                self.append(result.message)
                self.status = result.success ? "✅ \(result.message)" : "⚠️ \(result.message)"
                // a successful reset proves the dash ECU is reachable
                if result.success { self.dashReachable = true }
            }
        }
    }

    // MARK: - Live data / vehicle info / DTC

    func toggleLive() {
        if polling { polling = false; status = "Live data stopped"; return }
        guard let e = elm else { status = "Connect first"; return }
        polling = true; status = "Live data running…"
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
        guard let e = elm else { status = "Connect first"; return }
        let wasPolling = polling; polling = false   // pause polling during the read
        busy = true; status = "Reading VIN…"
        io.async { [weak self] in
            let vin = e.readVINString()
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.vin = vin
                self.status = vin != nil ? "VIN: \(vin!)" : "VIN read failed (ignition ON?)"
                if let v = vin { self.append("VIN: \(v)") }
                if wasPolling { self.toggleLive() }
            }
        }
    }

    func readDTCs() {
        guard let e = elm else { status = "Connect first"; return }
        let wasPolling = polling; polling = false
        busy = true; status = "Reading fault codes…"
        io.async { [weak self] in
            let codes = e.readDTCs()
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.dtcRead = true; self.dtcs = codes
                self.status = codes.isEmpty ? "No fault codes ✅" : "\(codes.count) fault code(s)"
                self.append("DTCs: \(codes.isEmpty ? "none" : codes.joined(separator: ", "))")
                if wasPolling { self.toggleLive() }
            }
        }
    }

    // MARK: - Reset / replay (advanced)

    func runReset(dryRun: Bool) {
        guard let e = elm else { status = "Connect first"; return }
        let commands = ResetViewModel.parseScript(resetScript)
        guard !commands.isEmpty else { status = "Reset sequence is empty"; return }
        if dryRun {
            append("— DRY RUN — would send \(commands.count) commands:")
            commands.forEach { append("   \($0)") }
            status = "Dry run listed \(commands.count) commands"
            return
        }
        busy = true; status = "Sending reset…"
        io.async { [weak self] in
            for cmd in commands {
                let reply = e.transact(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in self?.append("» \(cmd)   « \(reply)") }
            }
            Task { @MainActor in
                self?.busy = false
                self?.status = "Reset sequence sent — cycle the ignition to confirm"
            }
        }
    }

    func importCapture(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            status = "Could not read \(url.lastPathComponent)"; return
        }
        let cmds = SerialProxy.commandsFromCapture(text)
        guard !cmds.isEmpty else { status = "No APP->ELM commands in that log"; return }
        resetScript = "# Imported from \(url.lastPathComponent)\n" + cmds.joined(separator: "\n")
        status = "Imported \(cmds.count) commands"
    }

    // MARK: - Capture proxy

    func toggleCapture() {
        if capturing { stopCapture() } else { startCapture() }
    }

    private func startCapture() {
        guard !selectedPort.isEmpty else { status = "Pick a serial port first"; return }
        if connected { disconnect() } // the proxy needs exclusive access to the ELM327
        let logPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("melco-capture.log")
        let p = SerialProxy(elmPath: selectedPort, baud: speed_t(baudConst(baud)), logPath: logPath)
        proxy = p
        capturing = true
        status = "Starting capture…"
        append("Capture log: \(logPath)")
        io.async { [weak self] in
            do {
                try p.run(onReady: { slave in
                    Task { @MainActor in
                        self?.virtualPort = slave
                        self?.status = "Point MelcoDiag at: \(slave)"
                        self?.append("Virtual port ready: \(slave)\nIn MelcoDiag, select this port and run ONE reset, then Stop Capture.")
                    }
                }, onLog: { cmd in
                    Task { @MainActor in self?.append("MelcoDiag » \(cmd)") }
                })
            } catch {
                Task { @MainActor in self?.capturing = false; self?.status = "Capture failed: \(error)" }
                return
            }
            // run() returns after shouldStop -> import what we captured
            if let text = try? String(contentsOfFile: logPath, encoding: .utf8) {
                let cmds = SerialProxy.commandsFromCapture(text)
                Task { @MainActor in
                    if !cmds.isEmpty {
                        self?.resetScript = "# Captured from MelcoDiag\n" + cmds.joined(separator: "\n")
                        self?.append("Captured \(cmds.count) commands into the reset sequence.")
                    }
                }
            }
            Task { @MainActor in self?.capturing = false }
        }
    }

    private func stopCapture() {
        proxy?.shouldStop = true
        status = "Stopping capture…"
        virtualPort = ""
    }

    // MARK: - Helpers

    static func parseScript(_ s: String) -> [String] {
        s.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}

func baudConst(_ b: Int) -> UInt {
    switch b {
    case 9600:   return UInt(B9600)
    case 19200:  return UInt(B19200)
    case 38400:  return UInt(B38400)
    case 57600:  return UInt(B57600)
    case 115200: return UInt(B115200)
    default:     return UInt(B38400)
    }
}
