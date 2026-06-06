import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SerialError: Error, CustomStringConvertible {
    case openFailed(String)
    case configFailed(String)
    case writeFailed(String)
    case notOpen

    public var description: String {
        switch self {
        case .openFailed(let m):   return "Could not open serial port: \(m)"
        case .configFailed(let m): return "Could not configure serial port: \(m)"
        case .writeFailed(let m):  return "Serial write failed: \(m)"
        case .notOpen:             return "Serial port is not open"
        }
    }
}

/// Thin POSIX wrapper around a USB-CDC serial device (e.g. an FTDI ELM327
/// presenting as /dev/cu.usbserial-XXXX). No third-party dependencies.
public final class SerialPort {
    private var fd: Int32 = -1
    public let path: String

    public init(path: String) { self.path = path }

    public var isOpen: Bool { fd >= 0 }

    /// Raw file descriptor, for use with poll()-based proxies. -1 if closed.
    public var rawFD: Int32 { fd }

    public func writeRaw(_ data: Data) throws { try write(data) }

    public func open(baud: speed_t = speed_t(B38400)) throws {
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw SerialError.openFailed(String(cString: strerror(errno)))
        }
        fd = handle

        var settings = termios()
        guard tcgetattr(fd, &settings) == 0 else {
            let m = String(cString: strerror(errno)); close()
            throw SerialError.configFailed(m)
        }

        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
        cfsetispeed(&settings, baud)
        cfsetospeed(&settings, baud)

        guard tcsetattr(fd, TCSANOW, &settings) == 0 else {
            let m = String(cString: strerror(errno)); close()
            throw SerialError.configFailed(m)
        }

        tcflush(fd, TCIOFLUSH)
    }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    public func write(_ data: Data) throws {
        guard fd >= 0 else { throw SerialError.notOpen }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var ptr = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EAGAIN || errno == EINTR { usleep(1000); continue }
                    throw SerialError.writeFailed(String(cString: strerror(errno)))
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }

    /// Reads whatever is available, waiting up to `timeout` seconds for the
    /// first byte. Returns empty Data on timeout.
    public func read(timeout: TimeInterval) -> Data {
        guard fd >= 0 else { return Data() }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ms = Int32(max(0, timeout * 1000))
        let r = poll(&pfd, 1, ms)
        if r <= 0 { return Data() }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { return Data() }
        return Data(buf[0..<n])
    }

    deinit { close() }

    /// Best-effort enumeration of likely USB-serial adapters.
    public static func availablePorts() -> [String] {
        let dev = "/dev"
        let prefixes = ["cu.usbserial", "cu.usbmodem", "cu.SLAB", "cu.wchusbserial",
                        "cu.Bluetooth", "tty.usbserial"]
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dev) else { return [] }
        return entries
            .filter { name in prefixes.contains { name.hasPrefix($0) } }
            .map { "\(dev)/\($0)" }
            .sorted()
    }
}
