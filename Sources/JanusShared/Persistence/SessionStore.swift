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
    public var grantDelivered: Bool
    public var history: [HistoryEntry]
    /// Hex-encoded ETH private key for Tempo voucher signing (persisted to survive reconnect).
    public var ethPrivateKeyHex: String?

    public init(
        privateKeyBase64: String,
        sessionGrant: SessionGrant,
        spendState: SpendState,
        receipts: [Receipt] = [],
        grantDelivered: Bool = false,
        history: [HistoryEntry] = [],
        ethPrivateKeyHex: String? = nil
    ) {
        self.privateKeyBase64 = privateKeyBase64
        self.sessionGrant = sessionGrant
        self.spendState = spendState
        self.receipts = receipts
        self.grantDelivered = grantDelivered
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
        grantDelivered = try container.decode(Bool.self, forKey: .grantDelivered)
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

/// Persisted provider state — sessions, spend ledger, receipts issued.
public struct PersistedProviderState: Codable, Sendable {
    public let providerID: String
    public let privateKeyBase64: String
    public var knownSessions: [String: SessionGrant]
    public var spendLedger: [String: SpendState]
    public var receiptsIssued: [Receipt]
    public var totalRequestsServed: Int
    public var totalCreditsEarned: Int
    public var requestLog: [PersistedLogEntry]
    /// Maps sessionID → last settled cumulative spend.
    /// Allows re-settlement when more spend accumulates after a prior settlement.
    public var settledSpends: [String: Int]
    /// Hex-encoded ETH private key for Tempo settlement signing (persisted to survive restarts).
    public var ethPrivateKeyHex: String?

    public init(
        providerID: String,
        privateKeyBase64: String,
        knownSessions: [String: SessionGrant] = [:],
        spendLedger: [String: SpendState] = [:],
        receiptsIssued: [Receipt] = [],
        totalRequestsServed: Int = 0,
        totalCreditsEarned: Int = 0,
        requestLog: [PersistedLogEntry] = [],
        settledSpends: [String: Int] = [:],
        ethPrivateKeyHex: String? = nil
    ) {
        self.providerID = providerID
        self.privateKeyBase64 = privateKeyBase64
        self.knownSessions = knownSessions
        self.spendLedger = spendLedger
        self.receiptsIssued = receiptsIssued
        self.totalRequestsServed = totalRequestsServed
        self.totalCreditsEarned = totalCreditsEarned
        self.requestLog = requestLog
        self.settledSpends = settledSpends
        self.ethPrivateKeyHex = ethPrivateKeyHex
    }

    /// Custom decoder: defaults new fields when missing (backwards compatibility).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        privateKeyBase64 = try container.decode(String.self, forKey: .privateKeyBase64)
        knownSessions = try container.decode([String: SessionGrant].self, forKey: .knownSessions)
        spendLedger = try container.decode([String: SpendState].self, forKey: .spendLedger)
        receiptsIssued = try container.decode([Receipt].self, forKey: .receiptsIssued)
        totalRequestsServed = try container.decode(Int.self, forKey: .totalRequestsServed)
        totalCreditsEarned = try container.decode(Int.self, forKey: .totalCreditsEarned)
        requestLog = try container.decodeIfPresent([PersistedLogEntry].self, forKey: .requestLog) ?? []
        settledSpends = try container.decodeIfPresent([String: Int].self, forKey: .settledSpends) ?? [:]
        ethPrivateKeyHex = try container.decodeIfPresent(String.self, forKey: .ethPrivateKeyHex)
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
