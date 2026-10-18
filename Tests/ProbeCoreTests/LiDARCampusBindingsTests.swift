import XCTest
@testable import ProbeCore

final class LiDARCampusBindingsTests:XCTestCase {
    private func setup() throws -> (LiDARCampusCatalog,[String:(map:LiDARNavigationMap,placement:LiDARMapPlacement?)],LiDARNavigationMap,LiDARCampusCatalog.Building,LiDARCampusCatalog.Floor) {
        var catalog = LiDARCampusCatalog()
        let b = try catalog.addBuilding("教学中心"),f2 = try catalog.addFloor("2F",level:2,to:b.id),f3 = try catalog.addFloor("3F",to:b.id)
        let nodes = [LiDARRouteNode(name:"南门",position:ProbePoint(0,-1.5,0),id:"door",kind:.exit),
                     LiDARRouteNode(name:"电梯",position:ProbePoint(5,-1.5,0),id:"lift",kind:.elevator),
                     LiDARRouteNode(name:"走廊",position:ProbePoint(3,-1.5,0),id:"hall",kind:.waypoint)]
        let m = LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"2F",pointCount:500,nodes:nodes,edges:[])
        _ = f3
        return (catalog,[m.map_id:(m,try LiDARMapPlacement(mapID:m.map_id,building:catalog.building(b.id)!,floor:f2,region:"全层"))],m,b,f2)
    }
    func testEntranceKeepsItsIdAndRoundTrips() throws {
        let (_,_,m,b,_) = try setup()
        var bindings = LiDARCampusBindings()
        try bindings.bindBuilding(b.id,osmID:"w542603582")
        let node = LiDARNodeRef(map:m.map_id,node:"door")
        let first = try bindings.setEntrance(node,building:b.id,position:.init(lat:31.1790,lon:121.5905),accuracy:6,source:.gps)
        let again = try bindings.setEntrance(node,building:b.id,position:.init(lat:31.17905,lon:121.59052),accuracy:4,source:.gps,verified:true)
        XCTAssertEqual(first.id,again.id);XCTAssertEqual(bindings.entrances.count,1);XCTAssertTrue(bindings.entrance(at:node)!.verified)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try bindings.save(root:root)
        XCTAssertEqual(try LiDARCampusBindings.load(root:root),bindings)
        XCTAssertEqual(bindings.building(forOSM:"w542603582"),b.id);XCTAssertEqual(bindings.osmID(forBuilding:b.id),"w542603582")
        XCTAssertEqual(LiDARCampusBindings.GeoPoint(lat:31.1790,lon:121.5905).distance(to:.init(lat:31.1791,lon:121.5905)),11.1,accuracy:0.2)
    }
    func testOneToOneBuildingsAndInvalidCoordinates() throws {
        var bindings = LiDARCampusBindings()
        try bindings.bindBuilding("A",osmID:"w1")
        XCTAssertThrowsError(try bindings.bindBuilding("B",osmID:"w1"))
        try bindings.bindBuilding("A",osmID:"w2");XCTAssertEqual(bindings.buildings.count,1);XCTAssertEqual(bindings.osmID(forBuilding:"A"),"w2")
        XCTAssertThrowsError(try bindings.setEntrance(.init(map:"m",node:"n"),building:"A",position:.init(lat:0,lon:0),accuracy:nil,source:.gps))
        XCTAssertThrowsError(try bindings.setEntrance(.init(map:"m",node:"n"),building:"A",position:.init(lat:95,lon:121),accuracy:nil,source:.gps))
    }
    func testProblemsNameWhatIsNotUsable() throws {
        let (catalog,maps,m,b,f2) = try setup()
        var bindings = LiDARCampusBindings()
        // A waypoint is not an entrance; an elevator device without a matching elevator link is reported.
        bindings.entrances.append(.init(buildingID:b.id,node:.init(map:m.map_id,node:"hall")))
        bindings.elevator_devices.append(.init(groupID:"E1",buildingID:b.id,floorID:f2.id,peripheralName:"ELEV-2F",directions:[.up,.down]))
        let f3 = catalog.building(b.id)!.floors.first { $0.name == "3F" }!
        bindings.elevator_devices.append(.init(groupID:"E1",buildingID:b.id,floorID:f3.id,peripheralName:"ELEV-3F",directions:[.down]))
        try bindings.validate()
        let found = bindings.problems(catalog:catalog,maps:maps,links:[])
        XCTAssertTrue(found.contains { $0.contains("「走廊」不是大楼出入口") })
        XCTAssertTrue(found.contains { $0.contains("还没有记录室外坐标") })
        XCTAssertTrue(found.contains { $0.contains("ELEV-2F") && $0.contains("E1") })
        XCTAssertTrue(found.contains { $0.contains("3F") && $0.contains("没有填楼层号") })
        // With the elevator link in place, the 2F device resolves.
        let link = LiDARMapLink(kind:.elevator,a:.init(map:m.map_id,node:"lift"),b:.init(map:"other",node:"x"),groupID:"E1")
        XCTAssertFalse(bindings.problems(catalog:catalog,maps:maps,links:[link]).contains { $0.contains("ELEV-2F") })
        // Duplicate device for one elevator and floor is structurally invalid.
        bindings.elevator_devices.append(.init(groupID:"E1",buildingID:b.id,floorID:f2.id,peripheralName:"ELEV-2F-b",directions:[.up]))
        XCTAssertThrowsError(try bindings.validate())
    }
}

final class LiDARIndoorResumeTests:XCTestCase {
    func testOnePerMapAndOnlyOnTheSameGeometry() throws {
        var r = LiDARIndoorResume()
        r.record(.init(mapID:"m",geometrySHA256:"h1",position:ProbePoint(1,-1.5,2),reason:.confirmed))
        r.record(.init(mapID:"m",geometrySHA256:"h1",position:ProbePoint(5,-1.5,2),reason:.exited))
        r.record(.init(mapID:"n",geometrySHA256:"h9",position:ProbePoint(.nan,0,0),reason:.walking))
        XCTAssertEqual(r.entries.count,1);XCTAssertEqual(r.entry(mapID:"m",geometrySHA256:"h1")?.position.x,5)
        XCTAssertNil(r.entry(mapID:"m",geometrySHA256:"h2"),"a re-scanned map must not reuse the old position")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try r.save(root:root);XCTAssertEqual(LiDARIndoorResume.load(root:root),r)
        XCTAssertEqual(LiDARIndoorResume.load(root:root.appendingPathComponent("missing")),LiDARIndoorResume())
    }
}

final class LiDARAccessPathTests:XCTestCase {
    func testAccessPathStartsAtTheDoorAndFollowsItWhenMoved() throws {
        var b = LiDARCampusBindings();let node = LiDARNodeRef(map:"m",node:"door")
        try b.setEntrance(node,building:"B",position:.init(lat:31.1790,lon:121.5905),accuracy:nil,source:.manual)
        try b.setAccessPath(node,[.init(lat:31.17905,lon:121.59055),.init(lat:31.1791,lon:121.5906)])
        XCTAssertEqual(b.entrance(at:node)?.access_path?.count,3);XCTAssertEqual(b.entrance(at:node)?.access_path?.first,.init(lat:31.1790,lon:121.5905))
        try b.setEntrance(node,building:"B",position:.init(lat:31.17902,lon:121.59048),accuracy:nil,source:.manual)
        XCTAssertEqual(b.entrance(at:node)?.access_path?.first,.init(lat:31.17902,lon:121.59048));XCTAssertEqual(b.entrance(at:node)?.access_path?.count,3)
        // Too long (≈ 1.1 km) is refused; nil removes it.
        XCTAssertThrowsError(try b.setAccessPath(node,[.init(lat:31.1890,lon:121.5905)]))
        try b.setAccessPath(node,nil);XCTAssertNil(b.entrance(at:node)?.access_path)
        // A door without a position cannot get a path.
        XCTAssertThrowsError(try b.setAccessPath(.init(map:"m",node:"none"),[.init(lat:31.1791,lon:121.5906)]))
    }
}
