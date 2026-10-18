import XCTest
@testable import ProbeCore

final class LiDARSpaceRoutingTests:XCTestCase {
    // MARK: RLE test vectors (Docs/空间路网接口.md §2)
    func testRLEVectors() throws {
        // 3×2: row0 = 0 1 1, row1 = 1 1 1 → runs [1,2] [0,3] → bytes 01 02 00 03
        let bits = [false,true,true, true,true,true]
        let text = LiDARRLE.encode(bits,width:3,height:2)
        XCTAssertEqual(Data(base64Encoded:text),Data([1,2,0,3]))
        XCTAssertEqual(try LiDARRLE.decode(text,width:3,height:2),bits)
        // All white / all green, and a run needing two LEB128 bytes (200 = C8 01).
        XCTAssertEqual(Data(base64Encoded:LiDARRLE.encode(Array(repeating:false,count:200),width:200,height:1)),Data([0xC8,0x01]))
        XCTAssertEqual(Data(base64Encoded:LiDARRLE.encode(Array(repeating:true,count:200),width:200,height:1)),Data([0x00,0xC8,0x01]))
        // Bad streams: row sum short, trailing bytes, zero run mid-row, garbage.
        XCTAssertThrowsError(try LiDARRLE.decode(Data([1,1]).base64EncodedString(),width:3,height:1))
        XCTAssertThrowsError(try LiDARRLE.decode(Data([3,9]).base64EncodedString(),width:3,height:1))
        XCTAssertThrowsError(try LiDARRLE.decode(Data([1,0,2]).base64EncodedString(),width:3,height:1))
        XCTAssertThrowsError(try LiDARRLE.decode("@@@",width:3,height:1))
        // Negative origin cell lookup.
        let spec = LiDARGridSpec(origin_x:-2,origin_z:-1,width:40,height:20)
        XCTAssertEqual(spec.cell(-1.95,-0.95)?.i,0);XCTAssertEqual(spec.cell(-1.95,-0.95)?.j,0)
        XCTAssertNil(spec.cell(-2.05,0));XCTAssertEqual(spec.center(0,0).x,-1.95,accuracy:1e-9)
    }
    func testCalibrationValidation() throws {
        let id = UUID().uuidString
        var cal = LiDARPassageCalibration(mapID:id,geometrySHA256:"x",editor:"workbench",paths:[LiDARSuggestedPath(points:[[0,0],[1,0]],source:"phone")])
        try cal.validate(mapID:id)
        XCTAssertThrowsError(try cal.validate(mapID:UUID().uuidString))                       // other map
        cal.suggested_paths.append(cal.suggested_paths[0]);XCTAssertThrowsError(try cal.validate(mapID:id))   // duplicate id
        cal.suggested_paths = [LiDARSuggestedPath(points:[[0,0]],source:"phone")];XCTAssertThrowsError(try cal.validate(mapID:id))
        cal.suggested_paths = [LiDARSuggestedPath(points:[[0,0],[1,.nan]],source:"phone")];XCTAssertThrowsError(try cal.validate(mapID:id))
        cal.suggested_paths = [LiDARSuggestedPath(points:[[0,0],[1,0]],source:"legacy_route")];XCTAssertThrowsError(try cal.validate(mapID:id))
    }

    // MARK: Synthetic floor plans
    /// Floor everywhere in [x0,x1]×[z0,z1] (5 cm sampling) plus walls along given segments (3 rows of points per cell column).
    private func plan(floor rects:[(Double,Double,Double,Double)],walls:[((Double,Double),(Double,Double))]) -> [ProbePoint] {
        var p = [ProbePoint]()
        for (x0,z0,x1,z1) in rects { for x in stride(from:x0,to:x1,by:0.05) { for z in stride(from:z0,to:z1,by:0.05) { p.append(ProbePoint(x,-1.5,z)) } } }
        for (a,b) in walls {
            let n = max(1,Int(hypot(b.0-a.0,b.1-a.1)/0.05))
            for k in 0...n { let t = Double(k)/Double(n);for y in stride(from:-1.2,to:0.3,by:0.1) { p.append(ProbePoint(a.0+(b.0-a.0)*t,y,a.1+(b.1-a.1)*t)) } }
        }
        return p
    }
    /// A 20 m × 4 m corridor (walls at z = 0 and z = 4).
    private func corridor() -> [ProbePoint] { plan(floor:[(0,0,20,4)],walls:[((0,0),(20,0)),((0,4),(20,4)),((0,0),(0,4)),((20,0),(20,4))]) }
    func testRouteKeepsAwayFromWallsAndIsStraight() throws {
        let g = try LiDARSpaceGrid.build(points:corridor())
        let r = LiDARSpacePlanner.route(g,from:(1.5,2),to:(18.5,2.3))
        XCTAssertEqual(r.status,"ok",r.reason)
        XCTAssertEqual(r.length_m ?? 0,17,accuracy:0.6)
        // Wide corridor (half width ~1.8 m): the route stays near the middle, at least ~1.2 m from both walls.
        XCTAssertTrue(r.points.allSatisfy { $0[1] > 1.1 && $0[1] < 2.9 },"\(r.points)")
        XCTAssertLessThanOrEqual(r.points.count,4)
    }
    func testUnreachableAndOffGridEndpoints() throws {
        // Two rooms separated by a wall with no opening.
        let pts = plan(floor:[(0,0,4,4),(4.4,0,8,4)],walls:[((4.2,-1),(4.2,5))])
        let g = try LiDARSpaceGrid.build(points:pts)
        XCTAssertEqual(LiDARSpacePlanner.route(g,from:(1,2),to:(7,2)).status,"unreachable")
        XCTAssertTrue(LiDARSpacePlanner.route(g,from:(1,2),to:(30,2)).reason.contains("终点"))
    }
    func testSuggestedPathCrossesWhiteAndThePathIsFollowed() throws {
        // Same two rooms; a suggested path through the wall gap area is the user's authorization.
        // A 1 m unobserved strip (x 4…5) between the rooms: not walkable without evidence.
        let pts = plan(floor:[(0,0,4,4),(5,0,9,4)],walls:[])
        let blocked = try LiDARSpaceGrid.build(points:pts)
        XCTAssertEqual(LiDARSpacePlanner.route(blocked,from:(1,2),to:(7,2)).status,"unreachable")
        let path = LiDARSuggestedPath(points:[[2,2],[6,2]],width:0.6,source:"phone")
        let cal = LiDARPassageCalibration(mapID:"m",geometrySHA256:nil,editor:"phone",paths:[path])
        let g = try LiDARSpaceGrid.build(points:pts,calibration:cal)
        let r = LiDARSpacePlanner.route(g,from:(1,2),to:(7,2))
        XCTAssertEqual(r.status,"ok",r.reason);XCTAssertEqual(r.used_paths,[path.id])
        XCTAssertTrue(r.points.allSatisfy { abs($0[1]-2) < 0.35 },"\(r.points)")
    }
    func testLongDetourAlongAPathInOpenSpaceIsNotForced() throws {
        // Open 20×20 hall; a suggested path makes a big U. Going straight is far shorter → free variant.
        let hall = plan(floor:[(0,0,20,20)],walls:[((0,0),(20,0)),((0,20),(20,20)),((0,0),(0,20)),((20,0),(20,20))])
        let u = LiDARSuggestedPath(points:[[3,3],[3,17],[17,17],[17,3]],source:"workbench")
        let g = try LiDARSpaceGrid.build(points:hall,calibration:LiDARPassageCalibration(mapID:"m",geometrySHA256:nil,editor:"workbench",paths:[u]))
        let r = LiDARSpacePlanner.route(g,from:(3,4),to:(17,4))
        XCTAssertEqual(r.status,"ok");XCTAssertEqual(r.length_m ?? 0,14,accuracy:1)   // straight across, not round the U
        XCTAssertTrue(r.points.allSatisfy { $0[1] < 8 },"\(r.points)")
        // Along the path's own direction, the path is followed.
        let along = LiDARSpacePlanner.route(g,from:(3,4),to:(3,16))
        XCTAssertEqual(along.variant,"with_paths");XCTAssertTrue(along.points.allSatisfy { abs($0[0]-3) < 0.35 },"\(along.points)")
    }
    func testCalibratedRectangleIsFinalAndOutsideStaysAuto() throws {
        let pts = corridor()
        // Calibration covers x 0…10 and paints everything there white except a band z 1.5…2.5.
        let spec = LiDARGridSpec(origin_x:0,origin_z:0,width:100,height:40)
        var bits = [Bool](repeating:false,count:spec.count)
        for j in 15..<25 { for i in 0..<100 { bits[j*100+i] = true } }
        let walkable = LiDARPassageCalibration.Walkable(origin_x:0,origin_z:0,cell_m:0.1,width:100,height:40,rle:LiDARRLE.encode(bits,width:100,height:40))
        let g = try LiDARSpaceGrid.build(points:pts,calibration:LiDARPassageCalibration(mapID:"m",geometrySHA256:nil,editor:"workbench",walkable:walkable))
        // Inside: the observed floor at z = 0.8 is white because the file says so.
        let inside = g.spec.cell(5,0.8)!,outside = g.spec.cell(15,0.8)!
        XCTAssertFalse(g.effective[inside.j*g.spec.width+inside.i])
        XCTAssertTrue(g.effective[outside.j*g.spec.width+outside.i])
        XCTAssertEqual(g.calibratedRect,spec)
        let r = LiDARSpacePlanner.route(g,from:(2,2),to:(18,1))
        XCTAssertEqual(r.status,"ok");XCTAssertTrue(r.points.filter { $0[0] < 10 }.allSatisfy { $0[1] >= 1.45 && $0[1] <= 2.55 })
    }
    func testGridFileRoundTripsAllLayers() throws {
        let g = try LiDARSpaceGrid.build(points:corridor(),calibration:LiDARPassageCalibration(mapID:"m",geometrySHA256:nil,editor:"phone",paths:[LiDARSuggestedPath(points:[[1,2],[19,2]],source:"phone")]))
        let file = LiDARSpaceGridFile(g,mapID:"m",geometrySHA256:"h")
        let back = try JSONDecoder().decode(LiDARSpaceGridFile.self,from:JSONEncoder().encode(file)).spaceGrid()
        XCTAssertEqual(back.effective,g.effective);XCTAssertEqual(back.forced,g.forced);XCTAssertEqual(back.paths,g.paths)
        XCTAssertEqual(LiDARSpacePlanner.route(back,from:(1.5,2),to:(18,2)),LiDARSpacePlanner.route(g,from:(1.5,2),to:(18,2)))
    }
    func testWalkedTrajectoryGivesPassageEvidence() throws {
        // Floor seen on both sides, a 1 m unobserved strip in between that the mapper walked across.
        let pts = plan(floor:[(0,0,4,4),(5,0,9,4)],walls:[])
        XCTAssertEqual(LiDARSpacePlanner.route(try LiDARSpaceGrid.build(points:pts),from:(1,2),to:(8,2)).status,"unreachable")
        let walk = LiDARWalkedTrajectory(mapID:"m",polylines:[[[1,2],[8,2]]])
        let r = LiDARSpacePlanner.route(try LiDARSpaceGrid.build(points:pts,trajectory:walk),from:(1,2),to:(8,2))
        XCTAssertEqual(r.status,"ok",r.reason)
    }
}

final class LiDARSpaceModeMapTests:XCTestCase {
    func testSpaceModeMapsNeedNoNetwork() throws {
        var editor = LiDARRouteEditor();editor.spaceMode = true
        try editor.addNode(name:"大厅",kind:.junction,position:ProbePoint(0,-1.5,0))
        try editor.addNode(name:"东楼梯",kind:.stair,position:ProbePoint(5,-1.5,0))
        let entrance = try editor.addEntrance(name:"1309",position:ProbePoint(9,-1.5,1))
        XCTAssertTrue(editor.edges.isEmpty);XCTAssertEqual(entrance.attachment.kind,"space_point");XCTAssertTrue(editor.issues().isEmpty)
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"m",pointCount:200,voxel:0.1)
        XCTAssertTrue(map.usesSpaceRouting);try map.validate()
        XCTAssertEqual(map.namedChoices().rooms.map(\.name),["1309"]);XCTAssertEqual(map.namedChoices().others.map(\.name),["大厅","东楼梯"])
        XCTAssertEqual(Set(map.destinationGroups().map(\.name)),["1309","东楼梯"])
        var legacy = map;legacy.routing_mode = nil;XCTAssertThrowsError(try legacy.validate())   // a network map still needs edges
        var bogus = map;bogus.routing_mode = "magic";XCTAssertThrowsError(try bogus.validate())
    }
    func testSidecarPublishKeepsRouteAndIsVersioned() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        var editor = LiDARRouteEditor();editor.spaceMode = true
        try editor.addNode(name:"A",kind:.junction,position:ProbePoint(0,-1.5,0))
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"m",pointCount:200,voxel:0.1)
        try LiDARPointFile.encode((0..<200).map { ProbePoint(Double($0)*0.02,-1.5,0) }).write(to:temp.appendingPathComponent("geometry.f32"))
        try LiDARNavigationArchive.write(map,to:temp.appendingPathComponent("navigation.json"))
        let cal = LiDARPassageCalibration(mapID:map.map_id,geometrySHA256:nil,editor:"phone",paths:[LiDARSuggestedPath(points:[[0,0],[2,0]],source:"phone")])
        try LiDARMapVersions.publishSidecar(temp,name:LiDARPassageCalibration.fileName,data:JSONEncoder().encode(cal))
        XCTAssertEqual(try LiDARPassageCalibration.load(temp,mapID:map.map_id)?.suggested_paths.count,1)
        XCTAssertEqual(try LiDARNavigationArchive.load(temp).0.nodes,map.nodes);XCTAssertEqual(LiDARMapVersions.list(temp).count,1)
        XCTAssertThrowsError(try LiDARMapVersions.publishSidecar(temp,name:"navigation.json",data:Data()))
    }
}

final class LiDARFloorFieldAndTilesTests:XCTestCase {
    func testDriftingFloorIsStillWalkable() throws {
        // 40 m × 3 m corridor whose floor rises 0.4 m from one end to the other (vertical map drift).
        var p = [ProbePoint]()
        for x in stride(from:0.0,to:40,by:0.05) { let f = -1.5+0.01*x
            for z in stride(from:0.0,to:3,by:0.05) { p.append(ProbePoint(x,f,z)) }
            for y in stride(from:f,to:f+2.5,by:0.1) { p.append(ProbePoint(x,y,0));p.append(ProbePoint(x,y,3)) }
        }
        let g = try LiDARSpaceGrid.build(points:p)
        XCTAssertEqual(g.floorField!.floor(35,1.5),-1.15,accuracy:0.06)
        let r = LiDARSpacePlanner.route(g,from:(1,1.5),to:(39,1.5))
        XCTAssertEqual(r.status,"ok",r.reason);XCTAssertEqual(r.length_m ?? 0,38,accuracy:1)
        let back = try JSONDecoder().decode(LiDARSpaceGridFile.self,from:JSONEncoder().encode(LiDARSpaceGridFile(g,mapID:"m",geometrySHA256:nil))).spaceGrid()
        XCTAssertEqual(back.floorField,g.floorField)
    }
    func testTableTopIsNotTakenAsFloor() {
        var p = [ProbePoint]()
        for x in stride(from:0.0,to:10,by:0.05) { for z in stride(from:0.0,to:10,by:0.05) {
            // A 2 m table at height 0.75 above the floor covering block (2,2) entirely.
            if x >= 4 && x < 6 && z >= 4 && z < 6 { p.append(ProbePoint(x,-0.75,z)) } else { p.append(ProbePoint(x,-1.5,z)) }
        } }
        XCTAssertEqual(LiDARFloorField.build(p).floor(5,5),-1.5,accuracy:0.01)
    }
    func testEveryPlaceWithStructureIsCoveredByATileWindow() {
        // Codex's counterexample: structure near (0,0), (50,50) and (100,100).
        var map = [ProbePoint]()
        for c in [0.0,50.0,100.0] { for i in 0..<5 { for j in 0..<5 { map.append(ProbePoint(c+Double(i)*0.05,0,c+Double(j)*0.05)) } } }
        let centers = LiDARLocalizer.tileCenters(map)
        for p in map { XCTAssertLessThanOrEqual(centers.map { hypot($0.x-p.x,$0.z-p.z) }.min() ?? .infinity,15,"\(p)") }
    }
}
