import XCTest
@testable import ProbeCore

final class LiDARMultiMapTests:XCTestCase {
    private func line(_ id:String,_ names:[(String,CampusNodeKind,Double)]) -> LiDARNavigationMap {
        let nodes = names.enumerated().map { LiDARRouteNode(name:$1.0,position:ProbePoint($1.2,-1.5,0),id:"\(id)\($0)",kind:$1.1) }
        return LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:id,pointCount:500,nodes:nodes,
                                  edges:zip(nodes,nodes.dropFirst()).map { LiDARRouteEdge($0.id,$1.id) })
    }
    /// Test maps are straight corridors: in-map length is the straight distance.
    private let straight = LiDARSpaceDistances { _,a,b in (hypot(a.x-b.x,a.z-b.z),"") }
    func testRouteCrossesFloorByCheaperLinkAndSplitsLegs() throws {
        // 1F: stairs at x=0, hall, elevator at x=20.  2F: stairs at x=0, room at x=18, elevator at x=20.
        let f1 = line("a",[("东楼梯",.stair,0),("大厅",.junction,10),("电梯",.elevator,20)])
        let f2 = line("b",[("东楼梯",.stair,0),("会议室",.room,18),("电梯",.elevator,20)])
        let maps = [f1.map_id:f1,f2.map_id:f2]
        var links = LiDARCampusLinks()
        try links.add(LiDARMapLink(kind:.stairs,a:.init(map:f1.map_id,node:"a0"),b:.init(map:f2.map_id,node:"b0")),maps:maps)
        try links.add(LiDARMapLink(kind:.elevator,a:.init(map:f1.map_id,node:"a2"),b:.init(map:f2.map_id,node:"b2"),groupID:"E1"),maps:maps)
        XCTAssertThrowsError(try links.add(LiDARMapLink(kind:.elevator,a:.init(map:f1.map_id,node:"a0"),b:.init(map:f2.map_id,node:"b2")),maps:maps))
        XCTAssertThrowsError(try links.add(LiDARMapLink(kind:.stairs,a:.init(map:f1.map_id,node:"a0"),b:.init(map:f2.map_id,node:"b0")),maps:maps))
        // Standing at x=9: stairs = 9 + 15 + 18 = 42; elevator = 11 + 30 + 2 = 43 → stairs.
        let goal = [LiDARNodeRef(map:f2.map_id,node:"b1")]
        let r = try LiDARMultiMapPlanner.plan(maps:maps,links:links.links,startMap:f1.map_id,start:ProbePoint(9,-1.5,0),destinations:goal,distances:straight)
        XCTAssertEqual(r.legs.count,2);XCTAssertEqual(r.legs[0].target_node_id,"a0");XCTAssertEqual(r.legs[0].link?.kind,.stairs)
        XCTAssertEqual(r.legs[1].entry_node_id,"b0");XCTAssertEqual(r.legs[1].target_node_id,"b1")
        XCTAssertEqual(r.total_m,42,accuracy:0.01);XCTAssertEqual(r.legs[0].length_m,9,accuracy:0.01);XCTAssertEqual(r.legs[1].length_m,18,accuracy:0.01)
        // Standing at x=12: stairs 45, elevator 40 → elevator.
        let e = try LiDARMultiMapPlanner.plan(maps:maps,links:links.links,startMap:f1.map_id,start:ProbePoint(12,-1.5,0),destinations:goal,distances:straight)
        XCTAssertEqual(e.legs[0].link?.kind,.elevator);XCTAssertEqual(e.legs[0].link?.group_id,"E1");XCTAssertEqual(e.total_m,40,accuracy:0.01)
        // Same-map destination needs no link.
        let local = try LiDARMultiMapPlanner.plan(maps:maps,links:links.links,startMap:f1.map_id,start:ProbePoint(9,-1.5,0),destinations:[.init(map:f1.map_id,node:"a1")],distances:straight)
        XCTAssertEqual(local.legs.count,1);XCTAssertNil(local.legs[0].link)
        // No links: another floor is unreachable.
        XCTAssertThrowsError(try LiDARMultiMapPlanner.plan(maps:maps,links:[],startMap:f1.map_id,start:ProbePoint(9,-1.5,0),destinations:goal,distances:straight))
    }
    func testNamedElevatorsAreDestinationsAndRouteKindCanBeEditedAfterSaving() throws {
        var f = line("c",[("走廊",.waypoint,0),("1号电梯",.elevator,5),("节点3",.elevator,9)])
        f.destination_policy = LiDARNavigationMap.roomsAndNamedStairs
        XCTAssertEqual(f.destinationGroups().map(\.name),["1号电梯"])
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        try LiDARPointFile.encode((0..<500).map { ProbePoint(Double($0)*0.02,-1.5,0) }).write(to:temp.appendingPathComponent("geometry.f32"))
        try LiDARNavigationArchive.write(f,to:temp.appendingPathComponent("navigation.json"))
        try LiDARNavigationArchive.updateRoute(temp) { try $0.setKind("c0",.stair) }
        XCTAssertEqual(try LiDARNavigationArchive.load(temp).0.nodes[0].resolvedKind,.stair)
        XCTAssertEqual(LiDARMapVersions.list(temp).first?.nodes,3)
    }
    func testUnreachableInMapLegIsNoEdgeAndIsReported() throws {
        let f1 = line("a",[("东楼梯",.stair,0),("电梯",.elevator,20)]),f2 = line("b",[("东楼梯",.stair,0),("会议室",.room,18)])
        let maps = [f1.map_id:f1,f2.map_id:f2]
        var links = LiDARCampusLinks()
        try links.add(LiDARMapLink(kind:.stairs,a:.init(map:f1.map_id,node:"a0"),b:.init(map:f2.map_id,node:"b0")),maps:maps)
        // 2F has no walkable area: no straight-line or network fallback.
        let blocked = LiDARSpaceDistances { id,a,b in id == f2.map_id ? (nil,"终点不在可走区域") : (hypot(a.x-b.x,a.z-b.z),"") }
        XCTAssertThrowsError(try LiDARMultiMapPlanner.plan(maps:maps,links:links.links,startMap:f1.map_id,start:ProbePoint(5,-1.5,0),
                                                           destinations:[.init(map:f2.map_id,node:"b1")],distances:blocked))
        XCTAssertTrue(blocked.failures.contains { $0.contains("会议室") && $0.contains("终点不在可走区域") })
        // A real grid: a node 30 m outside the scanned corridor is not reachable.
        var pts = [ProbePoint]()
        for x in stride(from:0.0,through:10,by:0.1) { for z in stride(from:-1.0,through:1,by:0.1) { pts.append(ProbePoint(x,-1.5,z)) } }
        let grid = try LiDARSpaceGrid.build(points:pts)
        let space = LiDARSpaceDistances(grids:[f1.map_id:grid])
        XCTAssertNotNil(space.length(f1.map_id,from:ProbePoint(1,-1.5,0),to:ProbePoint(9,-1.5,0)))
        XCTAssertNil(space.length(f1.map_id,from:ProbePoint(1,-1.5,0),to:ProbePoint(40,-1.5,0),label:"x"))
        XCTAssertNil(space.length(f2.map_id,from:ProbePoint(1,-1.5,0),to:ProbePoint(9,-1.5,0)))
    }
}

final class LiDARNamedChoiceTests:XCTestCase {
    func testRoomsFirstOthersNamedOnlyAndNoWaypoints() {
        let names:[(String,CampusNodeKind)] = [("1309",.room),("东楼梯",.stair),("节点3",.junction),("大厅",.junction),("P1",.waypoint),("1309",.room),("1号电梯",.elevator)]
        let nodes = names.enumerated().map { LiDARRouteNode(name:$1.0,position:ProbePoint(Double($0),-1.5,0),id:"n\($0)",kind:$1.1) }
        let map = LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"m",pointCount:500,nodes:nodes,
                                     edges:zip(nodes,nodes.dropFirst()).map { LiDARRouteEdge($0.id,$1.id) })
        let c = map.namedChoices()
        XCTAssertEqual(c.rooms.map(\.name),["1309"]);XCTAssertEqual(c.rooms[0].nodeIDs,["n0","n5"])
        XCTAssertEqual(c.others.map(\.name),["东楼梯","大厅","1号电梯"])
    }
}

final class LiDARLeftMapAreaTests:XCTestCase {
    func testNearestWalkableGuidesBackFromOutsideTheMap() throws {
        var pts = [ProbePoint]()
        for x in stride(from:0.0,through:10,by:0.1) { for z in stride(from:-1.0,through:1,by:0.1) { pts.append(ProbePoint(x,-1.5,z)) } }
        let g = try LiDARSpaceGrid.build(points:pts)
        let back = try XCTUnwrap(LiDARSpacePlanner.nearestWalkable(g,x:5,z:6,maxDistance:30))
        XCTAssertEqual(back.x,5,accuracy:0.3);XCTAssertLessThan(back.z,1.1);XCTAssertEqual(back.distance,5,accuracy:0.5)
        XCTAssertEqual(LiDARSpacePlanner.route(g,from:(back.x,back.z),to:(9,0)).status,"ok")
        XCTAssertNil(LiDARSpacePlanner.nearestWalkable(g,x:5,z:45,maxDistance:30))
    }
}
