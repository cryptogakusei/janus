import XCTest
@testable import JanusShared

final class PricingTierTests: XCTestCase {

    func testSmallTier() {
        let tier = PricingTier.classify(promptLength: 50)
        XCTAssertEqual(tier, .small)
        XCTAssertEqual(tier.credits, 3)
        XCTAssertEqual(tier.maxOutputTokens, 256)
    }

    func testMediumTier() {
        XCTAssertEqual(PricingTier.classify(promptLength: 200), .medium)
        XCTAssertEqual(PricingTier.classify(promptLength: 500), .medium)
        XCTAssertEqual(PricingTier.classify(promptLength: 800), .medium)
        XCTAssertEqual(PricingTier.classify(promptLength: 200).credits, 5)
    }

    func testLargeTier() {
        let tier = PricingTier.classify(promptLength: 801)
        XCTAssertEqual(tier, .large)
        XCTAssertEqual(tier.credits, 8)
        XCTAssertEqual(tier.maxOutputTokens, 1024)
    }

    func testBoundarySmallMedium() {
        XCTAssertEqual(PricingTier.classify(promptLength: 199), .small)
        XCTAssertEqual(PricingTier.classify(promptLength: 200), .medium)
    }

    func testBoundaryMediumLarge() {
        XCTAssertEqual(PricingTier.classify(promptLength: 800), .medium)
        XCTAssertEqual(PricingTier.classify(promptLength: 801), .large)
    }

    func testEmptyPrompt() {
        XCTAssertEqual(PricingTier.classify(promptLength: 0), .small)
    }
}
