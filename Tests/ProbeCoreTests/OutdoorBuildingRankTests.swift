import XCTest
@testable import ProbeCore

final class OutdoorBuildingRankTests: XCTestCase {
    private func campus(rank: Any?) throws -> OutdoorCampus {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/Outdoor/campus.json")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
        var buildings = try XCTUnwrap(root["buildings"] as? [[String: Any]])
        buildings[0].removeValue(forKey: "rank")
        if let rank { buildings[0]["rank"] = rank }
        root["buildings"] = buildings
        return try OutdoorCampus.decode(JSONSerialization.data(withJSONObject: root))
    }
    func testLegacyBuildingWithoutRankRemainsReadable() throws {
        XCTAssertNil(try campus(rank: nil).buildings[0].rank)
        XCTAssertNil(try campus(rank: NSNull()).buildings[0].rank)
    }
    func testAllFiveRanksDecodeWithoutChangingTheirPriority() throws {
        for rank in 1...5 { XCTAssertEqual(try campus(rank: rank).buildings[0].rank, rank) }
    }
    func testInvalidRanksAreRejected() throws {
        for rank in [0, 6, -1, 2.5, "5", true] as [Any] {
            XCTAssertThrowsError(try campus(rank: rank))
        }
    }
}
