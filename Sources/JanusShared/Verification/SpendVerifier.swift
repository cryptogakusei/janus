import Foundation
import CryptoKit

/// Pure-logic verifier for spend authorizations.
///
/// Executes the 9-step verification from the PRD:
/// 1. Session exists
/// 2. Session not expired
/// 3. Provider match
/// 4. Quote valid
/// 5. Sequence monotonic
/// 6. Spend monotonic
/// 7. Spend increment matches quote
/// 8. Budget sufficient
/// 9. Signature valid
///
/// Design: `(SpendAuthorization, SessionGrant, SpendState, QuoteResponse) → Result<Accepted, VerificationError>`
/// No I/O, no MPC, no MLX — fully testable.
public struct SpendVerifier: Sendable {

    private let providerID: String
    private let backendVerifier: JanusVerifier

    /// - Parameters:
    ///   - providerID: This provider's ID, checked against session grants.
    ///   - backendPublicKeyBase64: The hardcoded backend public key for grant verification.
    public init(providerID: String, backendPublicKeyBase64: String) throws {
        self.providerID = providerID
        self.backendVerifier = try JanusVerifier(publicKeyBase64: backendPublicKeyBase64)
    }

    /// Result of successful verification.
    public struct Accepted: Sendable {
        public let creditsCharged: Int
        public let newCumulativeSpend: Int
        public let newSequenceNumber: Int
    }

    /// Verify a spend authorization against the session grant, current spend state, and quote.
    ///
    /// - Parameters:
    ///   - authorization: The SpendAuthorization from the client.
    ///   - grant: The cached SessionGrant for this session.
    ///   - spendState: The current SpendState for this session.
    ///   - quote: The QuoteResponse that was issued for this request.
    ///   - now: Current time (injectable for testing).
    /// - Returns: `Accepted` on success.
    /// - Throws: `VerificationError` with the specific check that failed.
    public func verify(
        authorization: SpendAuthorization,
        grant: SessionGrant,
        spendState: SpendState,
        quote: QuoteResponse,
        now: Date = Date()
    ) throws -> Accepted {

        // 1. Session exists — caller ensures grant is found; we check IDs match
        guard authorization.sessionID == grant.sessionID else {
            throw VerificationError.invalidSession
        }

        // 2. Session not expired
        guard grant.expiresAt > now else {
            throw VerificationError.sessionExpired
        }

        // 3. Provider match
        guard grant.providerID == providerID else {
            throw VerificationError.invalidSession
        }

        // 4. Quote valid — quote matches request and hasn't expired
        guard quote.requestID == authorization.requestID,
              quote.quoteID == authorization.quoteID,
              quote.expiresAt > now else {
            throw VerificationError.expiredQuote
        }

        // 5. Sequence monotonic
        guard authorization.sequenceNumber > spendState.sequenceNumber else {
            throw VerificationError.sequenceMismatch
        }

        // 6. Spend monotonic
        guard authorization.cumulativeSpend > spendState.cumulativeSpend else {
            throw VerificationError.sequenceMismatch
        }

        // 7. Spend increment matches quote
        let increment = authorization.cumulativeSpend - spendState.cumulativeSpend
        guard increment >= quote.priceCredits else {
            throw VerificationError.insufficientCredits
        }

        // 8. Budget sufficient
        guard authorization.cumulativeSpend <= grant.maxCredits else {
            throw VerificationError.insufficientCredits
        }

        // 9. Signature valid
        let clientVerifier: JanusVerifier
        do {
            clientVerifier = try JanusVerifier(publicKeyBase64: grant.userPubkey)
        } catch {
            throw VerificationError.invalidSignature
        }

        guard clientVerifier.verify(
            signature: authorization.clientSignature,
            fields: authorization.signableFields
        ) else {
            throw VerificationError.invalidSignature
        }

        return Accepted(
            creditsCharged: quote.priceCredits,
            newCumulativeSpend: authorization.cumulativeSpend,
            newSequenceNumber: authorization.sequenceNumber
        )
    }

    /// Verify a session grant's backend signature.
    public func verifyGrant(_ grant: SessionGrant) -> Bool {
        guard grant.providerID == providerID else { return false }
        return backendVerifier.verify(
            signature: grant.backendSignature,
            fields: grant.signableFields
        )
    }
}

/// Errors from the 9-step spend verification.
public enum VerificationError: Error, Sendable {
    case invalidSession
    case sessionExpired
    case expiredQuote
    case sequenceMismatch
    case insufficientCredits
    case invalidSignature

    /// Map to the ErrorResponse.ErrorCode for wire transport.
    public var errorCode: ErrorResponse.ErrorCode {
        switch self {
        case .invalidSession: return .invalidSession
        case .sessionExpired: return .sessionExpired
        case .expiredQuote: return .expiredQuote
        case .sequenceMismatch: return .sequenceMismatch
        case .insufficientCredits: return .insufficientCredits
        case .invalidSignature: return .invalidSignature
        }
    }
}
