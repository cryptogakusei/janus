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

/// Standalone per-provider history file — accumulates across session renewals.
/// Stored as `history_{providerID}.json`, never expires, never deleted by session logic.
public struct PersistedHistory: Codable, Sendable {
    public var entries: [HistoryEntry]

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
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
    /// Channel ID from the last active Tempo channel (for post-settlement verification).
    public var lastChannelId: Data?
    /// On-chain verified settlement amount (nil = not yet verified).
    public var lastVerifiedSettlement: UInt64?
    /// Whether the on-chain channel was successfully opened (persisted to survive app restart).
    public var channelOpenedOnChain: Bool
    /// Persisted channel deposit after top-ups. Takes precedence over sessionGrant.maxCredits
    /// when reconstructing the channel in setupTempoChannel(). Nil means no top-up has occurred.
    public var lastChannelDeposit: UInt64?
    /// Escrow contract address at time of last persist. Used to detect contract migrations:
    /// if this differs from the current TempoConfig, channelOpenedOnChain is reset to false.
    public var lastEscrowContract: String?

    public init(
        privateKeyBase64: String,
        sessionGrant: SessionGrant,
        spendState: SpendState,
        receipts: [Receipt] = [],
        history: [HistoryEntry] = [],
        ethPrivateKeyHex: String? = nil,
        lastChannelId: Data? = nil,
        lastVerifiedSettlement: UInt64? = nil,
        channelOpenedOnChain: Bool = false,
        lastChannelDeposit: UInt64? = nil,
        lastEscrowContract: String? = nil
    ) {
        self.privateKeyBase64 = privateKeyBase64
        self.sessionGrant = sessionGrant
        self.spendState = spendState
        self.receipts = receipts
        self.history = history
        self.ethPrivateKeyHex = ethPrivateKeyHex
        self.lastChannelId = lastChannelId
        self.lastVerifiedSettlement = lastVerifiedSettlement
        self.channelOpenedOnChain = channelOpenedOnChain
        self.lastChannelDeposit = lastChannelDeposit
        self.lastEscrowContract = lastEscrowContract
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
        lastChannelId = try container.decodeIfPresent(Data.self, forKey: .lastChannelId)
        lastVerifiedSettlement = try container.decodeIfPresent(UInt64.self, forKey: .lastVerifiedSettlement)
        channelOpenedOnChain = try container.decodeIfPresent(Bool.self, forKey: .channelOpenedOnChain) ?? false
        lastChannelDeposit = try container.decodeIfPresent(UInt64.self, forKey: .lastChannelDeposit)
        lastEscrowContract = try container.decodeIfPresent(String.self, forKey: .lastEscrowContract)
    }

    /// Whether this session is still valid (not expired).
    ///
    /// - Note: Deprecated as of #15b. `SessionManager.restore()` no longer gates on
    ///   this — Tempo sessions do not expire based on wall-clock time. Retained for
    ///   diagnostic use and backwards test compatibility only.
    @available(*, deprecated, message: "TTL-based expiry removed in #15b. Do not add new callers.")
    public var isValid: Bool {
        sessionGrant.expiresAt > Date()
    }

    public var remainingCredits: Int {
        let ceiling = lastChannelDeposit.map(Int.init) ?? sessionGrant.maxCredits
        return ceiling - spendState.cumulativeSpend
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
    /// Identity mappings for unsettled sessions (sessionID → device pubkey base64).
    /// Only unsettled channels survive restart; other identity mappings are re-established on reconnect.
    public var sessionToIdentity: [String: String]?
    /// Settlement interval in seconds (0 = disabled). Nil means never persisted (use engine default).
    public var settlementIntervalSeconds: Int?
    /// Aggregate unsettled credit threshold for auto-settlement (0 = disabled). Nil means never persisted.
    public var settlementThreshold: Int?
    /// Settled amount per channelId (hex) — persisted for settledAmount recovery when RPC is
    /// unavailable on reconnect. Updated on every persist so periodic settlement is covered.
    public var settledChannelAmounts: [String: UInt64]?
    /// Running token tab per client channel ID (hex). Persists across restarts so clients cannot
    /// escape debt by disconnecting and reconnecting.
    public var tabByChannelId: [String: UInt64]?
    /// channelId hex → requestID of the outstanding TabSettlementRequest for that client.
    /// Persists for crash recovery (provider re-sends settlement request on reconnect)
    /// and replay prevention (voucher requestID must match this value).
    public var pendingTabSettlementByChannelId: [String: String]?
    /// Operator-configured token rate (credits per 1000 tokens). Nil = use engine default (10).
    public var tokenRate: UInt64?
    /// Operator-configured tab threshold (tokens before settlement required). Nil = use engine default (500).
    public var tabThresholdTokens: UInt64?

    public init(
        providerID: String,
        privateKeyBase64: String,
        receiptsIssued: [Receipt] = [],
        totalRequestsServed: Int = 0,
        totalCreditsEarned: Int = 0,
        requestLog: [PersistedLogEntry] = [],
        ethPrivateKeyHex: String? = nil,
        unsettledChannels: [String: Channel]? = nil,
        sessionToIdentity: [String: String]? = nil,
        settlementIntervalSeconds: Int? = nil,
        settlementThreshold: Int? = nil,
        settledChannelAmounts: [String: UInt64]? = nil,
        tabByChannelId: [String: UInt64]? = nil,
        pendingTabSettlementByChannelId: [String: String]? = nil,
        tokenRate: UInt64? = nil,
        tabThresholdTokens: UInt64? = nil
    ) {
        self.providerID = providerID
        self.privateKeyBase64 = privateKeyBase64
        self.receiptsIssued = receiptsIssued
        self.totalRequestsServed = totalRequestsServed
        self.totalCreditsEarned = totalCreditsEarned
        self.requestLog = requestLog
        self.ethPrivateKeyHex = ethPrivateKeyHex
        self.unsettledChannels = unsettledChannels
        self.sessionToIdentity = sessionToIdentity
        self.settlementIntervalSeconds = settlementIntervalSeconds
        self.settlementThreshold = settlementThreshold
        self.settledChannelAmounts = settledChannelAmounts
        self.tabByChannelId = tabByChannelId
        self.pendingTabSettlementByChannelId = pendingTabSettlementByChannelId
        self.tokenRate = tokenRate
        self.tabThresholdTokens = tabThresholdTokens
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
        sessionToIdentity = try container.decodeIfPresent([String: String].self, forKey: .sessionToIdentity)
        settlementIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .settlementIntervalSeconds)
        settlementThreshold = try container.decodeIfPresent(Int.self, forKey: .settlementThreshold)
        settledChannelAmounts = try container.decodeIfPresent([String: UInt64].self, forKey: .settledChannelAmounts)
        tabByChannelId = try container.decodeIfPresent([String: UInt64].self, forKey: .tabByChannelId)
        pendingTabSettlementByChannelId = try container.decodeIfPresent([String: String].self, forKey: .pendingTabSettlementByChannelId)
        tokenRate = try container.decodeIfPresent(UInt64.self, forKey: .tokenRate)
        tabThresholdTokens = try container.decodeIfPresent(UInt64.self, forKey: .tabThresholdTokens)
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
