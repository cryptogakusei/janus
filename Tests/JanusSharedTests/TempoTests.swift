import XCTest
@testable import JanusShared

final class TempoTests: XCTestCase {

    private let config = TempoConfig.testnet

    // MARK: - Voucher signing and verification

    func testVoucherSignAndVerify() throws {
        let kp = try EthKeyPair()
        let channelId = Keccak256.hash(Data("test-channel".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 100)

        let signed = try voucher.sign(with: kp, config: config)

        XCTAssertEqual(signed.voucher, voucher)
        XCTAssertEqual(signed.signatureBytes.count, 65)
        XCTAssertTrue(Voucher.verify(signedVoucher: signed, expectedSigner: kp.address, config: config))
    }

    func testVoucherRejectsWrongSigner() throws {
        let signer = try EthKeyPair()
        let wrongAddress = try EthKeyPair().address
        let channelId = Keccak256.hash(Data("test-channel".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 50)

        let signed = try voucher.sign(with: signer, config: config)

        XCTAssertFalse(Voucher.verify(signedVoucher: signed, expectedSigner: wrongAddress, config: config))
    }

    func testVoucherRejectsTamperedAmount() throws {
        let kp = try EthKeyPair()
        let channelId = Keccak256.hash(Data("test-channel".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 100)
        let signed = try voucher.sign(with: kp, config: config)

        // Tamper: create a new voucher with a different amount but the same signature
        let tampered = Voucher(channelId: channelId, cumulativeAmount: 999)
        let tamperedSigned = SignedVoucher(voucher: tampered, signature: signed.signature)

        XCTAssertFalse(Voucher.verify(signedVoucher: tamperedSigned, expectedSigner: kp.address, config: config))
    }

    func testVoucherSignableHashDeterministic() throws {
        let channelId = Keccak256.hash(Data("deterministic".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 42)

        let hash1 = voucher.signableHash(config: config)
        let hash2 = voucher.signableHash(config: config)
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 32)
    }

    func testVoucherStructHashDiffersForDifferentAmounts() {
        let channelId = Keccak256.hash(Data("channel".utf8))
        let v1 = Voucher(channelId: channelId, cumulativeAmount: 100)
        let v2 = Voucher(channelId: channelId, cumulativeAmount: 200)
        XCTAssertNotEqual(v1.structHash, v2.structHash)
    }

    // MARK: - Address recovery

    func testRecoverAddressRoundTrip() throws {
        let kp = try EthKeyPair()
        let messageHash = Keccak256.hash(Data("test message".utf8))
        let sig = try kp.signRecoverable(messageHash: messageHash)

        let recovered = try recoverAddress(messageHash: messageHash, signature: sig)
        XCTAssertEqual(recovered, kp.address)
    }

    // MARK: - Channel ID computation

    func testChannelIdDeterministic() throws {
        let payer = try EthKeyPair().address
        let payee = try EthKeyPair().address
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("salt-1".utf8))
        let signer = payer

        let id1 = Channel.computeId(payer: payer, payee: payee, token: token,
                                     salt: salt, authorizedSigner: signer, config: config)
        let id2 = Channel.computeId(payer: payer, payee: payee, token: token,
                                     salt: salt, authorizedSigner: signer, config: config)
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id1.count, 32)
    }

    func testChannelIdDiffersForDifferentParams() throws {
        let payer = try EthKeyPair().address
        let payee = try EthKeyPair().address
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt1 = Keccak256.hash(Data("salt-1".utf8))
        let salt2 = Keccak256.hash(Data("salt-2".utf8))

        let id1 = Channel.computeId(payer: payer, payee: payee, token: token,
                                     salt: salt1, authorizedSigner: payer, config: config)
        let id2 = Channel.computeId(payer: payer, payee: payee, token: token,
                                     salt: salt2, authorizedSigner: payer, config: config)
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - Channel lifecycle

    func testChannelCreation() throws {
        let payer = try EthKeyPair().address
        let payee = try EthKeyPair().address
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("test".utf8))

        let channel = Channel(payer: payer, payee: payee, token: token,
                              salt: salt, authorizedSigner: payer, deposit: 1000, config: config)

        XCTAssertEqual(channel.state, .open)
        XCTAssertEqual(channel.deposit, 1000)
        XCTAssertEqual(channel.settledAmount, 0)
        XCTAssertEqual(channel.remainingDeposit, 1000)
        XCTAssertNil(channel.latestVoucher)
        XCTAssertEqual(channel.channelId.count, 32)
    }

    func testChannelAcceptVoucher() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("session-1".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)

        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 100)
        let signed = try voucher.sign(with: clientKP, config: config)

        try channel.acceptVoucher(signed)
        XCTAssertEqual(channel.authorizedAmount, 100)
        XCTAssertEqual(channel.unsettledAmount, 100)
    }

    func testChannelRejectsNonMonotonicVoucher() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("session-1".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)

        // Accept voucher for 100
        let v1 = Voucher(channelId: channel.channelId, cumulativeAmount: 100)
        try channel.acceptVoucher(try v1.sign(with: clientKP, config: config))

        // Try to accept voucher for 50 (lower) — should fail
        let v2 = Voucher(channelId: channel.channelId, cumulativeAmount: 50)
        XCTAssertThrowsError(try channel.acceptVoucher(try v2.sign(with: clientKP, config: config))) { error in
            XCTAssertEqual(error as? ChannelError, .nonMonotonicVoucher)
        }
    }

    func testChannelRejectsExceedingDeposit() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("session-1".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 100, config: config)

        // Try to authorize more than the deposit
        let v = Voucher(channelId: channel.channelId, cumulativeAmount: 150)
        XCTAssertThrowsError(try channel.acceptVoucher(try v.sign(with: clientKP, config: config))) { error in
            XCTAssertEqual(error as? ChannelError, .exceedsDeposit)
        }
    }

    func testChannelRejectsWrongChannelId() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("session-1".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)

        // Voucher for a different channel
        let wrongChannelId = Keccak256.hash(Data("wrong-channel".utf8))
        let v = Voucher(channelId: wrongChannelId, cumulativeAmount: 100)
        XCTAssertThrowsError(try channel.acceptVoucher(try v.sign(with: clientKP, config: config))) { error in
            XCTAssertEqual(error as? ChannelError, .wrongChannel)
        }
    }

    func testChannelSettlement() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("session-1".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)

        // Accept voucher and settle
        let v = Voucher(channelId: channel.channelId, cumulativeAmount: 300)
        try channel.acceptVoucher(try v.sign(with: clientKP, config: config))

        channel.recordSettlement(amount: 300)
        XCTAssertEqual(channel.settledAmount, 300)
        XCTAssertEqual(channel.remainingDeposit, 700)
        XCTAssertEqual(channel.unsettledAmount, 0) // all authorized amount is now settled
    }

    func testChannelRecordTopUp_updatesCreditAvailability() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("top-up-test".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 100, config: config)

        // At deposit=100, amount 120 is rejected
        XCTAssertFalse(channel.canAuthorize(cumulativeAmount: 120), "Must not authorize above deposit")

        // After top-up to 150, amount 120 is accepted
        channel.recordTopUp(newDeposit: 150)
        XCTAssertEqual(channel.deposit, 150)
        XCTAssertTrue(channel.canAuthorize(cumulativeAmount: 120), "Must authorize after top-up increases deposit")
    }

    func testMultipleVouchersMonotonic() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("session-1".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)

        // Simulate 3 requests with increasing cumulative amounts
        for amount in [100, 250, 500] as [UInt64] {
            let v = Voucher(channelId: channel.channelId, cumulativeAmount: amount)
            let signed = try v.sign(with: clientKP, config: config)
            try channel.acceptVoucher(signed)

            // Verify each voucher
            XCTAssertTrue(Voucher.verify(signedVoucher: signed, expectedSigner: clientKP.address, config: config))
        }

        XCTAssertEqual(channel.authorizedAmount, 500)
        XCTAssertEqual(channel.unsettledAmount, 500)
    }

    // MARK: - Codable round-trips

    func testVoucherCodable() throws {
        let channelId = Keccak256.hash(Data("codable-test".utf8))
        let voucher = Voucher(channelId: channelId, cumulativeAmount: 42)

        let data = try JSONEncoder().encode(voucher)
        let decoded = try JSONDecoder().decode(Voucher.self, from: data)
        XCTAssertEqual(decoded, voucher)
    }

    func testChannelCodable() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("codable".utf8))

        let channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 500, config: config)

        let data = try JSONEncoder().encode(channel)
        let decoded = try JSONDecoder().decode(Channel.self, from: data)
        XCTAssertEqual(decoded.channelId, channel.channelId)
        XCTAssertEqual(decoded.deposit, 500)
        XCTAssertEqual(decoded.state, .open)
    }

    /// Channel with a SignedVoucher survives JSON round-trip with crypto integrity intact.
    /// Critical for #12b — persisted channels must produce valid on-chain settlement signatures.
    func testChannelWithVoucherCodableRoundTrip() throws {
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let token = EthAddress(Data(repeating: 0, count: 20))
        let salt = Keccak256.hash(Data("voucher-codable".utf8))

        var channel = Channel(payer: clientKP.address, payee: providerKP.address,
                              token: token, salt: salt, authorizedSigner: clientKP.address,
                              deposit: 1000, config: config)

        // Accept a voucher so the channel has a SignedVoucher with real ECDSA signature bytes
        let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: 300)
        let signed = try voucher.sign(with: clientKP, config: config)
        try channel.acceptVoucher(signed)

        // Round-trip through JSON (using JanusStore's encoder for fidelity)
        let data = try JSONEncoder.janus.encode(channel)
        let decoded = try JSONDecoder.janus.decode(Channel.self, from: data)

        // Structural equality
        XCTAssertEqual(decoded.channelId, channel.channelId)
        XCTAssertEqual(decoded.deposit, 1000)
        XCTAssertEqual(decoded.authorizedAmount, 300)
        XCTAssertEqual(decoded.unsettledAmount, 300)
        XCTAssertNotNil(decoded.latestVoucher)

        // Crypto integrity — the signature must still verify against the original signer
        XCTAssertTrue(
            Voucher.verify(signedVoucher: decoded.latestVoucher!, expectedSigner: clientKP.address, config: config),
            "Voucher signature must remain valid after JSON round-trip — this is what gets submitted on-chain"
        )

        // Signature bytes must be identical (not just valid — exact match)
        XCTAssertEqual(decoded.latestVoucher!.signatureBytes, signed.signatureBytes,
                       "Signature bytes must be preserved exactly through serialization")
    }
}
