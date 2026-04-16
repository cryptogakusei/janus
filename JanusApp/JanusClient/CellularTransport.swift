import Foundation
import Network
import JanusShared

/// Forces HTTP POST requests onto the cellular interface using `NWConnection`.
///
/// ## Why URLSession isn't enough
/// `URLSessionConfiguration.allowsCellularAccess = true` permits cellular but does NOT
/// override the system default route when WiFi is active. An offline mesh AP (e.g. GL-iNET
/// Opal) has a healthy WiFi signal, so Wi-Fi Assist never triggers, and URLSession silently
/// routes over the dead WiFi link regardless of `allowsCellularAccess`.
///
/// ## The only deterministic solution
/// `NWConnection` with `NWParameters.requiredInterfaceType = .cellular` pins the connection
/// to the cellular modem at the OS networking stack level — bypassing the default route table.
/// This is the only public iOS API that guarantees cellular routing.
///
/// ## Usage
/// `PaymentConnectivityManager.internetTransport` returns a `CellularTransport` instance
/// when the reachability probe finds WiFi has no WAN uplink. Injected into `EthRPC` via
/// `TempoConfig.transport`.
final class CellularTransport: HTTPTransport {

    func post(url: URL, headers: [String: String], body: Data) async throws -> (Data, Int) {
        guard let host = url.host else { throw CellularTransportError.invalidURL }
        let port = UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))

        // TLS + TCP parameters with cellular pinned
        let tlsOptions = NWProtocolTLS.Options()
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        params.requiredInterfaceType = .cellular

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: params
        )

        // Build raw HTTP/1.1 POST request
        // Connection: close tells the server to close after the response, giving us a clean EOF.
        let path = url.path.isEmpty ? "/" : url.path
        let query = url.query.map { "?\($0)" } ?? ""
        var lines = [
            "POST \(path)\(query) HTTP/1.1",
            "Host: \(host)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
        ]
        for (key, value) in headers { lines.append("\(key): \(value)") }
        var requestData = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8)!
        requestData.append(body)

        return try await withCheckedThrowingContinuation { continuation in
            let q = DispatchQueue(label: "com.janus.cellular.transport", qos: .userInitiated)
            var settled = false

            func settle(_ result: Result<(Data, Int), Error>) {
                guard !settled else { return }
                settled = true
                connection.cancel()
                continuation.resume(with: result)
            }

            // Hard 20-second deadline — cellular can be slower than WiFi
            q.asyncAfter(deadline: .now() + 20) {
                settle(.failure(CellularTransportError.timeout))
            }

            connection.stateUpdateHandler = { [requestData] state in
                switch state {
                case .ready:
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if let error = error { settle(.failure(error)); return }
                        Self.readAll(connection: connection) { data in
                            settle(Self.parseHTTPResponse(data))
                        }
                    })
                case .failed(let error):
                    settle(.failure(error))
                case .cancelled:
                    // Only signal cancellation if we haven't settled yet (i.e. this is unexpected)
                    settle(.failure(CellularTransportError.cancelled))
                default:
                    break
                }
            }

            connection.start(queue: q)
        }
    }

    // MARK: - Read helpers

    /// Accumulate all data until the connection reaches EOF (`isComplete = true`).
    /// The server closes after the response because we sent `Connection: close`.
    private static func readAll(connection: NWConnection, completion: @escaping (Data) -> Void) {
        var acc = Data()
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { chunk, _, isComplete, error in
                if let chunk, !chunk.isEmpty { acc.append(chunk) }
                if isComplete || error != nil { completion(acc); return }
                next()
            }
        }
        next()
    }

    // MARK: - HTTP/1.1 response parsing

    private static func parseHTTPResponse(_ data: Data) -> Result<(Data, Int), Error> {
        let headerBodySeparator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let sepRange = data.range(of: headerBodySeparator) else {
            return .failure(CellularTransportError.malformedResponse)
        }
        guard let headerStr = String(data: data[..<sepRange.lowerBound], encoding: .utf8) else {
            return .failure(CellularTransportError.malformedResponse)
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            return .failure(CellularTransportError.malformedResponse)
        }

        var hdrs: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                hdrs[parts[0].lowercased().trimmingCharacters(in: .whitespaces)] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        let rawBody = Data(data[sepRange.upperBound...])
        let body: Data
        if hdrs["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = decodeChunked(rawBody) ?? rawBody
        } else {
            body = rawBody
        }

        return .success((body, statusCode))
    }

    /// Decode HTTP chunked transfer encoding.
    private static func decodeChunked(_ data: Data) -> Data? {
        var result = Data()
        var pos = data.startIndex
        let crlf = Data([0x0D, 0x0A])
        while pos < data.endIndex {
            guard let eol = data[pos...].range(of: crlf) else { break }
            guard let sizeStr = String(data: data[pos..<eol.lowerBound], encoding: .utf8),
                  let chunkSize = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16)
            else { return nil }
            if chunkSize == 0 { break }
            let bodyStart = eol.upperBound
            let bodyEnd = bodyStart + chunkSize
            guard bodyEnd <= data.endIndex else { return nil }
            result.append(data[bodyStart..<bodyEnd])
            pos = min(bodyEnd + 2, data.endIndex) // skip trailing \r\n
        }
        return result
    }
}

// MARK: - Errors

enum CellularTransportError: Error, LocalizedError {
    case invalidURL
    case timeout
    case cancelled
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid RPC URL"
        case .timeout: return "Cellular RPC connection timed out (20s)"
        case .cancelled: return "Cellular connection cancelled unexpectedly"
        case .malformedResponse: return "Malformed HTTP response from RPC server"
        }
    }
}
