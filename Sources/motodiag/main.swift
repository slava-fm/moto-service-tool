import Foundation
import DucatiResetKit
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Tiny argument parser

struct Args {
    private var flags: [String: String] = [:]
    private var bools: Set<String> = []
    let positional: [String]

    init(_ argv: [String]) {
        var pos: [String] = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") {
                    flags[key] = argv[i + 1]; i += 2
                } else {
                    bools.insert(key); i += 1
                }
            } else {
                pos.append(a); i += 1
            }
        }
        positional = pos
    }

    func string(_ key: String, _ def: String? = nil) -> String? { flags[key] ?? def }
    func bool(_ key: String) -> Bool { bools.contains(key) }
    func int(_ key: String, _ def: Int) -> Int {
        guard let v = flags[key] else { return def }
        if v.hasPrefix("0x") { return Int(v.dropFirst(2), radix: 16) ?? def }
        return Int(v) ?? def
    }
    func hexId(_ key: String, _ def: UInt32) -> UInt32 {
        guard let v = flags[key] else { return def }
        let s = v.hasPrefix("0x") ? String(v.dropFirst(2)) : v
        return UInt32(s, radix: 16) ?? def
    }
}

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func resolvePort(_ args: Args) -> String {
    if let p = args.string("port") { return p }
    let ports = SerialPort.availablePorts()
    if ports.count == 1 { return ports[0] }
    if ports.isEmpty {
        die("no USB-serial adapter found. Plug in the ELM327 and run `motodiag ports`, or pass --port /dev/cu.usbserial-XXXX")
    }
    die("multiple serial ports found; pick one with --port:\n  " + ports.joined(separator: "\n  "))
}

func baudConstant(_ b: Int) -> speed_t {
    switch b {
    case 9600:   return speed_t(B9600)
    case 19200:  return speed_t(B19200)
    case 38400:  return speed_t(B38400)
    case 57600:  return speed_t(B57600)
    case 115200: return speed_t(B115200)
    default:     return speed_t(B38400)
    }
}

/// Opens the serial port + ELM327. Runs the HS-CAN init unless `initialize`
/// is false (replay supplies its own AT setup).
func openElm(_ args: Args, initialize: Bool = true) -> (SerialPort, Elm327) {
    let path = resolvePort(args)
    let baud = args.int("baud", 38400)
    let proto = args.string("protocol", "6")!
    let port = SerialPort(path: path)
    do { try port.open(baud: baudConstant(baud)) } catch { die("\(error)") }
    let elm = Elm327(port: port)
    elm.verbose = args.bool("verbose")
    elm.currentHeader = args.hexId("tx", 0x7E0)
    if initialize {
        do { try elm.initialize(protocolCode: proto) } catch { die("\(error)") }
    }
    return (port, elm)
}

// MARK: - Commands

func cmdPorts() {
    let ports = SerialPort.availablePorts()
    if ports.isEmpty {
        print("No USB-serial adapters detected under /dev.")
        print("Plug in the ELM327, wait a second, re-run. Expected: /dev/cu.usbserial-XXXX")
        print("(Bluetooth ELM327: pair it first; it appears as /dev/cu.<name>.)")
    } else {
        print("Detected serial ports:")
        ports.forEach { print("  \($0)") }
    }
}

/// Connectivity check: identify the adapter and the active protocol.
func cmdTest(_ args: Args) {
    let (port, elm) = openElm(args); defer { port.close() }
    let id = elm.transact("ATI").trimmingCharacters(in: .whitespacesAndNewlines)
    let proto = elm.transact("ATDP").trimmingCharacters(in: .whitespacesAndNewlines)
    let volts = elm.transact("ATRV").trimmingCharacters(in: .whitespacesAndNewlines)
    print("Adapter : \(id)")
    print("Protocol: \(proto)")
    print("Voltage : \(volts)")
    print("Header  : \(String(format: "%03X", elm.currentHeader))")
    print("\nLooks alive. Try `scan` (ignition on) to find responding ECUs.")
}

/// Read-only bus monitor via ELM327 'AT MA'.
func cmdMonitor(_ args: Args) {
    let (port, _) = openElm(args); defer { port.close() }
    print("Monitoring all CAN traffic (ATMA). Ignition ON. Ctrl-C to stop.\n")
    try? port.write(Data("ATMA\r".utf8))
    while true {
        let chunk = port.read(timeout: 0.3)
        if !chunk.isEmpty, let s = String(data: chunk, encoding: .ascii) {
            FileHandle.standardOutput.write(Data(s.utf8))
        }
    }
}

/// Probe standard OBD headers for responding ECUs.
func cmdScan(_ args: Args) {
    let (port, elm) = openElm(args); defer { port.close() }
    print("Scanning headers 7E0..7E7 for UDS responders...\n")
    var found = 0
    for ecu in 0...7 {
        let tx = UInt32(0x7E0 + ecu)
        elm.setHeader(tx)
        do {
            let r = try elm.request([0x10, 0x01], timeout: 1.5)  // default session
            print(String(format: "  header 0x%03X -> response: %@", tx, r.hex as NSString))
            found += 1
        } catch ElmError.adapter, ElmError.empty, ElmError.timeout {
            continue
        } catch {
            print(String(format: "  header 0x%03X -> present (%@)", tx, "\(error)" as NSString))
            found += 1
        }
    }
    if found == 0 {
        print("No ECU answered standard headers.")
        print("Try `monitor` to learn the bike's real IDs, or --protocol 7 (29-bit) /")
        print("a different --protocol. Ensure ignition is ON.")
    } else {
        print("\nUse the responding header as --tx for `read`/`reset`.")
    }
}

/// Send one UDS request: `read --uds 22F190`.
func cmdRead(_ args: Args) {
    guard let udsStr = args.string("uds") else { die("pass --uds with hex, e.g. --uds 22F190") }
    let (port, elm) = openElm(args); defer { port.close() }
    do {
        let r = try elm.request(bytesFromHex(udsStr))
        print("Response: \(r.hex)")
    } catch { die("\(error)") }
}

/// Send a raw ELM327 command verbatim: `send --cmd ATRV` or `send --cmd 1003`.
func cmdSend(_ args: Args) {
    guard let cmd = args.string("cmd") else { die("pass --cmd with an ELM command, e.g. --cmd 1003 or --cmd ATI") }
    let (port, elm) = openElm(args); defer { port.close() }
    let reply = elm.transact(cmd)
    print(reply.trimmingCharacters(in: .whitespacesAndNewlines))
}

/// Capture MelcoDiag/JPDiag traffic through a PTY proxy.
func cmdCapture(_ args: Args) {
    let path = resolvePort(args)
    let baud = args.int("baud", 38400)
    let logPath = args.string("file", "melcodiag-capture.log")!
    let proxy = SerialProxy(elmPath: path, baud: baudConstant(baud), logPath: logPath)

    signal(SIGINT) { _ in
        FileHandle.standardError.write(Data("\nstopping proxy...\n".utf8)); exit(0)
    }

    do {
        try proxy.run(onReady: { slave in
            // Emit machine-readable path to stderr (unbuffered) for scripting.
            FileHandle.standardError.write(Data("VPORT=\(slave)\n".utf8))
            print("""
            Serial proxy running.
              • Physical ELM327 : \(path)
              • Virtual port    : \(slave)
              • Capture log     : \(logPath)

            In MelcoDiag/JPDiag (or any diag tool), select serial port:  \(slave)
            Perform ONE service reset, then Ctrl-C here. Then replay with:
              motodiag replay --file \(logPath) --from-capture --yes

            Forwarding... (Ctrl-C to stop)
            """)
        }, onLog: { cmd in
            FileHandle.standardError.write(Data(cmd.utf8))
        })
    } catch { die("\(error)") }
}

/// Replay captured ELM327 commands (a script, or a proxy capture log).
func cmdReplay(_ args: Args) {
    guard let file = args.string("file") else { die("pass --file <script-or-capture>") }
    guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
        die("could not read \(file)")
    }

    var commands: [String] = []
    if args.bool("from-capture") {
        // Extract APP->ELM command text between |...| markers, split on \r.
        for line in text.split(separator: "\n") where line.contains("[APP->ELM]") {
            guard let start = line.firstIndex(of: "|") else { continue }
            let after = line[line.index(after: start)...]
            guard let end = after.firstIndex(of: "|") else { continue }
            let payload = String(after[after.startIndex..<end])
            for cmd in payload.components(separatedBy: "\\r") where !cmd.isEmpty {
                commands.append(cmd)
            }
        }
    } else {
        commands = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    guard !commands.isEmpty else { die("no commands found in \(file)") }

    if !args.bool("yes") {
        print("Dry run — would send \(commands.count) commands:")
        commands.forEach { print("  \($0)") }
        print("\nPass --yes to actually transmit.")
        return
    }

    // The script/capture is authoritative (it includes its own AT setup), so
    // don't run our init first — just open the port and send verbatim.
    let (port, elm) = openElm(args, initialize: false); defer { port.close() }
    print("Replaying \(commands.count) commands to the ECU...\n")
    for cmd in commands {
        let reply = elm.transact(cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        print("  \(cmd)  ->  \(reply)")
    }
    print("\nDone. Cycle the ignition and check the service indicator.")
}

/// Run the service-reset sequence (MelcoDiag-style; guarded by --yes).
func cmdReset(_ args: Args) {
    let (port, elm) = openElm(args); defer { port.close() }
    let session = UInt8(args.int("session", 0x03))
    let method = args.string("method", "routine")!

    print("=== Ducati Panigale V2 service-indicator reset (HS-CAN) ===")
    print("Header TX 0x\(String(format: "%03X", elm.currentHeader)) | session 0x\(String(format: "%02X", session))\n")

    func step(_ name: String, _ work: () throws -> [UInt8]) {
        FileHandle.standardError.write(Data("• \(name)\n".utf8))
        do { _ = try work() }
        catch { die("\(name) failed: \(error)\nTip: run `scan` to confirm the header, or `capture` MelcoDiag to learn the exact sequence.") }
    }

    step("DiagnosticSessionControl 0x\(String(format: "%02X", session))") { try elm.diagnosticSession(session) }
    step("TesterPresent") { try elm.testerPresent() }

    if let key = args.string("key") {
        let level = UInt8(args.int("seclevel", 0x01))
        step("SecurityAccess requestSeed (0x\(String(format: "%02X", level)))") {
            let seed = try elm.securityRequestSeed(level: level)
            FileHandle.standardError.write(Data("    seed: \(Array(seed.dropFirst(2)).hex)\n".utf8))
            return seed
        }
        step("SecurityAccess sendKey") { try elm.securitySendKey(level: level + 1, key: bytesFromHex(key)) }
    }

    if !args.bool("yes") {
        print("\nDry run complete — diagnostic session opened OK, no reset sent.")
        print("Provide the reset and add --yes, e.g.:")
        print("  --method raw  --uds \"31 01 FF 00\"          (RoutineControl)")
        print("  --method wdbi --did 0x2F01 --data \"00 00\"  (WriteDataByIdentifier)")
        print("\nDon't know the exact bytes? Capture them from MelcoDiag:")
        print("  motodiag capture --file melco.log     (run a reset in MelcoDiag)")
        print("  motodiag replay  --file melco.log --from-capture --yes")
        return
    }

    switch method {
    case "routine":
        let routine = UInt16(args.hexId("routine", 0xFF00) & 0xFFFF)
        let sub = UInt8(args.int("sub", 0x01))
        step("RoutineControl 0x\(String(format: "%04X", routine))") {
            try elm.routineControl(sub: sub, routine: routine, data: bytesFromHex(args.string("data") ?? ""))
        }
    case "wdbi":
        let did = UInt16(args.hexId("did", 0x2F01) & 0xFFFF)
        step("WriteDataByIdentifier 0x\(String(format: "%04X", did))") {
            try elm.writeDataByIdentifier(did, bytesFromHex(args.string("data") ?? ""))
        }
    case "raw":
        guard let u = args.string("uds") else { die("method raw needs --uds \"<hex>\"") }
        step("Raw UDS \(bytesFromHex(u).hex)") { try elm.request(bytesFromHex(u)) }
    default:
        die("unknown --method \(method) (routine|wdbi|raw)")
    }

    print("\n✅ Reset sequence sent and acknowledged. Cycle the ignition to confirm.")
}

// MARK: - Usage

func usage() {
    print("""
    motodiag — Panigale V2 service reset & diagnostics (macOS / Apple Silicon, ELM327)
    Created by V-twin Fanatics.

    USE AT YOUR OWN RISK. The author takes no responsibility for any damage.
    Provided AS IS, no warranty. Not affiliated with Ducati. For a bike you own.

    USAGE
      motodiag <command> [options]

    COMMANDS
      ports                 List USB-serial adapters
      test                  Connect, show adapter id / protocol / voltage
      monitor               Read-only bus monitor (ATMA)
      scan                  Probe headers 7E0..7E7 for responding ECUs
      read   --uds <hex>    Send one UDS request, print reply (ELM does ISO-TP)
      send   --cmd <text>   Send a raw ELM327 command (e.g. ATRV, 1003)
      capture               Proxy MelcoDiag<->ELM327 and log the exact bytes
      replay --file <f>     Replay captured/scripted commands (--yes to send)
      reset  [--yes]        Service-reset sequence (dry-run without --yes)

    COMMON OPTIONS
      --port <dev>      Serial device (auto if only one)
      --baud <n>        38400 (default, MelcoDiag) | 115200 | ...
      --protocol <n>    ELM protocol: 6 = HS-CAN 11b/500k (default), 7 = 29b/500k
      --tx <hex>        Request header / CAN ID (default 7E0)
      --verbose         Log every ELM command and reply

    RESET / REPLAY OPTIONS
      --session <hex>   Diagnostic session (default 03)
      --method <m>      routine | wdbi | raw  (default routine)
      --routine <hex>   RoutineControl id      --sub <hex>  sub-function (01)
      --did <hex>       Data identifier (wdbi)
      --uds <hex>       Full request bytes (raw)
      --data <hex>      Payload for the chosen method
      --key <hex>       SecurityAccess key (enables seed->key)  --seclevel <hex>
      --from-capture    Parse a `capture` log instead of a plain script
      --yes             Actually transmit (otherwise dry-run)

    TYPICAL FLOW
      motodiag ports
      motodiag test
      motodiag scan
      # learn the exact reset MelcoDiag uses:
      motodiag capture --file melco.log      # do ONE reset in MelcoDiag
      motodiag replay  --file melco.log --from-capture        # dry run
      motodiag replay  --file melco.log --from-capture --yes  # do it

    See README.md for wiring, the Melco ECU notes, and the capture workflow.
    """)
}

// MARK: - Dispatch

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else { usage(); exit(0) }
let args = Args(Array(argv.dropFirst()))

switch command {
case "ports":               cmdPorts()
case "test", "init":        cmdTest(args)
case "monitor", "sniff":    cmdMonitor(args)
case "scan":                cmdScan(args)
case "read":                cmdRead(args)
case "send":                cmdSend(args)
case "capture", "proxy":    cmdCapture(args)
case "replay":              cmdReplay(args)
case "reset":               cmdReset(args)
case "help", "-h", "--help": usage()
default:
    FileHandle.standardError.write(Data("unknown command: \(command)\n\n".utf8))
    usage(); exit(1)
}
