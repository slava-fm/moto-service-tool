import Foundation

/// A byte transport the ELM327 driver can talk over (serial on macOS,
/// Bluetooth-LE on macOS/iOS). Cross-platform.
public protocol Transport: AnyObject {
    func write(_ data: Data) throws
    func read(timeout: TimeInterval) -> Data
    func close()
}

public enum TransportError: Error, CustomStringConvertible {
    case notOpen
    case openFailed(String)

    public var description: String {
        switch self {
        case .notOpen:           return "Transport is not open"
        case .openFailed(let m): return "Could not open transport: \(m)"
        }
    }
}
