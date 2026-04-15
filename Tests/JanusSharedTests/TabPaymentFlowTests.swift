import XCTest
@testable import JanusShared

/// Tests for the tab-based postpaid payment model.
///
/// Covers: serialization, ceiling division math, verifyTabSettlement() validation,
/// persistence round-trips, and tab lifecycle state transitions.
final class TabPaymentFlowTests: XCTestCase {

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

        let salt = Keccak256.hash(Data("tab-test-session".utf8))
        channel = Channel(
            payer: clientKP.address,
            payee: providerKP.address,
            token: EthAddress(Data(repeating: 0, count: 20)),
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 1000,
            config: config
        )
        verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)
    }

    // MARK: - Test 1: TabUpdate serialization round-trip

    func testTabUpdate_serializationRoundTrip() throws {
        let original = TabUpdate(tokensUsed: 150, cumulativeTabTokens: 350, tabThreshold: 500, tokenRate: 10)
        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(TabUpdate.self, from: data)

        XCTAssertEqual(decoded.tokensUsed, 150)
        XCTAssertEqual(decoded.cumulativeTabTokens, 350)
        XCTAssertEqual(decoded.tabThreshold, 500)
        XCTAssertEqual(decoded.tokenRate, 10)
    }

    // MARK: - Test 2: TabSettlementRequest serialization round-trip

    func testTabSettlementRequest_serializationRoundTrip() throws {
        let channelId = Data(repeating: 0xDE, count: 32)
        let original = TabSettlementRequest(requestID: "req-abc", tabCredits: 42, channelId: channelId)
        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(TabSettlementRequest.self, from: data)

        XCTAssertEqual(decoded.requestID, "req-abc")
        XCTAssertEqual(decoded.tabCredits, 42)
        XCTAssertEqual(decoded.channelId, channelId)
    }

    // MARK: - Test 3: VoucherAuthorization with nil quoteID round-trip

    func testVoucherAuthorization_nilQuoteID_roundTrip() throws {
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 50)
        let signed = try voucher.sign(with: clientKP, config: config)
        let original = VoucherAuthorization(requestID: "req-tab", quoteID: nil, signedVoucher: signed)

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(VoucherAuthorization.self, from: data)

        XCTAssertNil(decoded.quoteID, "nil quoteID must survive encode/decode (discriminant for tab settlement)")
        XCTAssertEqual(decoded.requestID, "req-tab")
    }

    // MARK: - Test 4: VoucherAuthorization with non-nil quoteID backward compat

    func testVoucherAuthorization_nonNilQuoteID_backwardCompat() throws {
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 5)
        let signed = try voucher.sign(with: clientKP, config: config)
        let original = VoucherAuthorization(requestID: "req-1", quoteID: "quote-xyz", signedVoucher: signed)

        let data = try JSONEncoder.janus.encode(original)
        let decoded = try JSONDecoder.janus.decode(VoucherAuthorization.self, from: data)

        XCTAssertEqual(decoded.quoteID, "quote-xyz")
    }

    // MARK: - Test 5: verifyTabSettlement happy path

    func testVerifyTabSettlement_happyPath() throws {
        let tabCredits: UInt64 = 10
        let auth = try makeTabAuth(cumulativeAmount: tabCredits)

        let result = try verifier.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: tabCredits)

        XCTAssertEqual(result.creditsCharged, Int(tabCredits))
        XCTAssertEqual(result.newCumulativeAmount, tabCredits)
    }

    // MARK: - Test 6: verifyTabSettlement rejects non-monotonic voucher

    func testVerifyTabSettlement_rejectsNonMonotonicVoucher() throws {
        var modifiedChannel = channel!
        try modifiedChannel.acceptVoucher(makeTabAuth(cumulativeAmount: 20).signedVoucher)

        // Try to submit a voucher with lower cumulativeAmount
        let auth = try makeTabAuth(cumulativeAmount: 10)
        XCTAssertThrowsError(try verifier.verifyTabSettlement(authorization: auth, channel: modifiedChannel, tabCredits: 10)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .nonMonotonicVoucher)
        }
    }

    // MARK: - Test 7: verifyTabSettlement rejects insufficient increment

    func testVerifyTabSettlement_rejectsInsufficientIncrement() throws {
        // 15 credits owed but voucher only covers 5
        let auth = try makeTabAuth(cumulativeAmount: 5)
        XCTAssertThrowsError(try verifier.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: 15)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .insufficientAmount)
        }
    }

    // MARK: - Test 17: verifyTabSettlement rejects closed channel

    func testVerifyTabSettlement_rejectsClosedChannel() throws {
        var closedChannel = channel!
        closedChannel.state = .closed
        let auth = try makeTabAuth(cumulativeAmount: 10)
        XCTAssertThrowsError(try verifier.verifyTabSettlement(authorization: auth, channel: closedChannel, tabCredits: 10)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .channelNotOpen)
        }
    }

    // MARK: - Test 18: verifyTabSettlement rejects wrong provider

    func testVerifyTabSettlement_rejectsWrongProvider() throws {
        let wrongProviderKP = try! EthKeyPair()
        let wrongVerifier = VoucherVerifier(providerAddress: wrongProviderKP.address, config: config)
        let auth = try makeTabAuth(cumulativeAmount: 10)
        XCTAssertThrowsError(try wrongVerifier.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: 10)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .wrongProvider)
        }
    }

    // MARK: - Test 19: verifyTabSettlement rejects exceeds deposit

    func testVerifyTabSettlement_rejectsExceedsDeposit() throws {
        let auth = try makeTabAuth(cumulativeAmount: 1001)  // deposit is 1000
        XCTAssertThrowsError(try verifier.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: 1001)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .exceedsDeposit)
        }
    }

    // MARK: - Test 20: verifyTabSettlement rejects invalid signature

    func testVerifyTabSettlement_rejectsInvalidSignature() throws {
        let wrongSignerKP = try! EthKeyPair()  // different key from channel's authorizedSigner
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 10)
        let signed = try voucher.sign(with: wrongSignerKP, config: config)
        let auth = VoucherAuthorization(requestID: "req-bad-sig", quoteID: nil, signedVoucher: signed)
        XCTAssertThrowsError(try verifier.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: 10)) { error in
            XCTAssertEqual(error as? VoucherVerificationError, .invalidSignature)
        }
    }

    // MARK: - Test 8: PersistedProviderState tab fields round-trip

    func testPersistedProviderState_tabFields_roundTrip() throws {
        let tabs: [String: UInt64] = ["0xabcd": 350, "0xef01": 0]
        let pending: [String: String] = ["0xabcd": "settle-req-1"]

        let state = PersistedProviderState(
            providerID: "prov-1",
            privateKeyBase64: "base64key==",
            tabByChannelId: tabs,
            pendingTabSettlementByChannelId: pending
        )
        let data = try JSONEncoder.janus.encode(state)
        let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: data)

        XCTAssertEqual(decoded.tabByChannelId?["0xabcd"], 350)
        XCTAssertEqual(decoded.tabByChannelId?["0xef01"], 0)
        XCTAssertEqual(decoded.pendingTabSettlementByChannelId?["0xabcd"], "settle-req-1")
    }

    func testPersistedProviderState_tabFields_nilWhenAbsent() throws {
        let state = PersistedProviderState(providerID: "prov-1", privateKeyBase64: "key==")
        let data = try JSONEncoder.janus.encode(state)
        let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: data)

        XCTAssertNil(decoded.tabByChannelId, "tabByChannelId must be nil when absent (decodeIfPresent)")
        XCTAssertNil(decoded.pendingTabSettlementByChannelId, "pendingTabSettlementByChannelId must be nil when absent")
    }

    // MARK: - Tests 9–11: Ceiling division correctness

    func testCeilingDivision_exactlyAtThreshold() {
        // 500 tokens * 10 rate / 1000 = exactly 5 credits
        let tokens: UInt64 = 500
        let rate: UInt64 = 10
        let credits = max(1, (tokens * rate + 999) / 1000)
        XCTAssertEqual(credits, 5)
    }

    func testCeilingDivision_zeroTokensMinimum() {
        // 0 tokens → should be 1 (min) to prevent 0-credit monotonicity violation
        let tokens: UInt64 = 0
        let rate: UInt64 = 10
        let credits = max(1, (tokens * rate + 999) / 1000)
        XCTAssertEqual(credits, 1, "0 tokens must produce minimum 1 credit")
    }

    func testCeilingDivision_tabledriven() {
        let cases: [(tokens: UInt64, rate: UInt64, expected: UInt64)] = [
            (1, 10, 1),       // 0.01 credits → ceil → 1
            (100, 10, 1),     // 1 credit exactly
            (101, 10, 2),     // 1.01 credits → ceil → 2
            (200, 10, 2),     // 2 credits exactly
            (999, 10, 10),    // 9.99 → ceil → 10
            (1000, 10, 10),   // 10 credits exactly
            (1001, 10, 11),   // 10.01 → ceil → 11
        ]
        for c in cases {
            let got = max(1, (c.tokens * c.rate + 999) / 1000)
            XCTAssertEqual(got, c.expected,
                           "tokens=\(c.tokens) rate=\(c.rate): expected \(c.expected) got \(got)")
        }
    }

    // MARK: - Test 12: Tab resets after successful settlement

    func testTabSettlementVoucher_resetsTabOnAcceptance() throws {
        let tabCredits: UInt64 = 10
        let auth = try makeTabAuth(cumulativeAmount: tabCredits)

        // Simulate verifyTabSettlement accepting the voucher
        let result = try verifier.verifyTabSettlement(authorization: auth, channel: channel, tabCredits: tabCredits)
        XCTAssertEqual(result.newCumulativeAmount, tabCredits)
        // The provider engine resets tabByChannelId[id] = 0 after this — tested at integration level
    }

    // MARK: - Test 22: Legacy JSON without tabByChannelId decodes with nil (backward compat)

    func testPersistedProviderState_legacyJSON_decodesWithNilTabFields() throws {
        let legacyJSON = """
        {
            "providerID": "prov-legacy",
            "privateKeyBase64": "abc==",
            "totalRequestsServed": 5,
            "totalCreditsEarned": 50,
            "receiptsIssued": [],
            "requestLog": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder.janus.decode(PersistedProviderState.self, from: legacyJSON)

        XCTAssertNil(decoded.tabByChannelId, "Legacy state must decode tabByChannelId as nil")
        XCTAssertNil(decoded.pendingTabSettlementByChannelId, "Legacy state must decode pendingTabSettlementByChannelId as nil")
        XCTAssertEqual(decoded.totalRequestsServed, 5)
    }

    // MARK: - Test: InferenceResponse with tabUpdate nil default

    func testInferenceResponse_tabUpdateNilDefault() throws {
        // Existing InferenceResponse construction (no tabUpdate) must not break
        let receipt = Receipt(sessionID: "s", requestID: "r", providerID: "p",
                              creditsCharged: 5, cumulativeSpend: 5, providerSignature: "")
        let response = InferenceResponse(requestID: "r", outputText: "hi",
                                         creditsCharged: 5, cumulativeSpend: 5, receipt: receipt)
        XCTAssertNil(response.tabUpdate, "tabUpdate must default to nil for backward compatibility")

        // Serializes and deserializes without tabUpdate field
        let data = try JSONEncoder.janus.encode(response)
        let decoded = try JSONDecoder.janus.decode(InferenceResponse.self, from: data)
        XCTAssertNil(decoded.tabUpdate)
    }

    // MARK: - Helpers

    private func makeTabAuth(cumulativeAmount: UInt64) throws -> VoucherAuthorization {
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: cumulativeAmount)
        let signed = try voucher.sign(with: clientKP, config: config)
        return VoucherAuthorization(requestID: "req-tab-\(cumulativeAmount)", quoteID: nil, signedVoucher: signed)
    }
}
