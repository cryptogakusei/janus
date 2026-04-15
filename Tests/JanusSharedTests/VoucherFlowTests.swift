import XCTest
@testable import JanusShared

/// End-to-end tests for the Tempo voucher payment flow.
///
/// These tests simulate the full request lifecycle:
///   PromptRequest → QuoteResponse → VoucherAuthorization → InferenceResponse
final class VoucherFlowTests: XCTestCase {

    // Shared fixtures
    private var clientKP: EthKeyPair!
    private var providerKP: EthKeyPair!
    private var config: TempoConfig!
    private var channel: Channel!
    private var verifier: VoucherVerifier!

    override func setUp() {
        super.setUp()
        clientKP = try! EthKeyPair()
        providerKP = try! EthKeyPair()
        config = TempoConfig.testnet

        let salt = Keccak256.hash(Data("test-session".utf8))
        channel = Channel(
            payer: clientKP.address,
            payee: providerKP.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 100,
            config: config
        )

        verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)
    }

    // MARK: - Helpers

    private func makeQuote(requestID: String, priceCredits: Int = 5) -> QuoteResponse {
        QuoteResponse(requestID: requestID, priceCredits: priceCredits,
                      priceTier: "medium", expiresAt: Date().addingTimeInterval(60))
    }

    private func makeAuth(requestID: String, quoteID: String? = "test-quote-id",
                          cumulativeAmount: UInt64) throws -> VoucherAuthorization {
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: cumulativeAmount)
        let signed = try voucher.sign(with: clientKP, config: config)
        return VoucherAuthorization(requestID: requestID, quoteID: quoteID, signedVoucher: signed)
    }

    // MARK: - Happy path

    func testSingleRequestFlow() throws {
        let quote = makeQuote(requestID: "req-1", priceCredits: 5)
        let auth = try makeAuth(requestID: "req-1", quoteID: quote.quoteID, cumulativeAmount: 5)

        let result = try verifier.verify(authorization: auth, channel: channel, quote: quote)
        XCTAssertEqual(result.creditsCharged, 5)
        XCTAssertEqual(result.newCumulativeAmount, 5)

        // Provider accepts the voucher into channel state
        try channel.acceptVoucher(auth.signedVoucher)
        XCTAssertEqual(channel.authorizedAmount, 5)
    }

    func testMultipleSequentialRequests() throws {
        // Request 1: 5 credits
        let q1 = makeQuote(requestID: "req-1", priceCredits: 5)
        let a1 = try makeAuth(requestID: "req-1", quoteID: q1.quoteID, cumulativeAmount: 5)
        let r1 = try verifier.verify(authorization: a1, channel: channel, quote: q1)
        try channel.acceptVoucher(a1.signedVoucher)
        XCTAssertEqual(r1.creditsCharged, 5)

        // Request 2: 3 more credits (cumulative = 8)
        let q2 = makeQuote(requestID: "req-2", priceCredits: 3)
        let a2 = try makeAuth(requestID: "req-2", quoteID: q2.quoteID, cumulativeAmount: 8)
        let r2 = try verifier.verify(authorization: a2, channel: channel, quote: q2)
        try channel.acceptVoucher(a2.signedVoucher)
        XCTAssertEqual(r2.creditsCharged, 3)
        XCTAssertEqual(r2.newCumulativeAmount, 8)

        // Request 3: 8 more credits (cumulative = 16)
        let q3 = makeQuote(requestID: "req-3", priceCredits: 8)
        let a3 = try makeAuth(requestID: "req-3", quoteID: q3.quoteID, cumulativeAmount: 16)
        let r3 = try verifier.verify(authorization: a3, channel: channel, quote: q3)
        try channel.acceptVoucher(a3.signedVoucher)
        XCTAssertEqual(r3.creditsCharged, 8)
        XCTAssertEqual(channel.authorizedAmount, 16)
    }

    // MARK: - Verification failures

    func testRejectsWrongSigner() throws {
        let wrongKP = try EthKeyPair()
        let quote = makeQuote(requestID: "req-1", priceCredits: 5)
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 5)
        let signed = try voucher.sign(with: wrongKP, config: config) // signed by wrong key
        let auth = VoucherAuthorization(requestID: "req-1", quoteID: quote.quoteID, signedVoucher: signed)

        XCTAssertThrowsError(try verifier.verify(authorization: auth, channel: channel, quote: quote)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .invalidSignature)
        }
    }

    func testRejectsNonMonotonicVoucher() throws {
        // First request succeeds
        let q1 = makeQuote(requestID: "req-1", priceCredits: 5)
        let a1 = try makeAuth(requestID: "req-1", quoteID: q1.quoteID, cumulativeAmount: 5)
        _ = try verifier.verify(authorization: a1, channel: channel, quote: q1)
        try channel.acceptVoucher(a1.signedVoucher)

        // Second request with lower cumulative amount
        let q2 = makeQuote(requestID: "req-2", priceCredits: 3)
        let a2 = try makeAuth(requestID: "req-2", quoteID: q2.quoteID, cumulativeAmount: 3)
        XCTAssertThrowsError(try verifier.verify(authorization: a2, channel: channel, quote: q2)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .nonMonotonicVoucher)
        }
    }

    func testRejectsExceedingDeposit() throws {
        // Channel has deposit of 100, try to authorize 150
        let quote = makeQuote(requestID: "req-1", priceCredits: 5)
        let auth = try makeAuth(requestID: "req-1", quoteID: quote.quoteID, cumulativeAmount: 150)

        XCTAssertThrowsError(try verifier.verify(authorization: auth, channel: channel, quote: quote)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .exceedsDeposit)
        }
    }

    func testRejectsInsufficientIncrement() throws {
        // First: authorize 5
        let q1 = makeQuote(requestID: "req-1", priceCredits: 5)
        let a1 = try makeAuth(requestID: "req-1", quoteID: q1.quoteID, cumulativeAmount: 5)
        _ = try verifier.verify(authorization: a1, channel: channel, quote: q1)
        try channel.acceptVoucher(a1.signedVoucher)

        // Second: quote is 8 credits but increment is only 1 (6-5)
        let q2 = makeQuote(requestID: "req-2", priceCredits: 8)
        let a2 = try makeAuth(requestID: "req-2", quoteID: q2.quoteID, cumulativeAmount: 6)
        XCTAssertThrowsError(try verifier.verify(authorization: a2, channel: channel, quote: q2)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .insufficientAmount)
        }
    }

    func testRejectsExpiredQuote() throws {
        let expiredQuote = QuoteResponse(
            requestID: "req-1", priceCredits: 5, priceTier: "medium",
            expiresAt: Date().addingTimeInterval(-10) // expired 10 seconds ago
        )
        let auth = try makeAuth(requestID: "req-1", quoteID: expiredQuote.quoteID, cumulativeAmount: 5)

        XCTAssertThrowsError(try verifier.verify(authorization: auth, channel: channel, quote: expiredQuote)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .expiredQuote)
        }
    }

    func testRejectsWrongProvider() throws {
        // Verifier for a different provider
        let otherProvider = try EthKeyPair()
        let wrongVerifier = VoucherVerifier(providerAddress: otherProvider.address, config: config)

        let quote = makeQuote(requestID: "req-1", priceCredits: 5)
        let auth = try makeAuth(requestID: "req-1", quoteID: quote.quoteID, cumulativeAmount: 5)

        XCTAssertThrowsError(try wrongVerifier.verify(authorization: auth, channel: channel, quote: quote)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .wrongProvider)
        }
    }

    func testRejectsWrongChannelId() throws {
        let quote = makeQuote(requestID: "req-1", priceCredits: 5)
        // Sign a voucher for a different channel
        let wrongChannelId = Keccak256.hash(Data("wrong".utf8))
        let voucher = Voucher(channelId: wrongChannelId, cumulativeAmount: 5)
        let signed = try voucher.sign(with: clientKP, config: config)
        let auth = VoucherAuthorization(requestID: "req-1", quoteID: quote.quoteID, signedVoucher: signed)

        XCTAssertThrowsError(try verifier.verify(authorization: auth, channel: channel, quote: quote)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .channelMismatch)
        }
    }

    // MARK: - ChannelInfo verification

    func testChannelInfoVerification() throws {
        let info = ChannelInfo(channel: channel, config: config)
        XCTAssertTrue(verifier.verifyChannelInfo(info))
    }

    func testVerifyChannelInfoOnChain_returnsRpcUnavailable_whenNoRPCConfigured() async throws {
        // Build a config without an RPC URL — verifyChannelInfoOnChain should
        // immediately return .rpcUnavailable without touching the network.
        let noRPCConfig = TempoConfig(
            escrowContract: config.escrowContract,
            paymentToken: config.paymentToken,
            chainId: config.chainId,
            rpcURL: nil
        )
        let offChainVerifier = VoucherVerifier(providerAddress: providerKP.address, config: noRPCConfig)
        let info = ChannelInfo(channel: channel, config: noRPCConfig)

        let result = await offChainVerifier.verifyChannelInfoOnChain(info)

        if case .rpcUnavailable = result { /* pass */ }
        else { XCTFail("Expected .rpcUnavailable, got \(result)") }
        XCTAssertTrue(result.isAccepted, ".rpcUnavailable must be accepted (supports offline inference)")
    }

    func testChannelInfoRejectsWrongPayee() throws {
        // Create channel info claiming a different provider
        let otherProvider = try EthKeyPair()
        let salt = Keccak256.hash(Data("other".utf8))
        let wrongChannel = Channel(
            payer: clientKP.address,
            payee: otherProvider.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 100,
            config: config
        )
        let info = ChannelInfo(channel: wrongChannel, config: config)
        XCTAssertFalse(verifier.verifyChannelInfo(info))
    }

    func testChannelInfoRejectsTamperedChannelId() throws {
        var info = ChannelInfo(channel: channel, config: config)
        // Tamper with channel ID
        let tampered = ChannelInfo(
            payerAddress: info.payerAddress,
            payeeAddress: info.payeeAddress,
            tokenAddress: info.tokenAddress,
            salt: info.salt,
            authorizedSigner: info.authorizedSigner,
            deposit: info.deposit,
            channelId: Keccak256.hash(Data("fake".utf8))
        )
        XCTAssertFalse(verifier.verifyChannelInfo(tampered))
    }

    // MARK: - MessageEnvelope round-trip

    func testVoucherAuthorizationEnvelopeRoundTrip() throws {
        let auth = try makeAuth(requestID: "req-1", quoteID: "quote-1", cumulativeAmount: 42)
        let envelope = try MessageEnvelope.wrap(
            type: .voucherAuthorization,
            senderID: "client-1",
            payload: auth
        )
        let data = try envelope.serialized()
        let restored = try MessageEnvelope.deserialize(from: data)

        XCTAssertEqual(restored.type, .voucherAuthorization)
        let decoded = try restored.unwrap(as: VoucherAuthorization.self)
        XCTAssertEqual(decoded.requestID, "req-1")
        XCTAssertEqual(decoded.cumulativeAmount, 42)
    }

    func testChannelInfoEnvelopeRoundTrip() throws {
        let info = ChannelInfo(channel: channel, config: config)
        let data = try JSONEncoder.janus.encode(info)
        let decoded = try JSONDecoder.janus.decode(ChannelInfo.self, from: data)

        XCTAssertEqual(decoded.channelId, channel.channelId)
        XCTAssertEqual(decoded.deposit, 100)
        XCTAssertEqual(decoded.payerAddress, clientKP.address)
        XCTAssertEqual(decoded.payeeAddress, providerKP.address)
    }

    // MARK: - Budget exhaustion

    func testBudgetExhaustionAtExactDeposit() throws {
        // Channel deposit = 100. Spend exactly 100 across multiple requests.
        var amounts: [UInt64] = [30, 60, 100]
        for (i, amount) in amounts.enumerated() {
            let reqId = "req-\(i+1)"
            let price = Int(amount - (i > 0 ? amounts[i-1] : 0))
            let q = makeQuote(requestID: reqId, priceCredits: price)
            let a = try makeAuth(requestID: reqId, quoteID: q.quoteID, cumulativeAmount: amount)
            _ = try verifier.verify(authorization: a, channel: channel, quote: q)
            try channel.acceptVoucher(a.signedVoucher)
        }

        XCTAssertEqual(channel.authorizedAmount, 100)

        // Next request should fail — budget exhausted
        let q = makeQuote(requestID: "req-4", priceCredits: 1)
        let a = try makeAuth(requestID: "req-4", quoteID: q.quoteID, cumulativeAmount: 101)
        XCTAssertThrowsError(try verifier.verify(authorization: a, channel: channel, quote: q)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .exceedsDeposit)
        }
    }
}
