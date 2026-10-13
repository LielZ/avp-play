import XCTest
@testable import AVPPlayCore

final class AppleIntermediateTests: XCTestCase {
    func testOnlyApplesDeveloperIntermediateHasAGeneration() {
        XCTAssertEqual(AppleIntermediate.generation(issuerCommonName: AppleIntermediate.issuerName, unit: "G3"), "G3")
        XCTAssertEqual(AppleIntermediate.generation(issuerCommonName: AppleIntermediate.issuerName, unit: "G12"), "G12")
        XCTAssertNil(AppleIntermediate.generation(issuerCommonName: "Developer ID Certification Authority", unit: "G2"))
        XCTAssertNil(AppleIntermediate.generation(issuerCommonName: AppleIntermediate.issuerName, unit: nil))
        // What goes into a URL is a generation and nothing else.
        XCTAssertNil(AppleIntermediate.generation(issuerCommonName: AppleIntermediate.issuerName, unit: "G3/../x"))
        XCTAssertNil(AppleIntermediate.generation(issuerCommonName: AppleIntermediate.issuerName, unit: "Apple Certification Authority"))
    }

    func testTheGenerationIsFetchedFromApple() {
        XCTAssertEqual(AppleIntermediate.url(generation: "G3")?.absoluteString, "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer")
        XCTAssertEqual(AppleIntermediate.url(generation: "G6")?.absoluteString, "https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer")
        XCTAssertNil(AppleIntermediate.url(generation: "G3.cer?x="))
        XCTAssertNil(AppleIntermediate.url(generation: ""))
    }

    func testNothingIsACertificateChain() {
        XCTAssertTrue(AppleIntermediate.chain([]).certificates.isEmpty)
        XCTAssertFalse(AppleIntermediate.chain([]).trusted)
    }
}
