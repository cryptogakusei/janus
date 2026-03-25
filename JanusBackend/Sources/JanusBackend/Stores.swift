import Foundation
import JanusShared

/// In-memory session store. Replace with a database for production.
actor InMemorySessionStore {
    private var sessions: [String: SessionRecord] = [:]

    struct SessionRecord {
        let grant: SessionGrant
        let createdAt: Date
        var settled: Bool = false
        var settledSpend: Int = 0
    }

    func create(_ grant: SessionGrant) {
        sessions[grant.sessionID] = SessionRecord(grant: grant, createdAt: Date())
    }

    func get(_ sessionID: String) -> SessionRecord? {
        sessions[sessionID]
    }

    /// Settle or re-settle a session. Allows updating spend if the session
    /// continues after a prior settlement (e.g. client reconnects).
    /// Returns the new settled spend, or nil if session not found or spend decreased.
    func settle(_ sessionID: String, spend: Int) -> Int? {
        guard var record = sessions[sessionID] else { return nil }
        // Allow re-settlement only if spend increased
        guard spend >= record.settledSpend else { return nil }
        record.settled = true
        record.settledSpend = spend
        sessions[sessionID] = record
        return spend
    }

    var count: Int { sessions.count }
}

/// In-memory provider registry.
actor InMemoryProviderStore {
    private var providers: [String: ProviderRecord] = [:]

    struct ProviderRecord {
        let providerID: String
        let publicKeyBase64: String
        let registeredAt: Date
    }

    func register(providerID: String, publicKeyBase64: String) {
        providers[providerID] = ProviderRecord(
            providerID: providerID,
            publicKeyBase64: publicKeyBase64,
            registeredAt: Date()
        )
    }

    func get(_ providerID: String) -> ProviderRecord? {
        providers[providerID]
    }

    var count: Int { providers.count }
}
