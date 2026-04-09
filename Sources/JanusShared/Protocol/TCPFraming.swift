import Foundation

/// Length-prefix framing for TCP streams.
///
/// TCP is a byte stream — it doesn't preserve message boundaries like MPC does.
/// This utility adds a 4-byte big-endian length header before each message so
/// the receiver can reconstruct discrete `Data` frames from the stream.
///
/// Wire format: [4 bytes UInt32 BE length][N bytes payload]
public enum TCPFramer {

    /// Maximum allowed frame size (16 MB). Rejects oversized length headers to prevent OOM.
    public static let maxFrameSize = 16 * 1024 * 1024

    /// Wraps `data` in a length-prefixed frame ready for TCP transmission.
    public static func frame(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(data)
        return framed
    }

    /// Accumulates incoming TCP data and emits complete frames.
    ///
    /// Feed chunks from `NWConnection.receive` into `append(_:)`.
    /// Complete frames are delivered via the `onFrame` callback.
    /// Oversized frames trigger `onError`.
    public class Deframer {
        public var onFrame: ((Data) -> Void)?
        public var onError: ((Error) -> Void)?

        private var buffer = Data()

        public init() {}

        /// Append data received from the TCP stream and emit any complete frames.
        public func append(_ data: Data) {
            buffer.append(data)

            while buffer.count >= 4 {
                let length = buffer.withUnsafeBytes {
                    $0.load(as: UInt32.self).bigEndian
                }
                let frameSize = Int(length)

                if frameSize > TCPFramer.maxFrameSize {
                    onError?(FramingError.oversizedFrame(frameSize))
                    buffer.removeAll()
                    return
                }

                let totalNeeded = 4 + frameSize
                guard buffer.count >= totalNeeded else {
                    break // wait for more data
                }

                let payload = buffer.subdata(in: 4 ..< totalNeeded)
                buffer.removeSubrange(0 ..< totalNeeded)
                onFrame?(payload)
            }
        }

        /// Reset the internal buffer (e.g., on disconnect).
        public func reset() {
            buffer.removeAll()
        }
    }

    public enum FramingError: Error, LocalizedError {
        case oversizedFrame(Int)

        public var errorDescription: String? {
            switch self {
            case .oversizedFrame(let size):
                return "Frame size \(size) exceeds maximum \(TCPFramer.maxFrameSize)"
            }
        }
    }
}
