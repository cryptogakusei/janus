import Foundation
import Network
import JanusShared

/// Monitors network interfaces to determine which has real internet access,
/// and vends a URLSession routed over that interface.
///
/// ## The core problem
/// `NWPathMonitor` reports WiFi as `.satisfied` even when the AP has no WAN
/// uplink (e.g. an offline mesh router). An active HTTP probe to the RPC
/// endpoint is the only reliable way to distinguish "WiFi with internet"
/// from "WiFi without WAN".
///
/// ## Usage
/// - Owned by `ClientEngine`. Call `startMonitoring()` on init.
/// - `internetSession` returns the URLSession to use for all blockchain RPC calls.
/// - `enqueuePaymentOperation` stores a closure that runs when internet returns.
///
/// ## Inference traffic is unaffected
/// This class only manages payment/blockchain connections. Inference connections
/// are pinned to WiFi in `BonjourBrowser` and are architecturally separate.
@MainActor
final class PaymentConnectivityManager: ObservableObject {

    // MARK: - Reachability

    enum InternetReachability: Equatable {
        /// NWPath just changed — active probe in flight. Operation queue holds.
        case probing
        /// WiFi has a live internet path (probe succeeded).
        case wifiWithInternet
        /// WiFi has no WAN uplink; cellular has internet.
        case cellularOnly
        /// Neither interface has internet.
        case unavailable
    }

    @Published private(set) var internetReachability: InternetReachability = .probing

    // MARK: - Sessions

    /// The URLSession to use for payment/blockchain RPC calls.
    /// Routes over whichever interface has confirmed internet access.
    var internetSession: URLSession {
        switch internetReachability {
        case .wifiWithInternet:
            return wifiSession
        case .cellularOnly, .probing, .unavailable:
            return cellularSession
        }
    }

    // MARK: - Transport

    /// The HTTP transport to use for payment/blockchain RPC calls.
    ///
    /// Returns a `URLSessionTransport` when WiFi has confirmed internet access.
    /// Returns a `CellularTransport` otherwise — this uses `NWConnection` with
    /// `requiredInterfaceType = .cellular`, which is the only public iOS API
    /// that deterministically pins traffic to the cellular modem regardless of
    /// which interface the system is currently routing through.
    var internetTransport: any HTTPTransport {
        switch internetReachability {
        case .wifiWithInternet:
            return URLSessionTransport(session: wifiSession)
        case .cellularOnly, .probing, .unavailable:
            return CellularTransport()
        }
    }

    /// WiFi-pinned session — used only for the active probe.
    /// Short timeout: we want fast fallback to cellular.
    private lazy var wifiProbeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.allowsExpensiveNetworkAccess = false
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 4
        return URLSession(configuration: config)
    }()

    /// WiFi session for RPC calls when WiFi has confirmed internet.
    private lazy var wifiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    /// Cellular-capable session — used when WiFi has no WAN.
    ///
    /// We cannot force iOS to route over cellular using URLSessionConfiguration alone
    /// (there is no "require cellular" equivalent of allowsCellularAccess = false).
    /// However: the probe failure above signals iOS Wi-Fi Assist that this WiFi has
    /// no internet, which causes iOS to transparently route subsequent URLSession
    /// requests over cellular when `allowsCellularAccess = true`. Short timeouts
    /// ensure any residual WiFi attempts fail fast.
    private lazy var cellularSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    // MARK: - Monitor

    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.janus.connectivity", qos: .utility)

    // MARK: - Probe tasks

    private var probeTask: Task<Void, Never>?
    private var periodicProbeTask: Task<Void, Never>?

    // MARK: - Operation queue

    private struct PendingOperation {
        let id: UUID
        let label: String
        let op: @Sendable () async -> Void
    }

    private var pendingOperations: [PendingOperation] = []
    private let maxQueueDepth = 20

    // MARK: - Lifecycle

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func stopMonitoring() {
        monitor.cancel()
        probeTask?.cancel()
        periodicProbeTask?.cancel()
    }

    // MARK: - Enqueue

    /// Queue a blockchain operation to run when internet is next available.
    ///
    /// Operations are executed serially in the order they were enqueued.
    /// The queue depth is capped at `maxQueueDepth` to prevent unbounded growth.
    func enqueuePaymentOperation(label: String, _ op: @escaping @Sendable () async -> Void) {
        guard pendingOperations.count < maxQueueDepth else {
            print("[PaymentConnectivity] Queue full (\(maxQueueDepth)), dropping: \(label)")
            return
        }
        pendingOperations.append(PendingOperation(id: UUID(), label: label, op: op))
        print("[PaymentConnectivity] Queued '\(label)' (depth: \(pendingOperations.count))")

        // If internet is already available, flush immediately
        if internetReachability == .wifiWithInternet || internetReachability == .cellularOnly {
            flushQueue()
        }
    }

    // MARK: - Path update handling

    private func handlePathUpdate(_ path: NWPath) {
        // Cancel any in-flight probe — path changed, start fresh
        probeTask?.cancel()
        periodicProbeTask?.cancel()

        guard path.status == .satisfied else {
            internetReachability = .unavailable
            print("[PaymentConnectivity] No network path")
            return
        }

        internetReachability = .probing
        // Use availableInterfaces — not usesInterfaceType(.cellular) — because
        // usesInterfaceType returns false when WiFi is the active path even if
        // cellular is present on the device.
        let hasCellular = path.availableInterfaces.contains { $0.type == .cellular }
        probeTask = Task { @MainActor in
            await probe(hasCellular: hasCellular)
            startPeriodicProbe(hasCellular: hasCellular)
        }
    }

    // MARK: - Active probe

    /// Re-probe every 30 seconds to detect WAN restoration on an offline mesh.
    private func startPeriodicProbe(hasCellular: Bool) {
        periodicProbeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }
                if internetReachability != .wifiWithInternet {
                    await probe(hasCellular: hasCellular)
                }
            }
        }
    }

    /// Fire an `eth_blockNumber` call over WiFi-only. Success = WiFi has WAN.
    /// Failure (timeout / network error) = WiFi has no WAN → fall back to cellular.
    private func probe(hasCellular: Bool) async {
        guard let rpcURL = TempoConfig.testnet.rpcURL else {
            internetReachability = hasCellular ? .cellularOnly : .unavailable
            return
        }

        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "eth_blockNumber", "params": [] as [Any]
        ])
        request.timeoutInterval = 4

        do {
            let (_, response) = try await wifiProbeSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                fallbackToCellular(hasCellular: hasCellular)
                return
            }
            internetReachability = .wifiWithInternet
            print("[PaymentConnectivity] Probe succeeded — WiFi has internet")
            flushQueue()
        } catch {
            // WiFi has no WAN uplink (timeout, NXDOMAIN, ECONNREFUSED, etc.)
            fallbackToCellular(hasCellular: hasCellular)
        }
    }

    private func fallbackToCellular(hasCellular: Bool) {
        if hasCellular {
            internetReachability = .cellularOnly
            print("[PaymentConnectivity] WiFi offline, routing payments over cellular")
            flushQueue()
        } else {
            internetReachability = .unavailable
            print("[PaymentConnectivity] No internet on any interface")
        }
    }

    // MARK: - Queue flush

    private func flushQueue() {
        guard !pendingOperations.isEmpty else { return }
        let ops = pendingOperations
        pendingOperations = []
        print("[PaymentConnectivity] Flushing \(ops.count) queued operation(s)")
        Task {
            for item in ops {   // serial — not concurrent
                print("[PaymentConnectivity] Executing: \(item.label)")
                await item.op()
            }
        }
    }
}
