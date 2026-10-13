import XCTest
@testable import AVPPlayCore

/// Die Angabe „Mixed Reality“: im Rezept und im Katalog, jeweils freiwillig.
final class MixedRealityTests: XCTestCase {
    private var recipes: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("recipes")
    }

    private func recipe(_ name: String) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: recipes.appendingPathComponent(name)))
    }

    func testRecipesSayWhichGamesHaveAMixedRealityMode() throws {
        XCTAssertEqual(try recipe("store-3634830803298285.json").mixedReality, true)   // Demeo
        XCTAssertEqual(try recipe("store-5340130476095884.json").mixedReality, true)   // TRIANGLE STRATEGY
        // Fehlt die Angabe, ist sie nicht „nein“ geschrieben, sondern nicht da – und gilt als nein.
        XCTAssertNil(try recipe("moss.json").mixedReality)
    }

    func testCatalogueEntryCarriesTheFlagOrLeavesItOut() throws {
        let with = #"{"appId":"1642239225880682","title":"Richie's Plank Experience","package":"","status":"community","works":0,"problems":0,"fails":0,"mixedReality":true}"#
        let without = #"{"appId":"1654565391314903","title":"Moss","package":"com.polyarc.moss","status":"verified","works":0,"problems":0,"fails":0}"#
        let a = try JSONDecoder().decode(CatalogGame.self, from: Data(with.utf8))
        let b = try JSONDecoder().decode(CatalogGame.self, from: Data(without.utf8))
        XCTAssertEqual(a.mixedReality, true)
        XCTAssertTrue(a.isSane)
        XCTAssertNil(b.mixedReality)
    }
}
