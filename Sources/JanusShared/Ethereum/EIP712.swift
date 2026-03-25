import Foundation

/// EIP-712: Typed structured data hashing and signing.
///
/// Implements the standard from https://eips.ethereum.org/EIPS/eip-712
/// Used by Tempo payment channels for off-chain voucher signing.
///
/// The final signable hash is: `keccak256("\x19\x01" || domainSeparator || structHash)`
public enum EIP712 {

    /// A named, typed field in an EIP-712 struct.
    public struct Field {
        public let name: String
        public let type: String

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    /// A struct type definition (name + ordered fields).
    public struct TypeDefinition {
        public let name: String
        public let fields: [Field]

        public init(name: String, fields: [Field]) {
            self.name = name
            self.fields = fields
        }

        /// The type hash: `keccak256("TypeName(type1 name1,type2 name2,...)")`.
        public var typeHash: Data {
            let encoding = name + "(" + fields.map { "\($0.type) \($0.name)" }.joined(separator: ",") + ")"
            return Keccak256.hash(Data(encoding.utf8))
        }
    }

    /// An EIP-712 domain separator.
    public struct Domain {
        public let name: String
        public let version: String
        public let chainId: UInt64
        public let verifyingContract: EthAddress

        public init(name: String, version: String, chainId: UInt64, verifyingContract: EthAddress) {
            self.name = name
            self.version = version
            self.chainId = chainId
            self.verifyingContract = verifyingContract
        }

        /// The domain separator hash.
        public var separator: Data {
            let domainType = TypeDefinition(name: "EIP712Domain", fields: [
                Field(name: "name", type: "string"),
                Field(name: "version", type: "string"),
                Field(name: "chainId", type: "uint256"),
                Field(name: "verifyingContract", type: "address"),
            ])

            let values: [Data] = [
                domainType.typeHash,
                Keccak256.hash(Data(name.utf8)),
                Keccak256.hash(Data(version.utf8)),
                ABI.Value.uint256(chainId).encoded,
                ABI.Value.address(verifyingContract).encoded,
            ]
            return Keccak256.hash(values.reduce(Data(), +))
        }
    }

    /// Hash a struct instance: `keccak256(typeHash || encodeData(...))`.
    ///
    /// - Parameters:
    ///   - type: The struct's type definition.
    ///   - values: The ABI-encoded field values (in field order), each 32 bytes.
    ///             String/bytes fields should be pre-hashed with keccak256.
    /// - Returns: The struct hash.
    public static func hashStruct(type: TypeDefinition, encodedValues: [Data]) -> Data {
        var data = type.typeHash
        for value in encodedValues {
            data.append(value)
        }
        return Keccak256.hash(data)
    }

    /// Compute the final EIP-712 signable digest.
    ///
    /// `keccak256("\x19\x01" || domainSeparator || structHash)`
    public static func signableHash(domain: Domain, structHash: Data) -> Data {
        var message = Data([0x19, 0x01])
        message.append(domain.separator)
        message.append(structHash)
        return Keccak256.hash(message)
    }
}
