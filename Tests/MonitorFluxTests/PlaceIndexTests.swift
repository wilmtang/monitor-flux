import XCTest
@testable import MonitorFlux

final class PlaceIndexTests: XCTestCase {
    /// A miniature index in the generated format: timezone table, admin table, cities
    /// (population-descending, as the generator emits), ZIP centroids.
    private static let fixture = PlaceIndex.load(from: """
    # comment line
    T\tAmerica/Los_Angeles
    T\tEurope/Zurich
    T\tAsia/Tokyo
    T\tAmerica/New_York
    A\tWashington
    A\tZurich
    A\tTokyo
    A\tNew York
    A\tCalifornia
    C\tTokyo\t2\tJP\t35.6895\t139.6917\t9733276\t2
    C\tNew York\t3\tUS\t40.7143\t-74.0060\t8804190\t3
    C\tSan Francisco\t4\tUS\t37.7749\t-122.4194\t873965\t0
    C\tSeattle\t0\tUS\t47.6062\t-122.3321\t780995\t0
    C\tZürich\t1\tCH\t47.3667\t8.5500\t415367\t1
    C\tSeaside\t4\tUS\t36.6111\t-121.8516\t34000\t0
    Z\t94107\t37.759\t-122.400
    """)

    private var index: PlaceIndex { Self.fixture }

    // MARK: - Classification

    func testClassifiesQueries() {
        XCTAssertEqual(PlaceIndex.classify("   "), .empty)
        XCTAssertEqual(PlaceIndex.classify("94107"), .zip("94107"))
        XCTAssertEqual(PlaceIndex.classify(" seattle "), .city("seattle"))
        XCTAssertEqual(PlaceIndex.classify("1600"), .city("1600"), "only full 5-digit codes are ZIPs")
        XCTAssertEqual(
            PlaceIndex.classify("47.61, -122.33"),
            .coordinate(latitude: 47.61, longitude: -122.33)
        )
        XCTAssertEqual(
            PlaceIndex.classify("47.61 -122.33"),
            .coordinate(latitude: 47.61, longitude: -122.33),
            "comma is optional"
        )
        XCTAssertEqual(
            PlaceIndex.classify("91.0, 10.0"),
            .city("91.0, 10.0"),
            "out-of-range latitude is not a coordinate"
        )
    }

    // MARK: - City search

    func testPrefixSearchRanksByPopulation() {
        let results = index.search("sea")
        XCTAssertEqual(results.map(\.name), ["Seattle", "Seaside"])
    }

    func testMultiWordQueryMatchesWordPrefixes() {
        XCTAssertEqual(index.search("new y").map(\.name), ["New York"])
        XCTAssertEqual(index.search("york").map(\.name), ["New York"], "any word boundary matches")
    }

    func testDiacriticInsensitiveMatch() {
        let results = index.search("zurich")
        XCTAssertEqual(results.map(\.name), ["Zürich"], "folded query finds the native spelling")
        XCTAssertEqual(results.first?.timeZoneID, "Europe/Zurich")
    }

    func testSearchRespectsLimit() {
        XCTAssertEqual(index.search("sea", limit: 1).map(\.name), ["Seattle"])
    }

    func testNoMatchesReturnsEmpty() {
        XCTAssertTrue(index.search("xyzzy").isEmpty)
        XCTAssertTrue(index.search("").isEmpty)
    }

    // MARK: - ZIP and coordinates

    func testZIPResolvesToCentroidNamedByNearestCity() throws {
        let result = try XCTUnwrap(index.search("94107").first)
        XCTAssertEqual(result.name, "San Francisco")
        XCTAssertEqual(result.zip, "94107")
        XCTAssertEqual(result.latitude, 37.759, accuracy: 0.0005, "coordinates are the ZIP centroid, not the city's")
        XCTAssertEqual(result.longitude, -122.400, accuracy: 0.0005)
        XCTAssertEqual(result.displayName, "San Francisco, California 94107")
    }

    func testUnknownZIPReturnsEmpty() {
        XCTAssertTrue(index.search("00000").isEmpty)
    }

    func testCoordinateQuerySynthesizesPlaceWithNearestTimeZone() throws {
        let result = try XCTUnwrap(index.search("47.61, -122.33").first)
        XCTAssertEqual(result.latitude, 47.61, accuracy: 0.0001)
        XCTAssertEqual(result.longitude, -122.33, accuracy: 0.0001)
        XCTAssertEqual(result.displayName, "47.6100, -122.3300")
        XCTAssertEqual(result.timeZoneID, "America/Los_Angeles", "timezone borrowed from the nearest city")
    }

    // MARK: - Nearest

    func testNearestFindsSeattleForSeattleSuburb() {
        XCTAssertEqual(index.nearest(latitude: 47.61, longitude: -122.20)?.name, "Seattle")
    }

    func testNearestHandlesDateLineWrap() {
        // 179.9°E is ~40° of longitude from Tokyo eastward across the date line, but ~86°
        // from San Francisco; without wrap handling the raw longitude delta would pick a
        // US city ("-122" is numerically closer to "179.9" than "139.7" is... it is not,
        // but a naive |Δlon| of 302° vs 40° collapses wrongly once squared).
        XCTAssertEqual(index.nearest(latitude: 35.0, longitude: 179.9)?.name, "Tokyo")
    }

    // MARK: - Display names

    func testDisplayNames() {
        XCTAssertEqual(index.search("seattle").first?.displayName, "Seattle, Washington")
        XCTAssertEqual(index.search("zurich").first?.displayName, "Zürich, Switzerland")
        XCTAssertEqual(
            index.search("tokyo").first?.qualifiedName,
            "Tokyo, Tokyo, Japan",
            "suggestions carry admin and country for disambiguation"
        )
    }

    // MARK: - The committed dataset

    /// Loads the real resource from the repo (tests run from the package, so #filePath is
    /// stable) and spot-checks it end to end — guards against a bad regeneration.
    func testBundledDatasetSanity() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/MonitorFluxTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/MonitorFlux/Resources/places.tsv")
        let index = PlaceIndex.load(from: try String(contentsOf: url, encoding: .utf8))

        XCTAssertFalse(index.isEmpty)

        let seattle = try XCTUnwrap(index.search("seattle").first)
        XCTAssertEqual(seattle.displayName, "Seattle, Washington")
        XCTAssertEqual(seattle.timeZoneID, "America/Los_Angeles")
        XCTAssertEqual(seattle.latitude, 47.6062, accuracy: 0.01)

        let zip = try XCTUnwrap(index.search("94107").first)
        XCTAssertEqual(zip.zip, "94107")
        XCTAssertEqual(zip.timeZoneID, "America/Los_Angeles")

        let tokyo = try XCTUnwrap(index.search("tokyo").first)
        XCTAssertEqual(tokyo.timeZoneID, "Asia/Tokyo")

        // Every city row must reference a valid timezone able to instantiate.
        let paris = try XCTUnwrap(index.search("paris").first)
        XCTAssertEqual(paris.displayName, "Paris, France", "population ranking puts Paris FR over Paris TX")
        XCTAssertNotNil(TimeZone(identifier: paris.timeZoneID))
    }
}
