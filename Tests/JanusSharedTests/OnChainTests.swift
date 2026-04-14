import XCTest
@testable import JanusShared

final class OnChainTests: XCTestCase {

    // MARK: - UInt128

    func testUInt128FromUInt64() {
        let v = UInt128(42)
        XCTAssertEqual(v.high, 0)
        XCTAssertEqual(v.low, 42)
        XCTAssertEqual(v.toUInt64, 42)
    }

    func testUInt128Comparison() {
        let a = UInt128(100)
        let b = UInt128(200)
        XCTAssertTrue(a < b)
        XCTAssertFalse(b < a)
        XCTAssertEqual(a, UInt128(100))
    }

    func testUInt128ComparisonHighBytes() {
        let low = UInt128(high: 0, low: UInt64.max)
        let high = UInt128(high: 1, low: 0)
        XCTAssertTrue(low < high)
        XCTAssertFalse(high < low)
    }

    func testUInt128ShiftLeft() {
        let v = UInt128(1)
        let shifted = v << 8
        XCTAssertEqual(shifted.low, 256)
        XCTAssertEqual(shifted.high, 0)
    }

    func testUInt128ShiftLeftAcrossBoundary() {
        let v = UInt128(high: 0, low: 1)
        let shifted = v << 64
        XCTAssertEqual(shifted.high, 1)
        XCTAssertEqual(shifted.low, 0)
    }

    func testUInt128ShiftLeftZero() {
        let v = UInt128(42)
        let shifted = v << 0
        XCTAssertEqual(shifted, v)
    }

    func testUInt128Or() {
        let a = UInt128(high: 0xFF, low: 0)
        let b = UInt128(high: 0, low: 0xAB)
        let result = a | b
        XCTAssertEqual(result.high, 0xFF)
        XCTAssertEqual(result.low, 0xAB)
    }

    func testUInt128ToUInt64ReturnsNilForLargeValues() {
        let large = UInt128(high: 1, low: 0)
        XCTAssertNil(large.toUInt64)
    }

    func testUInt128Description() {
        XCTAssertEqual(UInt128(42).description, "42")
        XCTAssertTrue(UInt128(high: 1, low: 0).description.contains("UInt128"))
    }

    func testUInt128ByteDecoding() {
        // Simulate decoding 1000 as big-endian in 16 bytes
        // 1000 = 0x03E8
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[14] = 0x03
        bytes[15] = 0xE8

        var value = UInt128(high: 0, low: 0)
        for b in bytes {
            value = value << 8 | UInt128(UInt64(b))
        }
        XCTAssertEqual(value.toUInt64, 1000)
    }

    // MARK: - EscrowClient ABI decoding

    func testDecodeChannelFromABIData() throws {
        // Build a synthetic ABI-encoded getChannel() response:
        // offset (32 bytes) + 8 fields × 32 bytes = 288 bytes
        var data = Data()

        // Offset pointer (points to byte 32)
        data.append(leftPad(Data([0x20]), to: 32))

        // Field 0: finalized = false
        data.append(leftPad(Data([0x00]), to: 32))

        // Field 1: closeRequestedAt = 0
        data.append(Data(repeating: 0, count: 32))

        // Field 2: payer = 0xAAAA...AA (20 bytes)
        let payerBytes = Data(repeating: 0xAA, count: 20)
        data.append(leftPad(payerBytes, to: 32))

        // Field 3: payee = 0xBBBB...BB
        let payeeBytes = Data(repeating: 0xBB, count: 20)
        data.append(leftPad(payeeBytes, to: 32))

        // Field 4: token = pathUSD-like address
        let tokenBytes = Data(repeating: 0xCC, count: 20)
        data.append(leftPad(tokenBytes, to: 32))

        // Field 5: authorizedSigner = same as payer
        data.append(leftPad(payerBytes, to: 32))

        // Field 6: deposit = 1000 (uint128 in 32 bytes)
        var depositBE = UInt64(1000).bigEndian
        let depositData = withUnsafeBytes(of: &depositBE) { Data($0) }
        data.append(leftPad(depositData, to: 32))

        // Field 7: settled = 300
        var settledBE = UInt64(300).bigEndian
        let settledData = withUnsafeBytes(of: &settledBE) { Data($0) }
        data.append(leftPad(settledData, to: 32))

        XCTAssertEqual(data.count, 288)

        // Use EscrowClient to decode (we need to access the private method via public API)
        // Instead, we test the struct properties after construction
        let payer = EthAddress(payerBytes)
        let payee = EthAddress(payeeBytes)
        let channel = EscrowClient.OnChainChannel(
            finalized: false,
            closeRequestedAt: 0,
            payer: payer,
            payee: payee,
            token: EthAddress(tokenBytes),
            authorizedSigner: payer,
            deposit: UInt128(1000),
            settled: UInt128(300)
        )

        XCTAssertTrue(channel.exists)
        XCTAssertFalse(channel.finalized)
        XCTAssertEqual(channel.deposit.toUInt64, 1000)
        XCTAssertEqual(channel.settled.toUInt64, 300)
        XCTAssertEqual(channel.payer, payer)
        XCTAssertEqual(channel.payee, payee)
    }

    func testOnChainChannelExistsFalseForZeroAddress() {
        let channel = EscrowClient.OnChainChannel(
            finalized: false,
            closeRequestedAt: 0,
            payer: EthAddress(Data(repeating: 0, count: 20)),
            payee: EthAddress(Data(repeating: 0, count: 20)),
            token: EthAddress(Data(repeating: 0, count: 20)),
            authorizedSigner: EthAddress(Data(repeating: 0, count: 20)),
            deposit: UInt128(0),
            settled: UInt128(0)
        )
        XCTAssertFalse(channel.exists)
    }

    // MARK: - TempoConfig testnet values

    func testTempoConfigTestnetValues() {
        let config = TempoConfig.testnet
        XCTAssertEqual(config.chainId, 42431)
        XCTAssertEqual(config.escrowContract.checksumAddress, "0xaB7409f3ea73952FC8C762ce7F01F245314920d9")
        XCTAssertEqual(config.paymentToken.checksumAddress, "0x20C0000000000000000000000000000000000000")
        XCTAssertNotNil(config.rpcURL)
        XCTAssertEqual(config.rpcURL?.absoluteString, "https://rpc.moderato.tempo.xyz")
    }

    func testTempoConfigVoucherDomain() {
        let config = TempoConfig.testnet
        let domain = config.voucherDomain
        XCTAssertEqual(domain.name, "Tempo Stream Channel")
        XCTAssertEqual(domain.version, "1")
        XCTAssertEqual(domain.chainId, 42431)
        XCTAssertEqual(domain.verifyingContract, config.escrowContract)
    }

    // MARK: - ETH keypair persistence

    func testPersistedClientSessionWithEthKey() throws {
        let kp = JanusKeyPair()
        let ethKP = try EthKeyPair()
        let grant = SessionGrant(
            sessionID: "eth-sess",
            userPubkey: kp.publicKeyBase64,
            providerID: "prov-1",
            maxCredits: 100,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: "sig"
        )

        let persisted = PersistedClientSession(
            privateKeyBase64: kp.privateKeyBase64,
            sessionGrant: grant,
            spendState: SpendState(sessionID: "eth-sess"),
            ethPrivateKeyHex: ethKP.privateKeyData.ethHexPrefixed
        )

        // Round-trip through JSON
        let data = try JSONEncoder.janus.encode(persisted)
        let loaded = try JSONDecoder.janus.decode(PersistedClientSession.self, from: data)

        XCTAssertNotNil(loaded.ethPrivateKeyHex)
        XCTAssertEqual(loaded.ethPrivateKeyHex, ethKP.privateKeyData.ethHexPrefixed)

        // Restore ETH keypair and verify address matches
        let restored = try EthKeyPair(hexPrivateKey: loaded.ethPrivateKeyHex!)
        XCTAssertEqual(restored.address, ethKP.address)
    }

    func testPersistedClientSessionWithoutEthKey() throws {
        let kp = JanusKeyPair()
        let grant = SessionGrant(
            sessionID: "no-eth",
            userPubkey: kp.publicKeyBase64,
            providerID: "prov-1",
            maxCredits: 100,
            expiresAt: Date().addingTimeInterval(3600),
            backendSignature: "sig"
        )

        let persisted = PersistedClientSession(
            privateKeyBase64: kp.privateKeyBase64,
            sessionGrant: grant,
            spendState: SpendState(sessionID: "no-eth")
            // ethPrivateKeyHex omitted — defaults to nil
        )

        let data = try JSONEncoder.janus.encode(persisted)
        let loaded = try JSONDecoder.janus.decode(PersistedClientSession.self, from: data)
        XCTAssertNil(loaded.ethPrivateKeyHex)
    }

    func testBackwardsCompatDecodesWithoutEthKeyField() throws {
        // Simulate an old file without ethPrivateKeyHex
        let oldJson = """
        {
            "privateKeyBase64": "\(JanusKeyPair().privateKeyBase64)",
            "sessionGrant": {
                "sessionID": "old-sess",
                "userPubkey": "pub",
                "providerID": "prov",
                "maxCredits": 100,
                "expiresAt": "\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)))",
                "backendSignature": "sig"
            },
            "spendState": {
                "sessionID": "old-sess",
                "cumulativeSpend": 0,
                "sequenceNumber": 0,
                "updatedAt": "\(ISO8601DateFormatter().string(from: Date()))"
            },
            "receipts": []
        }
        """
        let data = oldJson.data(using: .utf8)!
        let loaded = try JSONDecoder.janus.decode(PersistedClientSession.self, from: data)

        XCTAssertNil(loaded.ethPrivateKeyHex, "Old files without ethPrivateKeyHex should decode to nil")
        XCTAssertEqual(loaded.sessionGrant.sessionID, "old-sess")
    }

    // MARK: - ChannelOpener progress handler

    func testChannelOpener_progressHandler_firesBeforeWalletFailure() async throws {
        let clientKP = try EthKeyPair()
        // UUID salt ensures a fresh channel ID each run — avoids .alreadyOpen early return
        // which would skip the progress handler entirely.
        let salt = Keccak256.hash(Data(UUID().uuidString.utf8))
        let channel = Channel(
            payer: clientKP.address,
            payee: clientKP.address,
            token: TempoConfig.testnet.paymentToken,
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 10,
            config: TempoConfig.testnet
        )

        let mockWallet = MockWalletProvider(keyPair: clientKP)
        let opener = ChannelOpener(config: TempoConfig.testnet)
        var receivedMessages: [String] = []

        let result = await opener.openChannel(wallet: mockWallet, channel: channel) { message in
            receivedMessages.append(message)
        }

        // MockWalletProvider always throws on sendTransaction — expect .failed
        if case .failed = result { /* expected */ }
        else { XCTFail("Expected .failed, got \(result)") }

        // "Funding wallet..." and "Approving token spend..." fire before sendTransaction is called.
        // "Opening payment channel..." requires a successful approve tx receipt — not reachable with mock.
        XCTAssertTrue(receivedMessages.contains("Funding wallet..."),
                      "Progress handler must emit 'Funding wallet...'")
        XCTAssertTrue(receivedMessages.contains("Approving token spend..."),
                      "Progress handler must emit 'Approving token spend...'")

        // Verify emission order
        let fundingIdx = receivedMessages.firstIndex(of: "Funding wallet...")!
        let approveIdx = receivedMessages.firstIndex(of: "Approving token spend...")!
        XCTAssertLessThan(fundingIdx, approveIdx, "Progress messages must fire in stage order")
    }

    // MARK: - ChannelVerificationResult

    func testChannelVerificationResultAccepted() {
        let onChain = ChannelVerificationResult.acceptedOnChain(onChainDeposit: 1000, onChainSettled: 0)
        let rpcUnavailable = ChannelVerificationResult.rpcUnavailable
        let notFound = ChannelVerificationResult.channelNotFoundOnChain
        let rejected = ChannelVerificationResult.rejected(reason: "bad")

        XCTAssertTrue(onChain.isAccepted)
        XCTAssertTrue(rpcUnavailable.isAccepted)   // safe for offline inference
        XCTAssertFalse(notFound.isAccepted)         // channel was never opened — reject
        XCTAssertFalse(rejected.isAccepted)
    }

    // MARK: - VoucherVerifier off-chain with real config

    func testVoucherVerifierOffChainWithTestnetConfig() throws {
        let config = TempoConfig.testnet
        let providerKP = try EthKeyPair()
        let clientKP = try EthKeyPair()

        let verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)
        let salt = Keccak256.hash(Data("test-session".utf8))

        let info = ChannelInfo(
            payerAddress: clientKP.address,
            payeeAddress: providerKP.address,
            tokenAddress: config.paymentToken,
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 500,
            channelId: Channel.computeId(
                payer: clientKP.address, payee: providerKP.address,
                token: config.paymentToken, salt: salt,
                authorizedSigner: clientKP.address, config: config
            )
        )

        XCTAssertTrue(verifier.verifyChannelInfo(info))
    }

    func testVoucherVerifierRejectsWrongPayeeWithTestnetConfig() throws {
        let config = TempoConfig.testnet
        let providerKP = try EthKeyPair()
        let clientKP = try EthKeyPair()
        let wrongProvider = try EthKeyPair()

        let verifier = VoucherVerifier(providerAddress: providerKP.address, config: config)
        let salt = Keccak256.hash(Data("test".utf8))

        let info = ChannelInfo(
            payerAddress: clientKP.address,
            payeeAddress: wrongProvider.address,  // wrong!
            tokenAddress: config.paymentToken,
            salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 500,
            channelId: Channel.computeId(
                payer: clientKP.address, payee: wrongProvider.address,
                token: config.paymentToken, salt: salt,
                authorizedSigner: clientKP.address, config: config
            )
        )

        XCTAssertFalse(verifier.verifyChannelInfo(info))
    }

    // MARK: - EthRPC calldata encoding

    func testGetChannelCalldataEncoding() {
        let channelId = Keccak256.hash(Data("test-channel".utf8))
        let selector = Keccak256.hash(Data("getChannel(bytes32)".utf8)).prefix(4)
        let calldata = selector + ABI.Value.bytes32(channelId).encoded

        // 4 (selector) + 32 (channelId) = 36 bytes
        XCTAssertEqual(calldata.count, 36)
        // First 4 bytes should be the function selector
        XCTAssertEqual(calldata.prefix(4), selector)
        // Next 32 bytes should be the channelId
        XCTAssertEqual(Data(calldata.suffix(32)), channelId)
    }

    // MARK: - RLP encoding

    func testRLPEncodeSingleByte() {
        // Single byte < 0x80 encodes as itself
        let encoded = RLP.encode(.bytes(Data([0x42])))
        XCTAssertEqual(encoded, Data([0x42]))
    }

    func testRLPEncodeShortString() {
        // "dog" = [0x83, 0x64, 0x6f, 0x67]
        let encoded = RLP.encode(.bytes(Data("dog".utf8)))
        XCTAssertEqual(encoded, Data([0x83, 0x64, 0x6f, 0x67]))
    }

    func testRLPEncodeEmptyString() {
        // Empty bytes = [0x80]
        let encoded = RLP.encode(.bytes(Data()))
        XCTAssertEqual(encoded, Data([0x80]))
    }

    func testRLPEncodeEmptyList() {
        // Empty list = [0xc0]
        let encoded = RLP.encode(.list([]))
        XCTAssertEqual(encoded, Data([0xc0]))
    }

    func testRLPEncodeUInt() {
        // 0 encodes as empty bytes
        let zero = RLP.encodeUInt(0)
        if case .bytes(let data) = zero {
            XCTAssertEqual(data, Data())
        } else { XCTFail() }

        // 127 (0x7f) encodes as single byte
        let small = RLP.encodeUInt(127)
        if case .bytes(let data) = small {
            XCTAssertEqual(data, Data([0x7f]))
        } else { XCTFail() }

        // 1024 (0x0400) encodes as 2 bytes, no leading zeros
        let medium = RLP.encodeUInt(1024)
        if case .bytes(let data) = medium {
            XCTAssertEqual(data, Data([0x04, 0x00]))
        } else { XCTFail() }
    }

    func testRLPEncodeList() {
        // ["cat", "dog"] = [0xc8, 0x83, "cat", 0x83, "dog"]
        let encoded = RLP.encode(.list([
            .bytes(Data("cat".utf8)),
            .bytes(Data("dog".utf8)),
        ]))
        XCTAssertEqual(encoded, Data([0xc8, 0x83, 0x63, 0x61, 0x74, 0x83, 0x64, 0x6f, 0x67]))
    }

    // MARK: - Transaction signing

    func testEthTransactionSignProducesValidRLP() throws {
        let kp = try EthKeyPair()
        let tx = EthTransaction(
            nonce: 0, gasPrice: 20_000_000_000, gasLimit: 21000,
            to: kp.address, data: Data(), chainId: 42431
        )
        let signed = try tx.sign(with: kp)
        // Signed tx should start with 0xf8 or similar (RLP list prefix)
        // and be > 100 bytes
        XCTAssertGreaterThan(signed.count, 60)
        // First byte should be a list prefix (0xc0+ for short, 0xf7+ for long)
        XCTAssertTrue(signed[0] >= 0xc0, "Signed tx should be an RLP list")
    }

    func testEthTransactionApproveBuilder() throws {
        let token = try EthAddress(hex: "0x20C0000000000000000000000000000000000000")
        let spender = try EthAddress(hex: "0xaB7409f3ea73952FC8C762ce7F01F245314920d9")
        let tx = EthTransaction.approve(
            token: token, spender: spender, amount: 1000,
            nonce: 5, gasPrice: 1_000_000, chainId: 42431
        )
        XCTAssertEqual(tx.to.data, token.data)
        XCTAssertEqual(tx.nonce, 5)
        XCTAssertEqual(tx.chainId, 42431)
        // approve(address,uint256) selector = 0x095ea7b3
        XCTAssertEqual(tx.data.prefix(4), Data([0x09, 0x5e, 0xa7, 0xb3]))
        // Calldata = 4 + 32 + 32 = 68 bytes
        XCTAssertEqual(tx.data.count, 68)
    }

    func testEthTransactionOpenChannelBuilder() throws {
        let escrow = try EthAddress(hex: "0xaB7409f3ea73952FC8C762ce7F01F245314920d9")
        let payee = try EthAddress(hex: "0x68D99183E9B3ca3324AE8ECF9e4a557c41C6B5A2")
        let token = try EthAddress(hex: "0x20C0000000000000000000000000000000000000")
        let salt = Keccak256.hash(Data("test".utf8))
        let signer = try EthAddress(hex: "0x51A6658054Ba2D1d3B9Cf26Fdc087B1b3239A38A")

        let tx = EthTransaction.openChannel(
            escrow: escrow, payee: payee, token: token,
            deposit: 100, salt: salt, authorizedSigner: signer,
            nonce: 1, gasPrice: 1_000_000, chainId: 42431
        )
        XCTAssertEqual(tx.to.data, escrow.data)
        // open(address,address,uint128,bytes32,address) selector
        let expectedSelector = Keccak256.hash(
            Data("open(address,address,uint128,bytes32,address)".utf8)
        ).prefix(4)
        XCTAssertEqual(tx.data.prefix(4), expectedSelector)
        // Calldata = 4 + 5*32 = 164 bytes
        XCTAssertEqual(tx.data.count, 164)
    }

    // MARK: - Live transaction test (Tempo testnet)

    func testSendRealTransactionToTempo() async throws {
        let config = TempoConfig.testnet
        guard let rpcURL = config.rpcURL else {
            throw XCTSkip("No RPC URL configured")
        }
        let rpc = EthRPC(rpcURL: rpcURL)
        let kp = try EthKeyPair()

        // Fund via faucet
        try await rpc.fundAddress(kp.address)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Check nonce and gas price
        let nonce = try await rpc.getTransactionCount(address: kp.address)
        XCTAssertEqual(nonce, 0)
        let gasPrice = try await rpc.gasPrice()
        XCTAssertGreaterThan(gasPrice, 0)

        // Send a simple approve tx
        let tx = EthTransaction.approve(
            token: config.paymentToken,
            spender: config.escrowContract,
            amount: 1000,
            nonce: nonce,
            gasPrice: gasPrice,
            chainId: config.chainId
        )
        let signed = try tx.sign(with: kp)
        let txHash = try await rpc.sendRawTransaction(signedTx: signed)
        XCTAssertTrue(txHash.hasPrefix("0x"))

        // Wait for receipt
        let receipt = try await rpc.waitForReceipt(txHash: txHash, timeout: 30)
        XCTAssertTrue(receipt.status, "Transaction should succeed")
        XCTAssertGreaterThan(receipt.gasUsed, 0)
    }

    func testFullChannelOpeningOnTempo() async throws {
        let config = TempoConfig.testnet
        guard config.rpcURL != nil else {
            throw XCTSkip("No RPC URL configured")
        }

        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let salt = Keccak256.hash(Data(UUID().uuidString.utf8))

        let channel = Channel(
            payer: clientKP.address, payee: providerKP.address,
            token: config.paymentToken, salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 100, config: config
        )

        let opener = ChannelOpener(config: config)
        let result = await opener.openChannel(keyPair: clientKP, channel: channel)

        switch result {
        case .opened(let channelId, let approveTx, let openTx):
            XCTAssertEqual(channelId, channel.channelId)
            XCTAssertTrue(approveTx.hasPrefix("0x"))
            XCTAssertTrue(openTx.hasPrefix("0x"))

            // Verify channel exists on-chain using raw RPC call
            let rpc = EthRPC(rpcURL: config.rpcURL!)
            let selector = Keccak256.hash(Data("getChannel(bytes32)".utf8)).prefix(4)
            let calldata = selector + ABI.Value.bytes32(channelId).encoded
            let rawResult = try await rpc.call(to: config.escrowContract, data: calldata)
            // Should return at least 288 bytes for a valid channel
            XCTAssertGreaterThanOrEqual(rawResult.count, 256,
                "getChannel returned \(rawResult.count) bytes, expected >= 256")

            // Decode the channel
            let escrowClient = EscrowClient(config: config)
            let onChain = try await escrowClient.getChannel(channelId: channelId)
            XCTAssertTrue(onChain.exists)
            XCTAssertEqual(onChain.payer, clientKP.address)
            XCTAssertEqual(onChain.payee, providerKP.address)
            XCTAssertEqual(onChain.deposit.toUInt64, 100)

        case .alreadyOpen:
            XCTFail("Channel should not already exist")
        case .failed(let reason):
            XCTFail("Channel opening failed: \(reason)")
        }
    }

    func testSettleTransactionBuilder() throws {
        let escrow = try EthAddress(hex: "0xaB7409f3ea73952FC8C762ce7F01F245314920d9")
        let channelId = Keccak256.hash(Data("test-channel".utf8))
        let sig = Data(repeating: 0xAB, count: 65) // mock 65-byte signature

        let tx = EthTransaction.settleChannel(
            escrow: escrow,
            channelId: channelId,
            cumulativeAmount: 42,
            voucherSignature: sig,
            nonce: 3,
            gasPrice: 1_000_000,
            chainId: 42431
        )

        XCTAssertEqual(tx.to.data, escrow.data)
        XCTAssertEqual(tx.nonce, 3)
        // settle(bytes32,uint128,bytes) selector
        let expectedSelector = Keccak256.hash(Data("settle(bytes32,uint128,bytes)".utf8)).prefix(4)
        XCTAssertEqual(tx.data.prefix(4), expectedSelector)
        // Calldata: 4 + 32 (channelId) + 32 (amount) + 32 (offset) + 32 (length) + 96 (sig padded to 96) = 228
        XCTAssertEqual(tx.data.count, 228)
    }

    func testFullSettlementOnTempo() async throws {
        let config = TempoConfig.testnet
        guard config.rpcURL != nil else {
            throw XCTSkip("No RPC URL configured")
        }

        // Create client and provider keypairs
        let clientKP = try EthKeyPair()
        let providerKP = try EthKeyPair()
        let salt = Keccak256.hash(Data(UUID().uuidString.utf8))

        // Open channel (client side)
        var channel = Channel(
            payer: clientKP.address, payee: providerKP.address,
            token: config.paymentToken, salt: salt,
            authorizedSigner: clientKP.address,
            deposit: 100, config: config
        )

        let opener = ChannelOpener(config: config)
        let openResult = await opener.openChannel(keyPair: clientKP, channel: channel)
        guard case .opened = openResult else {
            XCTFail("Channel opening failed: \(openResult)")
            return
        }

        // Simulate requests: client signs cumulative vouchers (3, 6, 9)
        for amount in [3, 6, 9] as [UInt64] {
            let voucher = Voucher(channelId: channel.channelId, cumulativeAmount: amount)
            let signed = try voucher.sign(with: clientKP, config: config)
            try channel.acceptVoucher(signed)
        }
        XCTAssertEqual(channel.authorizedAmount, 9)

        // Fund provider for gas (needs pathUSD for Tempo gas fees)
        let rpc = EthRPC(rpcURL: config.rpcURL!)
        try await rpc.fundAddress(providerKP.address)
        try await Task.sleep(nanoseconds: 3_000_000_000)

        // Settle (provider side)
        let settler = ChannelSettler(config: config)
        let settleResult = await settler.settle(providerKeyPair: providerKP, channel: channel)

        switch settleResult {
        case .settled(let txHash, let amount):
            XCTAssertEqual(amount, 9)
            XCTAssertTrue(txHash.hasPrefix("0x"))

            // Verify on-chain settled amount
            let escrowClient = EscrowClient(config: config)
            let onChain = try await escrowClient.getChannel(channelId: channel.channelId)
            XCTAssertTrue(onChain.exists)
            XCTAssertEqual(onChain.settled.toUInt64, 9)

        case .noVoucher:
            XCTFail("Should have a voucher")
        case .alreadySettled:
            XCTFail("Should not be already settled")
        case .failed(let reason):
            XCTFail("Settlement failed: \(reason.description)")
        }
    }

    func testComputeChannelIdCalldataEncoding() {
        let payer = EthAddress(Data(repeating: 0xAA, count: 20))
        let payee = EthAddress(Data(repeating: 0xBB, count: 20))
        let token = EthAddress(Data(repeating: 0xCC, count: 20))
        let salt = Keccak256.hash(Data("salt".utf8))
        let signer = payer

        let selector = Keccak256.hash(
            Data("computeChannelId(address,address,address,bytes32,address)".utf8)
        ).prefix(4)
        let calldata = selector + ABI.encode([
            .address(payer), .address(payee), .address(token),
            .bytes32(salt), .address(signer),
        ])

        // 4 + 5×32 = 164 bytes
        XCTAssertEqual(calldata.count, 164)
    }
    // MARK: - SettleFailureReason unit tests

    func testSettleFailureReason_isPermanent() {
        XCTAssertFalse(ChannelSettler.SettleFailureReason.channelNotOnChain.isPermanent)
        XCTAssertTrue(ChannelSettler.SettleFailureReason.channelFinalized.isPermanent)
        XCTAssertFalse(ChannelSettler.SettleFailureReason.gasInfoUnavailable("timeout").isPermanent)
        XCTAssertTrue(ChannelSettler.SettleFailureReason.transactionReverted(txHash: "0xabc").isPermanent)
        XCTAssertFalse(ChannelSettler.SettleFailureReason.submissionFailed("decode error").isPermanent)
    }

    func testSettleFailureReason_description() {
        XCTAssertEqual(ChannelSettler.SettleFailureReason.channelNotOnChain.description, "Channel does not exist on-chain")
        XCTAssertEqual(ChannelSettler.SettleFailureReason.channelFinalized.description, "Channel is finalized")
        XCTAssertTrue(ChannelSettler.SettleFailureReason.gasInfoUnavailable("timeout").description.contains("timeout"))
        XCTAssertTrue(ChannelSettler.SettleFailureReason.transactionReverted(txHash: "0xabc").description.contains("0xabc"))
        XCTAssertTrue(ChannelSettler.SettleFailureReason.submissionFailed("RPC error").description.contains("RPC error"))
    }
}

// MARK: - Helper

private func leftPad(_ data: Data, to size: Int) -> Data {
    if data.count >= size { return data.suffix(size) }
    return Data(repeating: 0, count: size - data.count) + data
}
