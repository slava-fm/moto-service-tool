import Foundation

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
    public var hexCompact: String { map { String(format: "%02X", $0) }.joined() }
}

public func bytesFromHex(_ s: String) -> [UInt8] {
    let cleaned = s.uppercased().filter { $0.isHexDigit }
    var out: [UInt8] = []
    var it = cleaned.makeIterator()
    while let hi = it.next(), let lo = it.next() {
        if let b = UInt8("\(hi)\(lo)", radix: 16) { out.append(b) }
    }
    return out
}

public enum ElmError: Error, CustomStringConvertible {
    case adapter(String)          // "NO DATA", "CAN ERROR", "UNABLE TO CONNECT", ...
    case timeout
    case negativeResponse(service: UInt8, nrc: UInt8)
    case empty

    public var description: String {
        switch self {
        case .adapter(let m): return "ELM327 reported: \(m)"
        case .timeout:        return "ELM327 timed out (no '>' prompt). Check baud/port/wiring."
        case .empty:          return "ELM327 returned no usable data"
        case .negativeResponse(let s, let nrc):
            return "ECU rejected service 0x\(String(format: "%02X", s)): \(ElmError.nrcName(nrc)) (0x\(String(format: "%02X", nrc)))"
        }
    }

    public static func nrcName(_ nrc: UInt8) -> String {
        switch nrc {
        case 0x10: return "general reject"
        case 0x11: return "service not supported"
        case 0x12: return "sub-function not supported"
        case 0x13: return "incorrect length/format"
        case 0x22: return "conditions not correct"
        case 0x24: return "request sequence error"
        case 0x31: return "request out of range"
        case 0x33: return "security access denied"
        case 0x35: return "invalid key"
        case 0x36: return "exceeded attempts"
        case 0x37: return "time delay not expired"
        case 0x78: return "response pending"
        case 0x7E: return "sub-function not supported in active session"
        case 0x7F: return "service not supported in active session"
        default:   return "NRC"
        }
    }
}

/// Drives an ELM327 (the same way JPDiag/MelcoDiag do): AT-command setup for
/// HS-CAN, then hex requests with the adapter handling ISO-TP framing.
public final class Elm327 {
    public let port: Transport
    public var verbose = false
    public var currentHeader: UInt32 = 0x7E0
    /// Optional sink for verbose logging (used by the GUI). Defaults to stderr.
    public var logger: ((String) -> Void)?
    /// Optional sink for human-readable progress ("what it's doing now").
    public var onStage: ((String) -> Void)?
    private func stage(_ s: String) { onStage?(s) }

    private static let errorMarkers = [
        "NO DATA", "CAN ERROR", "BUFFER FULL", "UNABLE TO CONNECT",
        "BUS INIT: ERROR", "BUS BUSY", "FB ERROR", "DATA ERROR", "ERROR",
        "STOPPED", "?", "ACT ALERT"
    ]

    public init(port: Transport) { self.port = port }

    private func emit(_ s: String) {
        if let logger { logger(s) } else { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    }

    // MARK: - Low-level transport

    private func writeLine(_ s: String) throws {
        if verbose { emit("  » \(s)") }
        try port.write(Data((s + "\r").utf8))
    }

    private func readUntilPrompt(timeout: TimeInterval) -> String {
        var buf = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let chunk = port.read(timeout: 0.2)
            if let s = String(data: chunk, encoding: .ascii) {
                buf += s
                if buf.contains(">") { break }
            }
        }
        if verbose && !buf.isEmpty {
            emit("  « " + buf.replacingOccurrences(of: "\r", with: "\\r"))
        }
        return buf
    }

    @discardableResult
    public func transact(_ cmd: String, timeout: TimeInterval = 5.0) -> String {
        try? writeLine(cmd)
        return readUntilPrompt(timeout: timeout).replacingOccurrences(of: ">", with: "")
    }

    // MARK: - Setup

    /// JPDiag/MelcoDiag-style init for the Panigale V2 (HS-CAN).
    /// protocolCode "6" = ISO 15765-4 CAN 11-bit/500k.
    public func initialize(protocolCode: String = "6") throws {
        stage("Initializing adapter (ATZ)…")
        try? writeLine("")
        _ = readUntilPrompt(timeout: 0.5)
        _ = transact("ATZ", timeout: 3.0)
        _ = transact("ATE0")
        _ = transact("ATL0")
        _ = transact("ATS1")
        _ = transact("ATH1")
        _ = transact("ATSP\(protocolCode)")
        _ = transact("ATCAF1")
        _ = transact("ATAT1")
        _ = transact("ATST64")
        setHeader(currentHeader)
    }

    public func setHeader(_ id: UInt32) {
        currentHeader = id
        _ = transact(String(format: "ATSH%03X", id))
    }

    public func setReceiveFilter(_ id: UInt32) { _ = transact(String(format: "ATCRA%03X", id)) }
    public func clearReceiveFilter() { _ = transact("ATCRA") }

    // MARK: - UDS over ELM327

    @discardableResult
    public func request(_ payload: [UInt8], header: UInt32? = nil, timeout: TimeInterval = 5.0) throws -> [UInt8] {
        if let h = header, h != currentHeader { setHeader(h) }
        let cmd = payload.map { String(format: "%02X", $0) }.joined()
        let raw = transact(cmd, timeout: timeout)
        let data = try Elm327.parseAssembled(raw)

        if data.first == 0x7F {
            let nrc = data.count > 2 ? data[2] : 0
            if nrc == 0x78 {
                let more = readUntilPrompt(timeout: timeout)
                let again = try Elm327.parseAssembled(more.replacingOccurrences(of: ">", with: ""))
                if again.first == 0x7F {
                    throw ElmError.negativeResponse(service: again.count > 1 ? again[1] : 0,
                                                    nrc: again.count > 2 ? again[2] : 0)
                }
                return again
            }
            throw ElmError.negativeResponse(service: data.count > 1 ? data[1] : 0, nrc: nrc)
        }
        return data
    }

    @discardableResult public func diagnosticSession(_ t: UInt8) throws -> [UInt8] { try request([0x10, t]) }
    @discardableResult public func testerPresent() throws -> [UInt8] { try request([0x3E, 0x00]) }
    @discardableResult public func ecuReset(_ t: UInt8) throws -> [UInt8] { try request([0x11, t]) }
    @discardableResult public func readDataByIdentifier(_ did: UInt16) throws -> [UInt8] {
        try request([0x22, UInt8(did >> 8), UInt8(did & 0xFF)])
    }
    @discardableResult public func writeDataByIdentifier(_ did: UInt16, _ d: [UInt8]) throws -> [UInt8] {
        try request([0x2E, UInt8(did >> 8), UInt8(did & 0xFF)] + d)
    }
    @discardableResult public func routineControl(sub: UInt8, routine: UInt16, data: [UInt8] = []) throws -> [UInt8] {
        try request([0x31, sub, UInt8(routine >> 8), UInt8(routine & 0xFF)] + data)
    }
    @discardableResult public func securityRequestSeed(level: UInt8) throws -> [UInt8] { try request([0x27, level]) }
    @discardableResult public func securitySendKey(level: UInt8, key: [UInt8]) throws -> [UInt8] { try request([0x27, level] + key) }

    // MARK: - Response parsing

    /// Parses an ELM327 reply (ATH1/ATS1, CAF1) into the assembled UDS payload.
    public static func parseAssembled(_ raw: String) throws -> [UInt8] {
        let lines = raw
            .replacingOccurrences(of: "\n", with: "\r")
            .split(separator: "\r")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased() != "SEARCHING..." }

        if lines.isEmpty { throw ElmError.empty }

        for line in lines {
            let up = line.uppercased()
            for marker in errorMarkers where up == marker || up.hasPrefix(marker) {
                throw ElmError.adapter(up)
            }
        }

        if lines.contains(where: { $0.contains(":") }) {
            var ordered: [(Int, [UInt8])] = []
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let idxStr = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                guard let idx = Int(idxStr, radix: 16) else { continue }
                let rest = String(line[line.index(after: colon)...])
                ordered.append((idx, bytesFromHex(rest)))
            }
            let assembled = ordered.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
            if !assembled.isEmpty { return assembled }
        }

        let tokens = lines[0].split(whereSeparator: { $0 == " " }).map(String.init)
        if tokens.count >= 2, tokens[0].count <= 3, Int(tokens[0], radix: 16) != nil {
            return tokens.dropFirst().compactMap { UInt8($0, radix: 16) }
        }
        return bytesFromHex(lines[0])
    }
}

// MARK: - Panigale V2 service reset (confirmed working)

/// Result of the Panigale V2 service-indicator reset, with verification data.
public struct ServiceResetResult {
    public var success: Bool
    public var routineStarted: Bool          // saw 71 09 (StartRoutine ack)
    public var routineResults: Bool          // saw 73    (RequestResults ack)
    public var routineStopped: Bool          // saw 72    (StopRoutine ack)
    public var before91: [UInt8]
    public var after91: [UInt8]
    public var before93: [UInt8]
    public var after93: [UInt8]
    public var recordsChanged: Bool
    public var transcript: [String]
    public var message: String
}

/// A per-model service-reset profile (ECU address + routine id).
public struct ResetProfile: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let header: UInt32     // request CAN ID, e.g. 0x7E3
    public let resp: UInt32       // response CAN ID, e.g. 0x7EB
    public let routine: UInt8     // KWP StartRoutine local id, e.g. 0x09
    public let validated: Bool    // confirmed on a real bike?
    public let note: String

    public init(id: String, name: String, header: UInt32, resp: UInt32,
                routine: UInt8, validated: Bool, note: String) {
        self.id = id; self.name = name; self.header = header; self.resp = resp
        self.routine = routine; self.validated = validated; self.note = note
    }

    /// Built-in profiles. Only the Panigale V2 is validated; others are
    /// candidate routines derived from MelcoDiag and are UNVERIFIED.
    public static let builtIn: [ResetProfile] = [
        .init(id: "panigale-v2", name: "Panigale V2 / 959 (validated)",
              header: 0x7E3, resp: 0x7EB, routine: 0x09, validated: true,
              note: "Confirmed on Panigale V2 (Superquadro, 2020–2024)."),
        .init(id: "monster-scrambler", name: "Monster / Scrambler air-cooled (experimental)",
              header: 0x7E3, resp: 0x7EB, routine: 0x07, validated: false,
              note: "Unverified. May require security access (not included) and can fail safely."),
        .init(id: "testastretta", name: "Hypermotard / SuperSport / Multistrada (experimental)",
              header: 0x7E3, resp: 0x7EB, routine: 0x09, validated: false,
              note: "Unverified candidate for other Testastretta dashboards."),
    ]

    public static func custom(header: UInt32, routine: UInt8) -> ResetProfile {
        .init(id: "custom", name: "Custom",
              header: header, resp: header + 8, routine: routine,
              validated: false, note: "User-specified ECU header and routine.")
    }
}

/// Quick connectivity snapshot for the UI.
public struct Connectivity {
    public var adapterID: String
    public var voltage: String
    public var voltageValue: Double      // parsed volts, 0 if unknown
    public var dashReachable: Bool       // dash ECU 7E3 answered 10 01
    public var engineReachable: Bool     // engine ECU 7E0 answered 10 01
}

extension Elm327 {

    /// Parse one CAF0/ATH0 reply line ("06 5A 91 00 25 08 08") into its UDS
    /// payload (drops the leading ISO-TP PCI length byte). Returns [] on error.
    private func parseFrame(_ raw: String) -> [UInt8] {
        let lines = raw.replacingOccurrences(of: "\n", with: "\r")
            .split(separator: "\r").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.uppercased() != "SEARCHING..." }
        for line in lines {
            let up = line.uppercased()
            if up.contains("NO DATA") || up.contains("ERROR") || up == "?" { return [] }
            let toks = line.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            guard toks.count >= 2 else { continue }
            let pci = Int(toks[0])
            guard pci > 0, pci < toks.count else { return Array(toks.dropFirst()) }
            return Array(toks[1...pci])
        }
        return []
    }

    /// Reads adapter id, battery voltage, and whether the engine/dash ECUs answer.
    public func connectivity() -> Connectivity {
        stage("Reading adapter info & voltage…")
        let id = transact("ATI").trimmingCharacters(in: .whitespacesAndNewlines)
        let rv = transact("ATRV").trimmingCharacters(in: .whitespacesAndNewlines)
        let volts = Double(rv.lowercased().replacingOccurrences(of: "v", with: "")) ?? 0
        _ = transact("ATE0"); _ = transact("ATS1"); _ = transact("ATH0")
        _ = transact("ATSP6"); _ = transact("ATCAF0"); _ = transact("ATAT1")

        func probe(_ tx: String, _ rx: String) -> Bool {
            _ = transact("ATSH\(tx)"); _ = transact("ATCRA\(rx)")
            for _ in 0..<3 {                               // dash ECU may need a wake
                let r = parseFrame(transact("021001"))
                if r.first == 0x50 { return true }
            }
            return false
        }
        stage("Probing engine ECU (7E0)…")
        let engine = probe("7E0", "7E8")
        stage("Probing dashboard ECU (7E3)…")
        let dash = probe("7E3", "7EB")
        return Connectivity(adapterID: id.isEmpty ? "?" : id, voltage: rv,
                            voltageValue: volts, dashReachable: dash, engineReachable: engine)
    }

    /// Convenience: run the validated Panigale V2 profile.
    public func panigaleV2ServiceReset(dryRun: Bool) -> ServiceResetResult {
        serviceReset(profile: ResetProfile.builtIn[0], dryRun: dryRun)
    }

    /// Runs a service-reset routine for the given profile on its dashboard ECU,
    /// reading records 0x91/0x93 before/after to verify. `dryRun` reads only.
    /// The routine triple is StartRoutine(0x31) / RequestResults(0x33) /
    /// StopRoutine(0x32) on the profile's routine id.
    public func serviceReset(profile: ResetProfile, dryRun: Bool) -> ServiceResetResult {
        var log: [String] = []
        @discardableResult func cmd(_ c: String) -> [UInt8] {
            let bytes = parseFrame(transact(c))
            log.append("» \(c)   « \(bytes.isEmpty ? "—" : bytes.hex)")
            return bytes
        }
        let hdr = String(format: "%03X", profile.header)
        let rsp = String(format: "%03X", profile.resp)
        let r = profile.routine
        let startCmd   = String(format: "0431%02X00", r)   // 31 R 00
        let resultsCmd = String(format: "0233%02X", r)     // 33 R
        let stopCmd    = String(format: "0432%02X00", r)   // 32 R 00

        // Manual ISO-TP framing on the dashboard ECU.
        _ = transact("ATE0"); _ = transact("ATL0"); _ = transact("ATS1"); _ = transact("ATH0")
        _ = transact("ATSP6"); _ = transact("ATCAF0"); _ = transact("ATAT1")
        _ = transact("ATSH\(hdr)"); _ = transact("ATCRA\(rsp)")

        // Session (first request also wakes the ECU).
        _ = cmd("021001"); _ = cmd("021001")

        func record(_ x: [UInt8]) -> [UInt8] { x.count >= 2 ? Array(x.dropFirst(2)) : x }
        let before91 = record(cmd("021A91"))
        let before93 = record(cmd("021A93"))

        if dryRun {
            return ServiceResetResult(success: false, routineStarted: false, routineResults: false,
                routineStopped: false, before91: before91, after91: before91,
                before93: before93, after93: before93, recordsChanged: false,
                transcript: log + ["(dry run — no reset sent)"],
                message: "Dry run: read service records only.")
        }

        let r1 = cmd(startCmd)     // StartRoutine  -> expect 71 R
        let r2 = cmd(resultsCmd)   // RequestResults -> expect 73
        let r3 = cmd(stopCmd)      // StopRoutine   -> expect 72
        _ = cmd("023E00")          // TesterPresent

        // Force the "last service" date record (0x91) to today's date. The
        // routine above only re-stamps the date when a service is actually
        // due, so on a not-yet-due bike the displayed date never advances.
        // This explicit write makes it unconditional. KWP WriteDataByLocalId
        // (0x3B) on the dashboard ECU; record layout is BCD: 00 YY MM DD
        // (e.g. 00 26 06 05 = 2026-06-05). Dash ECU only — skipped for custom
        // profiles on other headers.
        var dateAck = false
        var wantDate: [UInt8] = []
        if profile.header == 0x7E3 {
            func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            wantDate = [0x00, bcd((c.year ?? 2000) % 100), bcd(c.month ?? 1), bcd(c.day ?? 1)]
            let payload: [UInt8] = [0x3B, 0x91] + wantDate          // 6 data bytes
            let writeCmd = String(format: "%02X", payload.count)    // ISO-TP PCI length
                + payload.map { String(format: "%02X", $0) }.joined()
            dateAck = cmd(writeCmd).first == 0x7B                    // positive: 7B 91
        }

        let after91 = record(cmd("021A91"))
        let after93 = record(cmd("021A93"))

        let started = r1.first == 0x71
        let results = r2.first == 0x73
        let stopped = r3.first == 0x72
        let dateSet = !wantDate.isEmpty && after91 == wantDate      // read-back proof
        let changed = (after91 != before91) || (after93 != before93)
        let success = started && stopped && (dateSet || changed || results)

        func fmtBCDDate(_ b: [UInt8]) -> String {
            guard b.count == 4 else { return b.hex }
            func dec(_ x: UInt8) -> Int { Int(x >> 4) * 10 + Int(x & 0x0F) }
            return String(format: "20%02d-%02d-%02d", dec(b[1]), dec(b[2]), dec(b[3]))
        }

        let msg: String
        if started && stopped && dateSet {
            msg = "✅ Reset complete — service date set to \(fmtBCDDate(after91)). Cycle the ignition to refresh the dash."
        } else if started && stopped && !wantDate.isEmpty && dateAck {
            msg = "Routine ran and the date write was accepted, but read-back still shows \(fmtBCDDate(after91)). Cycle the ignition and re-check."
        } else if started && stopped && !wantDate.isEmpty {
            msg = "Routine acknowledged, but the dash rejected the date write (no 7B 91). The reset ran; the date may stay at \(fmtBCDDate(after91)). Share the log so the write can be adjusted."
        } else if started && stopped {
            msg = "Routine acknowledged. Records \(changed ? "changed" : "unchanged") — cycle ignition to verify."
        } else if !profile.validated {
            msg = "No acknowledgement — this profile is experimental and may not match your model. Nothing was changed."
        } else {
            msg = "Routine did not acknowledge as expected. Ensure ignition is ON and retry."
        }
        return ServiceResetResult(success: success, routineStarted: started, routineResults: results,
            routineStopped: stopped, before91: before91, after91: after91,
            before93: before93, after93: after93, recordsChanged: changed,
            transcript: log, message: msg)
    }
}

// MARK: - Live data, VIN, fault codes

public struct LiveData {
    public var rpm: Int?
    public var coolantC: Int?
    public var intakeC: Int?
    public var speedKmh: Int?
    public var throttlePct: Int?
    public var loadPct: Int?
    public var batteryV: Double?
    public init() {}
}

extension Elm327 {
    /// Put the adapter in OBD-II Mode-01 mode on the engine ECU (7E0).
    public func obdBegin() {
        _ = transact("ATE0"); _ = transact("ATL0"); _ = transact("ATS1"); _ = transact("ATH0")
        _ = transact("ATSP6"); _ = transact("ATCAF1"); _ = transact("ATAT1")
        _ = transact("ATSH7E0"); _ = transact("ATCRA7E8")
    }

    private func hexTokens(_ raw: String) -> [UInt8] {
        raw.split(whereSeparator: { " \r\n>".contains($0) }).compactMap { UInt8($0, radix: 16) }
    }

    /// Reads one OBD Mode-01 PID; returns the data bytes after "41 <pid>".
    private func obdPID(_ pid: UInt8) -> [UInt8] {
        let toks = hexTokens(transact(String(format: "01%02X", pid)))
        if let i = toks.firstIndex(of: 0x41), i + 1 < toks.count, toks[i+1] == pid {
            return Array(toks[(i+2)...])
        }
        return []
    }

    /// Snapshot of the common live parameters (engine ECU must be in OBD mode).
    public func readLive() -> LiveData {
        var d = LiveData()
        let rpm = obdPID(0x0C); if rpm.count >= 2 { d.rpm = (Int(rpm[0]) << 8 | Int(rpm[1])) / 4 }
        if let a = obdPID(0x05).first { d.coolantC = Int(a) - 40 }
        if let a = obdPID(0x0F).first { d.intakeC = Int(a) - 40 }
        if let a = obdPID(0x0D).first { d.speedKmh = Int(a) }
        if let a = obdPID(0x11).first { d.throttlePct = Int(a) * 100 / 255 }
        if let a = obdPID(0x04).first { d.loadPct = Int(a) * 100 / 255 }
        let rv = transact("ATRV").lowercased().filter { "0123456789.".contains($0) }
        d.batteryV = Double(rv)
        return d
    }

    /// Reads the VIN (UDS 22 F190 on the engine ECU). Needs a diagnostic session.
    public func readVINString() -> String? {
        _ = transact("ATH0"); _ = transact("ATCAF1")
        _ = transact("ATSH7E0"); _ = transact("ATCRA7E8")
        _ = transact("1001")
        let bytes = (try? Elm327.parseAssembled(transact("22F190"))) ?? []
        guard bytes.count >= 4, bytes[0] == 0x62 else { return nil }
        let vin = String(bytes: Array(bytes.dropFirst(3)).prefix(17), encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        return (vin?.isEmpty == false) ? vin : nil
    }

    /// Reads stored diagnostic trouble codes (OBD Mode 03).
    public func readDTCs() -> [String] {
        obdBegin()
        let toks = hexTokens(transact("03"))
        guard let i = toks.firstIndex(of: 0x43) else { return [] }
        var rest = Array(toks[(i+1)...])
        if rest.count % 2 == 1 { rest = Array(rest.dropFirst()) }   // drop count byte if present
        var codes: [String] = []
        var k = 0
        let letters = ["P", "C", "B", "U"]
        while k + 1 < rest.count {
            let a = rest[k], b = rest[k+1]; k += 2
            if a == 0 && b == 0 { continue }
            codes.append("\(letters[Int(a >> 6)])\((a >> 4) & 0x3)" + String(format: "%X%02X", a & 0x0F, b))
        }
        return codes
    }
}
