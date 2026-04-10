import Foundation

/// A single history entry for display in the client UI.
public struct HistoryEntry: Codable, Sendable {
    public let task: TaskType
    public let prompt: String
    public let response: InferenceResponse

    public init(task: TaskType, prompt: String, response: InferenceResponse) {
        self.task = task
        self.prompt = prompt
        self.response = response
    }
}

/// Persisted client session state — everything needed to resume after app restart.
public struct PersistedClientSession: Codable, Sendable {
    public let privateKeyBase64: String
    public let sessionGrant: SessionGrant
    public var spendState: SpendState
    public var receipts: [Receipt]
    public var history: [HistoryEntry]
    /// Hex-encoded ETH private key for Tempo channel payer (persisted to survive reconnect).
    public var ethPrivateKeyHex: String?

    public init(
        privateKeyBase64: String,
        sessionGrant: SessionGrant,
        spendState: SpendState,
        receipts: [Receipt] = [],
        history: [HistoryEntry] = [],
        ethPrivateKeyHex: String? = nil
    ) {
        self.privateKeyBase64 = privateKeyBase64
        self.sessionGrant = sessionGrant
        self.spendState = spendState
        self.receipts = receipts
        self.history = history
        self.ethPrivateKeyHex = ethPrivateKeyHex
    }

    /// Custom decoder: defaults optional fields when missing (backwards compatibility).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        privateKeyBase64 = try container.decode(String.self, forKey: .privateKeyBase64)
        sessionGrant = try container.decode(SessionGrant.self, forKey: .sessionGrant)
        spendState = try container.decode(SpendState.self, forKey: .spendState)
        receipts = try container.decode([Receipt].self, forKey: .receipts)
        history = try container.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        ethPrivateKeyHex = try container.decodeIfPresent(String.self, forKey: .ethPrivateKeyHex)
    }

    /// Whether this session is still valid (not expired).
    public var isValid: Bool {
        sessionGrant.expiresAt > Date()
    }

    public var remainingCredits: Int {
        sessionGrant.maxCredits - spendState.cumulativeSpend
    }
}

/// A provider request log entry for persistence.
/// Mirrors ProviderEngine.LogEntry but lives in JanusShared for Codable access.
public struct PersistedLogEntry: Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let taskType: String
    public let promptPreview: String
    public let responsePreview: String?
    public let credits: Int?
    public let isError: Bool
    public let sessionID: String?

    public init(id: UUID = UUID(), timestamp: Date, taskType: String, promptPreview: String,
                responsePreview: String?, credits: Int?, isError: Bool, sessionID: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.taskType = taskType
        self.promptPreview = promptPreview
        self.responsePreview = responsePreview
        self.credits = credits
        self.isError = isError
        self.sessionID = sessionID
    }
}

/// Persisted provider state — channels, receipts issued, request log.
public struct PersistedProviderState: Codable, Sendable {
    public let providerID: String
    public let privateKeyBase64: String
    public var receiptsIssued: [Receipt]
    public var totalRequestsServed: Int
    public var totalCreditsEarned: Int
    public var requestLog: [PersistedLogEntry]
    /// Hex-encoded ETH private key for Tempo settlement signing (persisted to survive restarts).
    public var ethPrivateKeyHex: String?
    /// Channels with unsettled vouchers, keyed by sessionID.
    /// Persisted so the provider can settle after restart or connectivity loss.
    public var unsettledChannels: [String: Channel]?

    public init(
        providerID: String,
        privateKeyBase64: String,
        receiptsIssued: [Receipt] = [],
        totalRequestsServed: Int = 0,
        totalCreditsEarned: Int = 0,
        requestLog: [PersistedLogEntry] = [],
        ethPrivateKeyHex: String? = nil,
        unsettledChannels: [String: Channel]? = nil
    ) {
        self.providerID = providerID
        self.privateKeyBase64 = privateKeyBase64
        self.receiptsIssued = receiptsIssued
        self.totalRequestsServed = totalRequestsServed
        self.totalCreditsEarned = totalCreditsEarned
        self.requestLog = requestLog
        self.ethPrivateKeyHex = ethPrivateKeyHex
        self.unsettledChannels = unsettledChannels
    }

    /// Custom decoder: defaults new fields when missing (backwards compatibility).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        privateKeyBase64 = try container.decode(String.self, forKey: .privateKeyBase64)
        receiptsIssued = try container.decodeIfPresent([Receipt].self, forKey: .receiptsIssued) ?? []
        totalRequestsServed = try container.decodeIfPresent(Int.self, forKey: .totalRequestsServed) ?? 0
        totalCreditsEarned = try container.decodeIfPresent(Int.self, forKey: .totalCreditsEarned) ?? 0
        requestLog = try container.decodeIfPresent([PersistedLogEntry].self, forKey: .requestLog) ?? []
        ethPrivateKeyHex = try container.decodeIfPresent(String.self, forKey: .ethPrivateKeyHex)
        unsettledChannels = try container.decodeIfPresent([String: Channel].self, forKey: .unsettledChannels)
    }
}

/// Simple JSON file persistence for Janus state.
///
/// Reads/writes Codable values as JSON files in the app's Application Support directory.
/// Thread-safe for single-writer use (which both our apps are — @MainActor).
public struct JanusStore {

    private let directory: URL

    /// Create a store in the given directory, creating it if needed.
    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Default store using the app's Application Support/Janus directory.
    public static var appDefault: JanusStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return JanusStore(directory: appSupport.appendingPathComponent("Janus", isDirectory: true))
    }

    /// Save a Codable value to a named file.
    public func save<T: Encodable>(_ value: T, as filename: String) throws {
        let url = directory.appendingPathComponent(filename)
        let data = try JSONEncoder.janus.encode(value)
        try data.write(to: url, options: .atomic)
    }

    /// Load a Codable value from a named file. Returns nil if file doesn't exist.
    public func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.janus.decode(T.self, from: data)
    }

    /// Delete a named file.
    public func delete(_ filename: String) {
        let url = directory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    /// URL for a named file in the store directory (for direct file I/O).
    public func sidecarURL(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }
}
