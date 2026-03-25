import Vapor
import JanusShared

// MARK: - Request/Response DTOs

struct CreateSessionRequest: Content {
    let providerID: String
    let clientPubkey: String  // base64 Ed25519 public key
    let maxCredits: Int?      // optional, defaults to 100
}

struct CreateSessionResponse: Content {
    let sessionGrant: SessionGrant
}

struct RegisterProviderRequest: Content {
    let providerID: String
    let publicKeyBase64: String
}

struct RegisterProviderResponse: Content {
    let providerID: String
    let registered: Bool
}

struct SettleSessionRequest: Content {
    let sessionID: String
    let providerID: String
    let cumulativeSpend: Int
    let receipts: [Receipt]
}

struct SettleSessionResponse: Content {
    let sessionID: String
    let settled: Bool
    let settledSpend: Int
}

struct StatusResponse: Content {
    let status: String
    let sessions: Int
    let providers: Int
}

// MARK: - Routes

func routes(
    _ app: Application,
    backendSigner: JanusSigner,
    sessionStore: InMemorySessionStore,
    providerStore: InMemoryProviderStore
) throws {

    // Health check
    app.get("status") { req async -> StatusResponse in
        let sessionCount = await sessionStore.count
        let providerCount = await providerStore.count
        return StatusResponse(status: "ok", sessions: sessionCount, providers: providerCount)
    }

    // POST /providers/register — register a provider's identity
    app.post("providers", "register") { req async throws -> RegisterProviderResponse in
        let body = try req.content.decode(RegisterProviderRequest.self)

        guard !body.providerID.isEmpty, !body.publicKeyBase64.isEmpty else {
            throw Abort(.badRequest, reason: "providerID and publicKeyBase64 are required")
        }

        await providerStore.register(providerID: body.providerID, publicKeyBase64: body.publicKeyBase64)
        req.logger.info("Provider registered: \(body.providerID)")

        return RegisterProviderResponse(providerID: body.providerID, registered: true)
    }

    // POST /sessions — create a new funded session
    app.post("sessions") { req async throws -> CreateSessionResponse in
        let body = try req.content.decode(CreateSessionRequest.self)

        guard !body.providerID.isEmpty, !body.clientPubkey.isEmpty else {
            throw Abort(.badRequest, reason: "providerID and clientPubkey are required")
        }

        // Verify provider is registered
        guard await providerStore.get(body.providerID) != nil else {
            throw Abort(.notFound, reason: "Provider \(body.providerID) not registered")
        }

        let sessionID = UUID().uuidString
        let maxCredits = body.maxCredits ?? DemoConfig.defaultMaxCredits
        let expiresAt = Date().addingTimeInterval(DemoConfig.defaultSessionDuration)

        // Create the grant with a placeholder signature
        let unsignedGrant = SessionGrant(
            sessionID: sessionID,
            userPubkey: body.clientPubkey,
            providerID: body.providerID,
            maxCredits: maxCredits,
            expiresAt: expiresAt,
            backendSignature: ""
        )

        // Sign with the backend key
        let signature = try backendSigner.sign(fields: unsignedGrant.signableFields)

        let grant = SessionGrant(
            sessionID: sessionID,
            userPubkey: body.clientPubkey,
            providerID: body.providerID,
            maxCredits: maxCredits,
            expiresAt: expiresAt,
            backendSignature: signature
        )

        // Store the session
        await sessionStore.create(grant)
        req.logger.info("Session created: \(sessionID) for provider \(body.providerID), \(maxCredits) credits")

        return CreateSessionResponse(sessionGrant: grant)
    }

    // POST /sessions/settle — provider submits final spend for settlement
    app.post("sessions", "settle") { req async throws -> SettleSessionResponse in
        let body = try req.content.decode(SettleSessionRequest.self)

        guard let session = await sessionStore.get(body.sessionID) else {
            throw Abort(.notFound, reason: "Session \(body.sessionID) not found")
        }

        guard session.grant.providerID == body.providerID else {
            throw Abort(.forbidden, reason: "Provider mismatch")
        }

        guard body.cumulativeSpend <= session.grant.maxCredits else {
            throw Abort(.badRequest, reason: "Spend \(body.cumulativeSpend) exceeds grant max \(session.grant.maxCredits)")
        }

        guard let settledSpend = await sessionStore.settle(body.sessionID, spend: body.cumulativeSpend) else {
            throw Abort(.conflict, reason: "Cannot settle: spend must be >= previous settlement")
        }

        req.logger.info("Session settled: \(body.sessionID), spend: \(settledSpend)/\(session.grant.maxCredits)")

        return SettleSessionResponse(
            sessionID: body.sessionID,
            settled: true,
            settledSpend: settledSpend
        )
    }
}
