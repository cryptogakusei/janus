/// Result of comparing on-chain settlement against client's expected spend.
public enum SettlementStatus: Equatable, Sendable {
    /// Settled amount matches cumulative spend exactly.
    case match(settled: UInt64)
    /// Provider settled more than client authorized.
    case overpayment(settled: UInt64, expected: UInt64)
    /// Provider settled less than client authorized (partial or in-progress).
    case underpayment(settled: UInt64, expected: UInt64)
    /// Verification not yet attempted.
    case unverified

    public var settled: UInt64 {
        switch self {
        case .match(let s): return s
        case .overpayment(let s, _): return s
        case .underpayment(let s, _): return s
        case .unverified: return 0
        }
    }
}
