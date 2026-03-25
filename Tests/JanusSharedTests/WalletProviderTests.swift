import XCTest
@testable import JanusShared

/// Tests for the WalletProvider protocol and LocalWalletProvider implementation.
///
/// Verifies that:
/// - LocalWalletProvider produces identical signatures to direct EthKeyPair signing
/// - Vouchers signed via WalletProvider verify correctly
/// - The protocol abstraction doesn't lose any cryptographic properties
/// - A mock wallet provider can simulate async signing (Privy-like behavior)
final class WalletProviderTests: XCTestCase {

    private let config = TempoConfig.testnet

    // MARK: - LocalWalletProvider: signVoucher

    func testLocalWalletProviderSignsVoucher() async throws {
        let kp = try EthKeyPair()
        let provider = LocalWalletProvider(keyPair: kp)

        let channelId = Keccak256.hash(Data("test-channel".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 42)

        let signed = try await provider.signVoucher(voucher, config: config)

        XCTAssertEqual(signed.voucher, voucher)
        XCTAssertEqual(signed.signatureBytes.count, 65)
    }

    func testLocalWalletProviderSignatureMatchesDirectSigning() async throws {
        let kp = try EthKeyPair()
        let provider = LocalWalletProvider(keyPair: kp)

        let channelId = Keccak256.hash(Data("consistency-test".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 100)

        // Sign via WalletProvider
        let signedViaProvider = try await provider.signVoucher(voucher, config: config)

        // Sign directly with EthKeyPair
        let signedDirect = try voucher.sign(with: kp, config: config)

        // Both should produce the same signature (deterministic signing)
        XCTAssertEqual(signedViaProvider.signature.r, signedDirect.signature.r)
        XCTAssertEqual(signedViaProvider.signature.s, signedDirect.signature.s)
        XCTAssertEqual(signedViaProvider.signature.v, signedDirect.signature.v)
    }

    func testLocalWalletProviderVoucherVerifies() async throws {
        let kp = try EthKeyPair()
        let provider = LocalWalletProvider(keyPair: kp)

        let channelId = Keccak256.hash(Data("verify-test".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 50)

        let signed = try await provider.signVoucher(voucher, config: config)

        // Verify the signature against the keypair's address
        XCTAssertTrue(Voucher.verify(signedVoucher: signed, expectedSigner: kp.address, config: config))
        XCTAssertEqual(provider.address, kp.address)
    }

    func testLocalWalletProviderVoucherRejectsWrongSigner() async throws {
        let kp = try EthKeyPair()
        let otherKP = try EthKeyPair()
        let provider = LocalWalletProvider(keyPair: kp)

        let channelId = Keccak256.hash(Data("wrong-signer-test".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 25)

        let signed = try await provider.signVoucher(voucher, config: config)

        // Should NOT verify against a different address
        XCTAssertFalse(Voucher.verify(signedVoucher: signed, expectedSigner: otherKP.address, config: config))
    }

    // MARK: - LocalWalletProvider: address

    func testLocalWalletProviderAddress() throws {
        let kp = try EthKeyPair()
        let provider = LocalWalletProvider(keyPair: kp)
        XCTAssertEqual(provider.address, kp.address)
    }

    // MARK: - LocalWalletProvider: sendTransaction without RPC

    func testLocalWalletProviderThrowsWithoutRPC() async {
        let kp = try! EthKeyPair()
        let provider = LocalWalletProvider(keyPair: kp) // no rpcURL

        do {
            _ = try await provider.sendTransaction(
                to: kp.address, data: Data(), value: 0, chainId: 1
            )
            XCTFail("Should have thrown WalletProviderError.noRPC")
        } catch let error as WalletProviderError {
            if case .noRPC = error {
                // Expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - MockWalletProvider (simulates Privy-like async signing)

    func testMockWalletProviderSignsVoucher() async throws {
        let kp = try EthKeyPair()
        let mock = MockWalletProvider(keyPair: kp)

        let channelId = Keccak256.hash(Data("mock-test".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 77)

        let signed = try await mock.signVoucher(voucher, config: config)

        // Should verify correctly
        XCTAssertTrue(Voucher.verify(signedVoucher: signed, expectedSigner: kp.address, config: config))
        XCTAssertEqual(mock.signCallCount, 1, "Should have been called exactly once")
    }

    func testMockWalletProviderTracksMultipleCalls() async throws {
        let kp = try EthKeyPair()
        let mock = MockWalletProvider(keyPair: kp)

        let channelId = Keccak256.hash(Data("multi-call".utf8))

        for amount in [10, 20, 30] as [UInt64] {
            let voucher = Voucher(channelId: channelId, cumulativeAmount: amount)
            let signed = try await mock.signVoucher(voucher, config: config)
            XCTAssertTrue(Voucher.verify(signedVoucher: signed, expectedSigner: kp.address, config: config))
        }

        XCTAssertEqual(mock.signCallCount, 3)
    }

    // MARK: - WalletProvider used in VoucherVerifier flow

    func testWalletProviderInFullVerificationFlow() async throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let clientWallet: any WalletProvider = LocalWalletProvider(keyPair: clientKP)

        let salt = Keccak256.hash(Data("full-flow".utf8))
        var channel = Channel(
            payer: clientWallet.address,
            payee: providerKP.address,
            token: config.paymentToken,
            salt: salt,
            authorizedSigner: clientWallet.address,
            deposit: 100,
            config: config
        )

        let verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)

        // Simulate: client signs voucher via WalletProvider
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 15)
        let signed = try await clientWallet.signVoucher(voucher, config: config)

        let quote = QuoteResponse(
            requestID: "req-1", priceCredits: 15,
            priceTier: "medium", expiresAt: Date().addingTimeInterval(60)
        )
        let auth = VoucherAuthorization(
            requestID: "req-1", quoteID: quote.quoteID, signedVoucher: signed
        )

        // Provider verifies
        let result = try verifier.verify(authorization: auth, channel: channel, quote: quote)
        XCTAssertEqual(result.creditsCharged, 15)
        XCTAssertEqual(result.newCumulativeAmount, 15)

        // Accept into channel
        try channel.acceptVoucher(signed)
        XCTAssertEqual(channel.authorizedAmount, 15)
    }

    func testWalletProviderMultiStepVerificationFlow() async throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let clientWallet: any WalletProvider = MockWalletProvider(keyPair: clientKP)

        let salt = Keccak256.hash(Data("multi-step".utf8))
        var channel = Channel(
            payer: clientWallet.address,
            payee: providerKP.address,
            token: config.paymentToken,
            salt: salt,
            authorizedSigner: clientWallet.address,
            deposit: 100,
            config: config
        )

        let verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)

        // Step 1: 10 credits
        let v1 = Voucher(channelId: channel.channelId, cumulativeAmount: 10)
        let s1 = try await clientWallet.signVoucher(v1, config: config)
        let q1 = QuoteResponse(requestID: "r1", priceCredits: 10, priceTier: "small", expiresAt: Date().addingTimeInterval(60))
        let a1 = VoucherAuthorization(requestID: "r1", quoteID: q1.quoteID, signedVoucher: s1)
        _ = try verifier.verify(authorization: a1, channel: channel, quote: q1)
        try channel.acceptVoucher(s1)

        // Step 2: 25 more (cumulative = 35)
        let v2 = Voucher(channelId: channel.channelId, cumulativeAmount: 35)
        let s2 = try await clientWallet.signVoucher(v2, config: config)
        let q2 = QuoteResponse(requestID: "r2", priceCredits: 25, priceTier: "large", expiresAt: Date().addingTimeInterval(60))
        let a2 = VoucherAuthorization(requestID: "r2", quoteID: q2.quoteID, signedVoucher: s2)
        let r2 = try verifier.verify(authorization: a2, channel: channel, quote: q2)
        try channel.acceptVoucher(s2)

        XCTAssertEqual(r2.creditsCharged, 25)
        XCTAssertEqual(channel.authorizedAmount, 35)
    }

    // MARK: - Calldata helpers

    func testApproveCalldataMatchesFullTransaction() throws {
        let spender = try EthAddress(hex: "0x" + String(repeating: "ab", count: 20))
        let amount: UInt64 = 1000

        let calldata = EthTransaction.approveCalldata(spender: spender, amount: amount)
        let fullTx = EthTransaction.approve(
            token: spender, spender: spender, amount: amount,
            nonce: 0, gasPrice: 1, chainId: 1
        )

        XCTAssertEqual(calldata, fullTx.data)
    }

    func testOpenChannelCalldataMatchesFullTransaction() throws {
        let addr = try EthAddress(hex: "0x" + String(repeating: "cd", count: 20))
        let salt = Keccak256.hash(Data("salt".utf8))

        let calldata = EthTransaction.openChannelCalldata(
            payee: addr, token: addr, deposit: 500,
            salt: salt, authorizedSigner: addr
        )
        let fullTx = EthTransaction.openChannel(
            escrow: addr, payee: addr, token: addr, deposit: 500,
            salt: salt, authorizedSigner: addr,
            nonce: 0, gasPrice: 1, chainId: 1
        )

        XCTAssertEqual(calldata, fullTx.data)
    }

    func testSettleChannelCalldataMatchesFullTransaction() throws {
        let addr = try EthAddress(hex: "0x" + String(repeating: "ef", count: 20))
        let channelId = Keccak256.hash(Data("channel".utf8))
        let sig = Data(repeating: 0xAB, count: 65)

        let calldata = EthTransaction.settleChannelCalldata(
            channelId: channelId, cumulativeAmount: 99, voucherSignature: sig
        )
        let fullTx = EthTransaction.settleChannel(
            escrow: addr, channelId: channelId, cumulativeAmount: 99,
            voucherSignature: sig, nonce: 0, gasPrice: 1, chainId: 1
        )

        XCTAssertEqual(calldata, fullTx.data)
    }
}

// MARK: - Mock WalletProvider

/// A test wallet provider that delegates to a local keypair but tracks calls.
/// Simulates the async nature of Privy's MPC signing.
final class MockWalletProvider: WalletProvider, @unchecked Sendable {
    private let keyPair: EthKeyPair
    private(set) var signCallCount = 0
    private(set) var sendTxCallCount = 0

    var address: EthAddress { keyPair.address }

    init(keyPair: EthKeyPair) {
        self.keyPair = keyPair
    }

    func signVoucher(_ voucher: Voucher, config: TempoConfig) async throws -> SignedVoucher {
        signCallCount += 1
        // Simulate async delay (Privy MPC signing takes ~200-500ms)
        try await Task.sleep(nanoseconds: 1_000_000) // 1ms for tests
        return try voucher.sign(with: keyPair, config: config)
    }

    func sendTransaction(to: EthAddress, data: Data, value: UInt64, chainId: UInt64) async throws -> String {
        sendTxCallCount += 1
        throw WalletProviderError.noRPC
    }
}
