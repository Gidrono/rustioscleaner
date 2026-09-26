import XCTest
@testable import ContextCleaner

final class ContextCleanerSmokeTests: XCTestCase {
    func testDefaultWeightsTomlNonEmpty() {
        let toml = defaultWeightsToml()
        XCTAssertTrue(toml.contains("version"))
        XCTAssertTrue(toml.contains("blink_miss"))
    }

    func testAnalyzeSolidBlackIsPocket() throws {
        let w: UInt32 = 32
        let h: UInt32 = 32
        var rgba = Data(count: Int(w * h * 4))
        // already zero = black
        let signals = try analyzeThumbnail(width: w, height: h, rgba: rgba)
        XCTAssertTrue(signals.isPocketShot)
        XCTAssertGreaterThan(signals.uniformity, 0.9)
    }
}
