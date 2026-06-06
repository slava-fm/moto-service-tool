import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A man-in-the-middle between MelcoDiag/JPDiag (or any serial diag tool) and
/// the real ELM327. Opens a pseudo-terminal (PTY); point the other tool's
/// serial port at the printed slave path. Every byte is forwarded and logged
/// with direction + hex + ASCII, so you can capture the exact service-reset
/// sequence — then replay it natively.
public final class SerialProxy {
    public let elmPath: String
    public let baud: speed_t
    public let logURL: URL
    /// Set true from another thread to stop the forwarding loop.
    public var shouldStop = false

    public init(elmPath: String, baud: speed_t, logPath: String) {
        self.elmPath = elmPath
        self.baud = baud
        self.logURL = URL(fileURLWithPath: logPath)
    }

    /// Runs the forwarding loop until `shouldStop` is set or an error occurs.
    /// `onReady` is called once with the virtual serial port path.
    /// `onLog` receives human-readable traffic lines.
    public func run(onReady: ((String) -> Void)? = nil,
                    onLog: ((String) -> Void)? = nil) throws {
        // Writing to the PTY master after the slave (Wine) closes raises SIGPIPE,
        // which would kill the process. Ignore it so the proxy survives MelcoDiag
        // restarts and stays the stable owner of the real adapter.
        signal(SIGPIPE, SIG_IGN)

        let elm = SerialPort(path: elmPath)
        try elm.open(baud: baud)
        let elmFD = elm.rawFD
        guard elmFD >= 0 else { throw SerialError.notOpen }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw SerialError.openFailed(String(cString: strerror(errno))) }
        guard grantpt(master) == 0, unlockpt(master) == 0,
              let slaveCStr = ptsname(master) else {
            Darwin.close(master)
            throw SerialError.configFailed("could not set up pty")
        }
        let slavePath = String(cString: slaveCStr)

        var t = termios()
        if tcgetattr(master, &t) == 0 { cfmakeraw(&t); tcsetattr(master, TCSANOW, &t) }
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }

        onReady?(slavePath)

        var fds = [pollfd(fd: master, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: elmFD,  events: Int16(POLLIN), revents: 0)]
        var buf = [UInt8](repeating: 0, count: 4096)

        while !shouldStop {
            let r = poll(&fds, 2, 500)
            if r < 0 { if errno == EINTR { continue }; break }
            if r == 0 { continue }

            // POLLHUP/POLLNVAL on the master = the slave (Wine) closed the port.
            // Don't busy-spin; wait for the next slave to open it.
            if fds[0].revents & Int16(POLLHUP | POLLNVAL) != 0 {
                usleep(100_000)
            }
            if fds[0].revents & Int16(POLLIN) != 0 {
                let n = Darwin.read(master, &buf, buf.count)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    _ = try? elm.writeRaw(data)
                    logLine(log, dir: "APP->ELM", data: data, onLog: onLog)
                }
            }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = Darwin.read(elmFD, &buf, buf.count)
                if n > 0 {
                    let data = Data(buf[0..<n])
                    _ = Darwin.write(master, buf, n)
                    logLine(log, dir: "ELM->APP", data: data, onLog: onLog)
                }
            }
        }
        Darwin.close(master)
        elm.close()
    }

    private func logLine(_ fh: FileHandle, dir: String, data: Data, onLog: ((String) -> Void)?) {
        let ascii = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let bytes = [UInt8](data)
        fh.write(Data("[\(dir)] \(bytes.hex)   |\(ascii)|\n".utf8))
        if dir == "APP->ELM" { onLog?(ascii) }
    }

    /// Extracts the APP->ELM command lines from a capture log into a replayable
    /// list of ELM327 commands.
    public static func commandsFromCapture(_ text: String) -> [String] {
        var commands: [String] = []
        for line in text.split(separator: "\n") where line.contains("[APP->ELM]") {
            guard let start = line.firstIndex(of: "|") else { continue }
            let after = line[line.index(after: start)...]
            guard let end = after.firstIndex(of: "|") else { continue }
            let payload = String(after[after.startIndex..<end])
            for cmd in payload.components(separatedBy: "\\r") where !cmd.isEmpty {
                commands.append(cmd)
            }
        }
        return commands
    }
}
