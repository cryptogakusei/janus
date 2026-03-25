import XCTest
@testable import JanusShared

final class EthereumTests: XCTestCase {

    // MARK: - Keccak256 test vectors

    func testKeccak256EmptyString() {
        // keccak256("") — well-known test vector
        let hash = Keccak256.hash(Data())
        XCTAssertEqual(
            hash.ethHex,
            "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
        )
    }

    func testKeccak256HelloWorld() {
        // keccak256("hello world")
        let hash = Keccak256.hash(Data("hello world".utf8))
        XCTAssertEqual(
            hash.ethHex,
            "47173285a8d7341e5e972fc677286384f802f8ef42a5ec5f03bbfa254cb01fad"
        )
    }

    func testKeccak256IsNotSHA3() {
        // SHA3-256("") = a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a
        // Keccak-256("") = c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        // They MUST differ (different padding byte)
        let hash = Keccak256.hash(Data())
        XCTAssertNotEqual(
            hash.ethHex,
            "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"
        )
    }

    // MARK: - Hex utilities

    func testHexRoundTrip() throws {
        let original = Data([0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(original.ethHex, "deadbeef")
        XCTAssertEqual(original.ethHexPrefixed, "0xdeadbeef")

        let decoded = try Data(ethHex: "0xdeadbeef")
        XCTAssertEqual(decoded, original)

        let decodedNoPrefix = try Data(ethHex: "deadbeef")
        XCTAssertEqual(decodedNoPrefix, original)
    }

    func testHexInvalidOddLength() {
        XCTAssertThrowsError(try Data(ethHex: "0xabc")) { error in
            XCTAssertEqual(error as? EthError, .invalidHex)
        }
    }

    // MARK: - EthAddress

    func testAddressFromHex() throws {
        let addr = try EthAddress(hex: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
        XCTAssertEqual(addr.data.count, 20)
    }

    func testAddressChecksumEncoding() throws {
        // Vitalik's address — EIP-55 checksum
        let addr = try EthAddress(hex: "0xd8da6bf26964af9d7eed9e03e53415d37aa96045")
        XCTAssertEqual(addr.checksumAddress, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
    }

    func testAddressCodableRoundTrip() throws {
        let addr = try EthAddress(hex: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
        let data = try JSONEncoder().encode(addr)
        let decoded = try JSONDecoder().decode(EthAddress.self, from: data)
        XCTAssertEqual(addr, decoded)
    }

    // MARK: - EthKeyPair

    func testKeyPairGeneration() throws {
        let kp = try EthKeyPair()
        XCTAssertEqual(kp.privateKeyData.count, 32)
        XCTAssertEqual(kp.uncompressedPublicKey.count, 65)
        XCTAssertEqual(kp.uncompressedPublicKey.first, 0x04) // uncompressed prefix
        XCTAssertEqual(kp.address.data.count, 20)
    }

    func testKeyPairDeterministicAddress() throws {
        // A known private key should always derive the same address
        let privateKeyHex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
        let kp1 = try EthKeyPair(hexPrivateKey: privateKeyHex)
        let kp2 = try EthKeyPair(hexPrivateKey: privateKeyHex)
        XCTAssertEqual(kp1.address, kp2.address)
        XCTAssertEqual(kp1.uncompressedPublicKey, kp2.uncompressedPublicKey)
    }

    func testHardhatAccount0Address() throws {
        // Hardhat/Anvil default account #0
        // Private key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
        // Expected address: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
        let kp = try EthKeyPair(hexPrivateKey: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")
        XCTAssertEqual(
            kp.address.checksumAddress.lowercased(),
            "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266".lowercased()
        )
    }

    func testRecoverableSignature() throws {
        let kp = try EthKeyPair()
        let messageHash = Keccak256.hash(Data("test message".utf8))
        let sig = try kp.signRecoverable(messageHash: messageHash)
        XCTAssertEqual(sig.r.count, 32)
        XCTAssertEqual(sig.s.count, 32)
        XCTAssertTrue(sig.v == 0 || sig.v == 1)
        XCTAssertEqual(sig.compactRepresentation.count, 65)
    }

    // MARK: - ABI encoding

    func testABIEncodeUint256() {
        let encoded = ABI.encode([.uint256(42)])
        XCTAssertEqual(encoded.count, 32)
        XCTAssertEqual(encoded.last, 42)
        // All leading bytes should be zero
        XCTAssertTrue(encoded.prefix(31).allSatisfy { $0 == 0 })
    }

    func testABIEncodeAddress() throws {
        let addr = try EthAddress(hex: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
        let encoded = ABI.encode([.address(addr)])
        XCTAssertEqual(encoded.count, 32)
        // First 12 bytes should be zero (left-padding)
        XCTAssertTrue(encoded.prefix(12).allSatisfy { $0 == 0 })
        // Last 20 bytes should be the address
        XCTAssertEqual(Data(encoded.suffix(20)), addr.data)
    }

    func testABIEncodePacked() throws {
        let addr = try EthAddress(hex: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045")
        let packed = ABI.encodePacked([.address(addr), .uint256(1)])
        // address = 20 bytes (no padding in packed), uint256 = 32 bytes
        XCTAssertEqual(packed.count, 52)
    }

    func testABIEncodeBool() {
        let trueEncoded = ABI.encode([.bool(true)])
        let falseEncoded = ABI.encode([.bool(false)])
        XCTAssertEqual(trueEncoded.count, 32)
        XCTAssertEqual(trueEncoded.last, 1)
        XCTAssertEqual(falseEncoded.last, 0)
    }

    // MARK: - EIP-712

    func testEIP712TypeHash() {
        // Known type hash for EIP-712 Mail example
        let mailType = EIP712.TypeDefinition(name: "Mail", fields: [
            EIP712.Field(name: "from", type: "address"),
            EIP712.Field(name: "to", type: "address"),
            EIP712.Field(name: "contents", type: "string"),
        ])
        let typeHash = mailType.typeHash
        // keccak256("Mail(address from,address to,string contents)")
        let expected = Keccak256.hash(Data("Mail(address from,address to,string contents)".utf8))
        XCTAssertEqual(typeHash, expected)
    }

    func testEIP712DomainSeparator() throws {
        // Verify domain separator is deterministic
        let domain = EIP712.Domain(
            name: "TestDomain",
            version: "1",
            chainId: 1,
            verifyingContract: try EthAddress(hex: "0x0000000000000000000000000000000000000001")
        )
        let sep1 = domain.separator
        let sep2 = domain.separator
        XCTAssertEqual(sep1.count, 32)
        XCTAssertEqual(sep1, sep2)
    }

    func testEIP712SignableHash() throws {
        let domain = EIP712.Domain(
            name: "Test",
            version: "1",
            chainId: 31337,
            verifyingContract: try EthAddress(hex: "0x0000000000000000000000000000000000000001")
        )
        let structHash = Keccak256.hash(Data("test".utf8))
        let signable = EIP712.signableHash(domain: domain, structHash: structHash)
        XCTAssertEqual(signable.count, 32)

        // Verify the 0x1901 prefix is used
        var expected = Data([0x19, 0x01])
        expected.append(domain.separator)
        expected.append(structHash)
        XCTAssertEqual(signable, Keccak256.hash(expected))
    }
}
