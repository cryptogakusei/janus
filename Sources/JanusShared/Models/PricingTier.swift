import Foundation

/// Pricing tiers based on prompt length.
///
/// From PRD Section 9:
///   small:  < 200 chars  → 256 max output tokens → 3 credits
///   medium: 200–800 chars → 512 max output tokens → 5 credits
///   large:  > 800 chars   → 1024 max output tokens → 8 credits
public enum PricingTier: String, Codable, Sendable {
    case small
    case medium
    case large

    public var credits: Int {
        switch self {
        case .small: return 3
        case .medium: return 5
        case .large: return 8
        }
    }

    public var maxOutputTokens: Int {
        switch self {
        case .small: return 256
        case .medium: return 512
        case .large: return 1024
        }
    }

    /// Classify a prompt into a pricing tier based on character count.
    public static func classify(promptLength: Int) -> PricingTier {
        if promptLength < 200 {
            return .small
        } else if promptLength <= 800 {
            return .medium
        } else {
            return .large
        }
    }
}
