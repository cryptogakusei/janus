import Foundation

/// Errors from the Multipeer Connectivity transport layer.
public enum MPCError: Error, LocalizedError {
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to a peer."
        }
    }
}
