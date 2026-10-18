import XCTest
@testable import ProbeCore

final class LiDARCampusCatalogTests:XCTestCase {
    private func mapFolder(_ root:URL,id:String = UUID().uuidString) throws -> (URL,LiDARNavigationMap) {
        let folder = root.appendingPathComponent("map-"+id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let points = (0..<150).map { ProbePoint(Double($0)/50,-1.5,0) }
        let map = LiDARNavigationMap(mapID:id,sessionID:UUID().uuidString,name:"走廊",pointCount:points.count,
            nodes:[LiDARRouteNode(name:"A",position:ProbePoint(0,-1.5,0),id:"a"),LiDARRouteNode(name:"B",position:ProbePoint(3,-1.5,0),id:"b")],
            edges:[LiDARRouteEdge("a","b")])
        try LiDARNavigationArchive.write(map,to:folder.appendingPathComponent("navigation.json"))
        try LiDARPointFile.encode(points).write(to:folder.appendingPathComponent("geometry.f32"))
        return (folder,map)
    }
    func testNamesAreTrimmedUniqueAndFloorsSortByLevel() throws {
        var catalog = LiDARCampusCatalog()
        let b = try catalog.addBuilding("  教学楼 ")
        XCTAssertEqual(b.name,"教学楼")
        XCTAssertThrowsError(try catalog.addBuilding("教学楼"))
        XCTAssertThrowsError(try catalog.addBuilding("   "))
        try catalog.addFloor("三层",level:3,to:b.id);try catalog.addFloor("负一层",level:-1,to:b.id);try catalog.addFloor("夹层",to:b.id)
        XCTAssertThrowsError(try catalog.addFloor("三层",to:b.id))
        XCTAssertEqual(catalog.building(b.id)?.sortedFloors.map(\.name),["负一层","三层","夹层"])
        try catalog.validate()
    }
    func testPlacementTravelsWithExportAndImportRecreatesMissingFloor() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let (folder,map) = try mapFolder(temp.appendingPathComponent("phone-a"))
        var catalog = LiDARCampusCatalog()
        let b = try catalog.addBuilding("实验楼"),f = try catalog.addFloor("二层",level:2,to:b.id)
        try LiDARMapPlacement(mapID:map.map_id,building:catalog.building(b.id)!,floor:f,region:"西侧走廊").write(to:folder)
        let zip = temp.appendingPathComponent("map.zip")
        try LiDARNavigationArchive.exportZIP(folder,to:zip)
        let imported = try LiDARNavigationArchive.importZIP(zip,into:temp.appendingPathComponent("phone-b"))
        guard case .placed(let p) = LiDARMapPlacement.load(imported,mapID:map.map_id) else { return XCTFail("placement lost in export") }
        // The other phone knows nothing about this building yet: adopt recreates it under the same IDs.
        var other = LiDARCampusCatalog()
        XCTAssertNil(other.resolve(p));XCTAssertTrue(other.adopt(p))
        XCTAssertEqual(other.resolve(p)?.floor.name,"二层");XCTAssertEqual(other.resolve(p)?.building.id,b.id)
        // A same-named building with a different ID is a clash: the map stays unclassified instead of merging by name.
        var clash = LiDARCampusCatalog();try clash.addBuilding("实验楼")
        XCTAssertFalse(clash.adopt(p));XCTAssertNil(clash.resolve(p))
    }
    func testGroupingKeepsUnplacedDamagedAndDanglingMapsVisible() throws {
        var catalog = LiDARCampusCatalog()
        let b = try catalog.addBuilding("图书馆"),f1 = try catalog.addFloor("一层",level:1,to:b.id),f2 = try catalog.addFloor("二层",level:2,to:b.id)
        let building = catalog.building(b.id)!
        let east = try LiDARMapPlacement(mapID:"m1",building:building,floor:f1,region:"东侧")
        let west = try LiDARMapPlacement(mapID:"m2",building:building,floor:f1,region:"东侧")
        let ghost = try LiDARMapPlacement(mapID:"m4",building:building,floor:LiDARCampusCatalog.Floor(name:"三层"),region:"北侧")
        let grouping = LiDARLibraryGrouping(catalog:catalog,maps:[
            ("m1","a",.placed(east)),("m2","b",.placed(west)),("m3","旧图",.none),("m4","c",.placed(ghost)),("m5","d",.invalid("坏文件"))])
        XCTAssertEqual(grouping.buildings.count,1)
        XCTAssertEqual(grouping.buildings[0].floors.map(\.floor.id),[f1.id,f2.id])
        XCTAssertEqual(grouping.buildings[0].floors[0].regions.map(\.map_id),["m1","m2"])
        XCTAssertTrue(grouping.buildings[0].floors[1].regions.isEmpty)
        XCTAssertEqual(Set(grouping.unclassified.map(\.map_id)),["m3","m4","m5"])
        XCTAssertEqual(grouping.duplicateRegionNames,["图书馆 · 一层 · 东侧"])
    }
    func testRemovingOccupiedFloorOrBuildingIsRefused() throws {
        var catalog = LiDARCampusCatalog()
        let b = try catalog.addBuilding("主楼"),f = try catalog.addFloor("一层",to:b.id)
        let p = try LiDARMapPlacement(mapID:"m",building:catalog.building(b.id)!,floor:f,region:"大厅")
        XCTAssertThrowsError(try catalog.removeFloor(f.id,in:b.id,placements:[p]))
        XCTAssertThrowsError(try catalog.removeBuilding(b.id,placements:[p]))
        try catalog.removeFloor(f.id,in:b.id,placements:[]);try catalog.removeBuilding(b.id,placements:[])
        XCTAssertTrue(catalog.buildings.isEmpty)
    }
    func testPlacementForAnotherMapAndCatalogRoundTrip() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let (folder,_) = try mapFolder(temp)
        var catalog = LiDARCampusCatalog()
        let b = try catalog.addBuilding("主楼"),f = try catalog.addFloor("一层",to:b.id)
        let wrong = try LiDARMapPlacement(mapID:"someone-else",building:catalog.building(b.id)!,floor:f,region:"大厅")
        XCTAssertThrowsError(try wrong.write(to:folder))
        XCTAssertEqual(LiDARMapPlacement.load(folder,mapID:"x"),.none)
        try catalog.save(root:temp)
        XCTAssertEqual(try LiDARCampusCatalog.load(root:temp),catalog)
        XCTAssertEqual(try LiDARCampusCatalog.load(root:temp.appendingPathComponent("empty")),LiDARCampusCatalog())
    }
}
