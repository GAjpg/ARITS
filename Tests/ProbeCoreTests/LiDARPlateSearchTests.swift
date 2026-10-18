import XCTest
@testable import ProbeCore

final class LiDARPlateSearchTests:XCTestCase {
    private func room(dx:Double = 0) -> [ProbePoint] {
        var points = [ProbePoint]()
        for x in stride(from:0.0,through:5.4,by:0.18) {
            for z in stride(from:-4.0,through:0.0,by:0.18) { points.append(ProbePoint(x+dx,-1.5,z)) }
            for y in stride(from:-1.5,through:1.0,by:0.18) { points.append(ProbePoint(x+dx,y,-4)) }
        }
        for z in stride(from:-4.0,through:0.0,by:0.18) { for y in stride(from:-1.5,through:1.0,by:0.18) { points.append(ProbePoint(dx,y,z)) } }
        for x in stride(from:2.6,through:3.4,by:0.12) { for y in stride(from:-1.5,through:0.6,by:0.15) { points.append(ProbePoint(x+dx,y,-1.3));points.append(ProbePoint(3.4+dx,y,x-4.7)) } }
        return points
    }
    private let yaw = 1.13
    private func toQuery(_ p:ProbePoint) -> ProbePoint {
        let c = cos(yaw),s = sin(yaw),x = p.x-1.1,z = p.z+2.3
        return ProbePoint(c*x-s*z,p.y+0.28,s*x+c*z)
    }
    private func plate(_ text:String,center:ProbePoint,normal:ProbePoint,node:String?) -> LiDARLandmark {
        var l = LiDARLandmark(category:.room_plate,trigger:.manual,text:LiDARLandmarkText(raw:text,candidates:[],confirmedByUser:true,edited:false),destination:LiDARLandmarkDestination(enabled:node != nil,node_id:node),
                              geometry:LiDARLandmarkGeometryResult(status:"measured",center:center,normal:normal,spread_m:0.01,observations:3,reason:"ok"),evidence:[])
        l.mount = .wall;return l
    }
    private func map(_ nodes:[LiDARRouteNode]) -> LiDARNavigationMap {
        LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"m",pointCount:500,nodes:nodes,
                           edges:zip(nodes,nodes.dropFirst()).map { LiDARRouteEdge($0.id,$1.id) })
    }
    func testCentersUseExactTextEveryEntranceAndMergeDuplicates() {
        let nodes = [LiDARRouteNode(name:"走廊",position:ProbePoint(0,-1.5,0),id:"w"),
                     LiDARRouteNode(name:"1309",position:ProbePoint(2,-1.5,0),id:"e1",kind:.room),
                     LiDARRouteNode(name:"1309",position:ProbePoint(9,-1.5,0),id:"e2",kind:.room)]
        let plates = [plate("1309",center:ProbePoint(2.3,-0.1,0.2),normal:ProbePoint(0,0,-1),node:"e1"),
                      plate("1308",center:ProbePoint(5,-0.1,0),normal:ProbePoint(0,0,-1),node:nil)]
        let centers = LiDARPlateSearch.centers(text:"１３０９",landmarks:plates,map:map(nodes))
        XCTAssertEqual(centers.map(\.node_id),["e1","e2"])        // plate centre within 1 m of e1 is merged
        XCTAssertTrue(LiDARPlateSearch.centers(text:"130",landmarks:plates,map:map(nodes)).isEmpty)
    }
    func testPlatePoseRecoversKnownTransform() throws {
        let mapCenter = ProbePoint(3,0.2,-4),mapNormal = ProbePoint(0,0,1)
        let qc = toQuery(mapCenter),c = cos(yaw),s = sin(yaw)
        let qn = ProbePoint(c*mapNormal.x-s*mapNormal.z,0,s*mapNormal.x+c*mapNormal.z)
        let geometry = { (p:ProbePoint,n:ProbePoint) in LiDARLandmarkGeometryResult(status:"measured",center:p,normal:n,spread_m:0,observations:3,reason:"ok") }
        let t = try XCTUnwrap(LiDARPlateSearch.poseFromPlate(query:geometry(qc,qn),map:geometry(mapCenter,mapNormal)))
        let back = CampusMapGeometry.point([qc.x,qc.y,qc.z],through:t)
        XCTAssertEqual(back[0],3,accuracy:1e-9);XCTAssertEqual(back[2],-4,accuracy:1e-9)
        let other = toQuery(ProbePoint(0,0,0)),mapped = CampusMapGeometry.point([other.x,other.y,other.z],through:t)
        XCTAssertEqual(mapped[0],0,accuracy:1e-9);XCTAssertEqual(mapped[2],0,accuracy:1e-9)
        XCTAssertNil(LiDARPlateSearch.poseFromPlate(query:.unknown(),map:geometry(mapCenter,mapNormal)))
    }
    private func cameraX(_ c:LiDARLocalizationCandidate,_ cam:ProbePoint) -> [Double] { CampusMapGeometry.point([cam.x,cam.y,cam.z],through:c.transform_query_to_map) }
    func testOverlappingWindowsCountOnceAndTwinRoomsStayAmbiguousUntilPlatePoseOrders() throws {
        let single = room(),query = single.enumerated().filter { $0.offset%3 != 0 && $0.element.x < 4.4 }.map { toQuery($0.element) }
        let cam = toQuery(ProbePoint(2,0,-2))
        let a = LiDARPlateSearch.Center(position:ProbePoint(2,-1.5,-1),landmark_id:nil,node_id:"a",source:"entrance")
        let once = LiDARPlateSearch.solve(map:single,query:query,sessionID:"s",referenceCamera:cam,centers:[a],maxSeconds:40)
        let twice = LiDARPlateSearch.solve(map:single,query:query,sessionID:"s",referenceCamera:cam,centers:[a,a],maxSeconds:40)
        XCTAssertEqual(once.candidates.count,twice.candidates.count)          // the same window twice adds nothing
        XCTAssertTrue(once.candidates.contains { let p = cameraX($0,cam);return hypot(p[0]-2,p[2]+2) < 0.3 })
        XCTAssertEqual(once.search_scope?.kind,"plate_entrance_windows")
        // Two identical rooms 9 m apart, one entrance each: both are kept and the result is ambiguous.
        let twin = single+room(dx:9)
        let b = LiDARPlateSearch.Center(position:ProbePoint(11,-1.5,-1),landmark_id:nil,node_id:"c",source:"entrance")
        let amb = LiDARPlateSearch.solve(map:twin,query:query,sessionID:"s",referenceCamera:cam,centers:[a,b],maxSeconds:40)
        XCTAssertEqual(amb.status,"ambiguous")
        let xs = amb.candidates.map { cameraX($0,cam)[0] }
        XCTAssertTrue(xs.contains { abs($0-2) < 0.3 } && xs.contains { abs($0-11) < 0.3 })
        // The plate seen belongs to the second room: its pose moves that candidate first; still ambiguous.
        let normal = ProbePoint(0,0,1),c = cos(yaw),s = sin(yaw)
        let g = { (p:ProbePoint,n:ProbePoint) in LiDARLandmarkGeometryResult(status:"measured",center:p,normal:n,spread_m:0,observations:3,reason:"ok") }
        let qPlate = toQuery(ProbePoint(3,0.2,-4))
        let pose = LiDARPlateSearch.poseFromPlate(query:g(qPlate,ProbePoint(c*normal.x-s*normal.z,0,s*normal.x+c*normal.z)),map:g(ProbePoint(12,0.2,-4),normal))!
        let ordered = LiDARPlateSearch.solve(map:twin,query:query,sessionID:"s",referenceCamera:cam,centers:[a,b],maxSeconds:40,platePose:pose,platePoint:qPlate)
        XCTAssertEqual(ordered.status,"ambiguous");XCTAssertTrue(ordered.decision_reasons!.contains("plate_pose_supports_one"))
        XCTAssertEqual(cameraX(ordered.candidates[0],cam)[0],11,accuracy:0.3)
    }
    func testCompassYawPriorRestrictsTheSearch() {
        let single = room(),query = single.enumerated().filter { $0.offset%3 != 0 && $0.element.x < 4.4 }.map { toQuery($0.element) }
        let truth = yaw*180/Double.pi
        func yawOf(_ c:LiDARLocalizationCandidate) -> Double { atan2(c.transform_query_to_map[0][2],c.transform_query_to_map[0][0])*180/Double.pi }
        let right = LiDARLocalizer.solve(map:single,query:query,sessionID:"s",maxSeconds:40,yawPrior:(truth,20))
        XCTAssertEqual(right.yaw_prior_deg,[truth,20])
        XCTAssertTrue(right.candidates.contains { $0.quality_gate && abs(LiDARMagnetic.wrap(yawOf($0)-truth)) < 5 })
        XCTAssertTrue(right.candidates.allSatisfy { abs(LiDARMagnetic.wrap(yawOf($0)-truth)) < 45 })
        let wrong = LiDARLocalizer.solve(map:single,query:query,sessionID:"s",maxSeconds:40,yawPrior:(truth+180,20))
        XCTAssertFalse(wrong.candidates.contains { abs(LiDARMagnetic.wrap(yawOf($0)-truth)) < 30 })
    }
    func testUnsearchedWindowsPreventAUniqueAnswer() {
        let single = room(),query = single.enumerated().filter { $0.offset%3 != 0 && $0.element.x < 4.4 }.map { toQuery($0.element) }
        let cam = toQuery(ProbePoint(2,0,-2))
        let a = LiDARPlateSearch.Center(position:ProbePoint(2,-1.5,-1),landmark_id:nil,node_id:"a",source:"entrance")
        let far = LiDARPlateSearch.Center(position:ProbePoint(40,-1.5,40),landmark_id:nil,node_id:"z",source:"entrance")
        // Time runs out after the first window: the second is never searched.
        let r = LiDARPlateSearch.solve(map:single,query:query,sessionID:"s",referenceCamera:cam,centers:[a,far,far],maxSeconds:0.01)
        XCTAssertNotEqual(r.status,"candidate_requires_review")
        XCTAssertEqual(r.search_complete,false)
        XCTAssertEqual(r.plate_windows?.count,3)
        XCTAssertTrue(r.plate_windows!.contains { $0.hasSuffix(":not_searched") || $0.hasSuffix(":incomplete") })
    }
}

final class LiDARTiledSearchTests:XCTestCase {
    /// A long corridor (100 m) with distinctive side rooms; the query sees one room near x = 70.
    private func corridor() -> [ProbePoint] {
        var p = [ProbePoint]()
        for x in stride(from:0.0,to:100,by:0.15) {
            for z in stride(from:0.0,to:3,by:0.15) { p.append(ProbePoint(x,-1.5,z)) }
            for y in stride(from:-1.5,to:1.0,by:0.15) { p.append(ProbePoint(x,y,0));if Int(x/0.15) % 40 > 6 { p.append(ProbePoint(x,y,3)) } }
        }
        // A unique alcove at x 68…72 behind the far wall.
        for x in stride(from:68.0,to:72,by:0.12) { for y in stride(from:-1.5,to:1.0,by:0.12) { p.append(ProbePoint(x,y,5)) } }
        for z in stride(from:3.0,to:5,by:0.12) { for y in stride(from:-1.5,to:1.0,by:0.12) { p.append(ProbePoint(68,y,z));p.append(ProbePoint(72,y,z)) } }
        for x in stride(from:68.0,to:72,by:0.15) { for z in stride(from:3.0,to:5,by:0.15) { p.append(ProbePoint(x,-1.5,z)) } }
        return p
    }
    func testLargeMapIsSearchedInTilesInsteadOfRejected() {
        let map = corridor()
        XCTAssertEqual(LiDARLocalizer.solve(map:map,query:map,sessionID:"s").decision_reasons,["map_too_large"])
        XCTAssertGreaterThan(LiDARLocalizer.tileCenters(map).count,3)
        let query = map.filter { $0.x > 64 && $0.x < 76 }.map { ProbePoint($0.x-70,$0.y,$0.z-2) }    // query frame centred at the alcove
        let r = LiDARLocalizer.solveGlobal(map:map,query:query,sessionID:"s",referenceCamera:ProbePoint(0,0,0),maxSeconds:120)
        XCTAssertNotEqual(r.decision_reasons ?? [],["map_too_large"])
        XCTAssertEqual(r.search_scope?.kind,"tiled_global")
        XCTAssertTrue(r.candidates.contains { abs($0.transform_query_to_map[0][3]-70) < 0.5 && abs($0.transform_query_to_map[2][3]-2) < 0.5 },"\(r.candidates.map { [$0.transform_query_to_map[0][3],$0.transform_query_to_map[2][3]] })")
        XCTAssertEqual(r.plate_windows?.count,LiDARLocalizer.tileCenters(map).count)
    }
}

final class LiDARPlateNameTests:XCTestCase {
    private func plate(_ text:String,name:String?,node:String?) -> LiDARLandmark {
        var l = LiDARLandmark(category:.room_plate,trigger:.manual,text:LiDARLandmarkText(raw:text,candidates:[],confirmedByUser:true,edited:false),
                              destination:LiDARLandmarkDestination(enabled:node != nil,node_id:node),geometry:.unknown(),evidence:[])
        l.display_name = name;return l
    }
    func testDisplayNameIsSeparateFromRecognitionText() throws {
        let p = plate("3-132",name:"132",node:"e")
        XCTAssertEqual(p.displayName,"132");XCTAssertEqual(p.text.normalized,"3132")
        // Older JSON without the field still loads.
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as! [String:Any];json.removeValue(forKey:"display_name")
        let old = try JSONDecoder().decode(LiDARLandmark.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertNil(old.display_name);XCTAssertEqual(old.displayName,"3-132")
    }
    func testRenamedEntranceIsNotARecognitionAlias() {
        // Entrance node named "132" bound to the plate "3-132"; a separate manual room also named "132".
        var editor = LiDARRouteEditor();editor.spaceMode = true
        let bound = try! editor.addEntrance(name:"132",position:ProbePoint(0,-1.5,0)).node
        let manual = try! editor.addEntrance(name:"132",position:ProbePoint(20,-1.5,0)).node
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"m",pointCount:200,voxel:0.1)
        let plates = [plate("3-132",name:"132",node:bound.id)]
        XCTAssertEqual(LiDARPlateSearch.centers(text:"3-132",landmarks:plates,map:map).compactMap(\.node_id),[bound.id])
        // Reading "132" matches no plate text; only the unbound manual room by its own name.
        XCTAssertEqual(LiDARPlateSearch.centers(text:"132",landmarks:plates,map:map).compactMap(\.node_id),[manual.id])
    }
}
