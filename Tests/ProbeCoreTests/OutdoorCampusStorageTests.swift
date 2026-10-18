import XCTest
@testable import ProbeCore

final class OutdoorCampusStorageTests:XCTestCase {
    private var asset:Data { get throws { try Data(contentsOf:URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/Outdoor/campus.json")) } }
    private func changed(_ name:String) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:asset) as? [String:Any])
        var meta = try XCTUnwrap(root["meta"] as? [String:Any]);meta["name"] = name;root["meta"] = meta;root["future"] = ["untouched":true]
        return try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys])
    }
    func testWholeFileImportExportRestoreAndBundledFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:dir) }
        let store = OutdoorCampusStorage(directory:dir),original = try asset,first = try changed("first"),second = try changed("second")
        XCTAssertFalse(try store.current(bundled:original).isCustom);XCTAssertNil(store.previous())
        try store.install(first,bundled:original);XCTAssertEqual(try store.current(bundled:original).data,first)
        XCTAssertEqual(store.previous(),original)
        try store.install(second,bundled:original);XCTAssertEqual(store.previous(),first)
        try store.restore(bundled:original);XCTAssertEqual(try store.current(bundled:original).data,first)
        try store.restore(bundled:original);XCTAssertEqual(try store.current(bundled:original).data,second)
        let before = try Data(contentsOf:store.currentURL)
        XCTAssertThrowsError(try store.install(Data("{}".utf8),bundled:original));XCTAssertEqual(try Data(contentsOf:store.currentURL),before)
        try Data("broken".utf8).write(to:store.currentURL)
        let fallback = try store.current(bundled:original);XCTAssertFalse(fallback.isCustom);XCTAssertNotNil(fallback.warning);XCTAssertEqual(fallback.data,original)
    }
    func testMultipartKeepsPrimaryRingAndRejectsMismatchedPrimary() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:asset) as? [String:Any]),buildings = try XCTUnwrap(root["buildings"] as? [[String:Any]])
        buildings[0]["parts"] = [buildings[0]["ring"]!,buildings[1]["ring"]!];root["buildings"] = buildings
        let c = try OutdoorCampusStorage.validateImport(JSONSerialization.data(withJSONObject:root))
        XCTAssertEqual(c.buildings[0].footprints.count,2);XCTAssertEqual(c.buildings[0].footprints.first,c.buildings[0].ring)
        buildings[0]["parts"] = [buildings[1]["ring"]!];root["buildings"] = buildings
        XCTAssertThrowsError(try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root)))
    }
    func testImportRejectsDisconnectedGraphButLegacyDecodeDoesNot() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:asset) as? [String:Any]),graph = try XCTUnwrap(root["graph"] as? [String:Any]),nodes = try XCTUnwrap(graph["nodes"] as? [[Double]])
        nodes.append([31.18,121.59]);graph["nodes"] = nodes;root["graph"] = graph
        let data = try JSONSerialization.data(withJSONObject:root)
        XCTAssertNoThrow(try OutdoorCampus.decode(data));XCTAssertThrowsError(try OutdoorCampusStorage.validateImport(data))
    }
}
