import XCTest
@testable import ProbeCore

final class OutdoorCampusTests: XCTestCase {
    private var source: URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets/Outdoor/campus.json")
    }
    func testRealCampusAndUnknownFloorRemainUnknown() throws {
        let c = try OutdoorCampus.decode(Data(contentsOf:source))
        XCTAssertEqual(c.buildings.count,88); XCTAssertEqual(c.graph.nodes.count,686); XCTAssertEqual(c.graph.edges.count,790)
        XCTAssertEqual(c.buildings.reduce(0) { $0+$1.entrances.count },160)
        let center = try XCTUnwrap(c.building(id:"w832289363"))
        XCTAssertNil(center.levels)
        XCTAssertEqual(center.entrances.count,3)
        XCTAssertTrue(c.source.contains("OpenStreetMap"))
    }
    func testCoordinateOrderAndLocalFrameRoundTrip() throws {
        let c = try OutdoorCampus.decode(Data(contentsOf:source)), f = c.frame
        XCTAssertEqual(c.origin.latitude,31.1785599,accuracy:1e-8)
        let p = f.coordinate(east:52,north:-38), q = f.local(p)
        XCTAssertEqual(q.east,52,accuracy:1e-6); XCTAssertEqual(q.north,-38,accuracy:1e-6)
        XCTAssertEqual(f.bearing(c.origin,f.coordinate(east:0,north:20)),0,accuracy:1e-5)
        XCTAssertEqual(f.bearing(c.origin,f.coordinate(east:20,north:0)),90,accuracy:1e-5)
    }
    func testRejectsInvalidGraphAndLatitudeLongitudeSwap() throws {
        let data = try Data(contentsOf:source)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var graph = try XCTUnwrap(root["graph"] as? [String:Any])
        var edges = try XCTUnwrap(graph["edges"] as? [[Any]])
        edges[0][1] = 999999; graph["edges"] = edges; root["graph"] = graph
        XCTAssertThrowsError(try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root)))
        root = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var meta = try XCTUnwrap(root["meta"] as? [String:Any]); meta["origin"] = [121.590965,31.1785599]; root["meta"] = meta
        XCTAssertThrowsError(try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root)))
    }
    func testRejectsNegativeOrUnderweightedEdges() throws {
        let data = try Data(contentsOf:source)
        for bad in [-1.0,0.5] {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            var graph = try XCTUnwrap(root["graph"] as? [String:Any]), edges = try XCTUnwrap(graph["edges"] as? [[Any]])
            edges[0][3] = bad; graph["edges"] = edges; root["graph"] = graph
            XCTAssertThrowsError(try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root)))
        }
    }
    func testPresentationDoesNotInventMeasurementsOrElevatorETA() {
        var s = NavigationShellState(destination:"会议中心 · 132",phase:.indoorRecovery)
        XCTAssertNil(s.durationSeconds); XCTAssertNil(s.arrivalTime)
        s.maneuver = .recover; s.maneuverDistanceM = 12
        XCTAssertEqual(s.instruction,"缓慢观察周围")
        s.maneuver = .left; XCTAssertEqual(s.instruction,"12 米后左转")
        XCTAssertEqual(NavigationShellState.distance(.nan),"—")
    }
    func testVerifiedEntranceRemainsExactEndAndPathIsConnected() throws {
        let c = try OutdoorCampus.decode(Data(contentsOf:source)), router = OutdoorRouter(campus:c)
        let b = try XCTUnwrap(c.building(id:"w832289363")), door = try XCTUnwrap(b.entrances.first)
        let route = try XCTUnwrap(router.plan(from:c.graph.nodes[0],buildingID:b.id,entrances:[door]))
        XCTAssertEqual(route.points.last,door.coordinate)
        XCTAssertEqual(route.entrance,door)
        XCTAssertEqual(route.nodeIndices.last,door.nodeIndex)
        for pair in zip(route.nodeIndices,route.nodeIndices.dropFirst()) {
            XCTAssertTrue(c.graph.edges.contains { ($0.from == pair.0 && $0.to == pair.1) || ($0.to == pair.0 && $0.from == pair.1) })
        }
        XCTAssertEqual(route.projection(route.points[0]).alongM,0,accuracy:0.01)
        XCTAssertEqual(route.point(at:route.lengthM),door.coordinate)
        XCTAssertNil(router.plan(from:c.graph.nodes[0],buildingID:b.id,entrances:[]))
    }
    func testAllActualCampusEntrancesHaveGraphPaths() throws {
        let c = try OutdoorCampus.decode(Data(contentsOf:source)), router = OutdoorRouter(campus:c)
        for b in c.buildings {
            for door in b.entrances {
                let p = try XCTUnwrap(router.routeNodes(from:0,to:door.nodeIndex))
                XCTAssertEqual(p.nodes.first,0);XCTAssertEqual(p.nodes.last,door.nodeIndex)
                let summed = p.edgeIndices.reduce(0.0) { $0+c.graph.edges[$1].cost }
                XCTAssertEqual(p.cost,summed,accuracy:1e-6)
            }
        }
        XCTAssertNil(router.routeNodes(from:-1,to:0))
        let f = c.frame, far = f.coordinate(east:5000,north:5000)
        XCTAssertNil(router.plan(from:far,buildingID:c.buildings[0].id))
    }

    private func accessCampus(blocker:Bool = false) throws -> OutdoorCampus {
        let f = OutdoorLocalFrame(origin:.init(latitude:31,longitude:121))
        func point(_ x:Double,_ y:Double) -> [Double] { let p = f.coordinate(east:x,north:y);return [p.latitude,p.longitude] }
        func building(_ id:String,_ x:Double,_ y:Double,_ w:Double,_ h:Double) -> [String:Any] {
            ["osm":id,"name":id,"ring":[point(x,y),point(x+w,y),point(x+w,y+h),point(x,y+h)],"centroid":point(x+w/2,y+h/2),"doors":[]]
        }
        var buildings = [building("target",80,5,10,10)]
        if blocker { buildings.append(building("thin-wall",70,2,30,0.1)) }
        let root:[String:Any] = ["v":1,"meta":["name":"test","source":"synthetic","origin":[31,121]],
            "campusRing":[point(-20,-20),point(120,-20),point(120,40),point(-20,40)],"buildings":buildings,
            "graph":["nodes":[point(0,0),point(100,0)],"edges":[[0,1,100,1,"footway",""]]]]
        return try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root))
    }
    func testCoordinateOnlyDoorSplitsEdgeAndKeepsExactPhysicalEnd() throws {
        let c = try accessCampus(), f = c.frame,router = OutdoorRouter(campus:c)
        let door = OutdoorEntrance(coordinate:f.coordinate(east:85,north:5),nodeIndex:-1,bindingID:"physical-east-door")
        let route = try XCTUnwrap(router.plan(from:f.coordinate(east:20,north:0),buildingID:"target",entrances:[door]))
        XCTAssertEqual(route.entrance,door);XCTAssertEqual(route.entrance.bindingID,"physical-east-door");XCTAssertEqual(route.points.last,door.coordinate)
        XCTAssertEqual(route.lengthM,70,accuracy:0.01) // 65 m on the edge plus 5 m to the actual door.
        XCTAssertLessThanOrEqual(route.points.count,4)
    }
    func testCoordinateOnlyDoorCannotCrossBuildingOrThinFootprint() throws {
        for blocked in [false,true] {
            let c = try accessCampus(blocker:blocked), f = c.frame,router = OutdoorRouter(campus:c)
            let door = OutdoorEntrance(coordinate:f.coordinate(east:85,north:blocked ? 5 : 15),nodeIndex:-1)
            XCTAssertNil(router.plan(from:f.coordinate(east:20,north:0),buildingID:"target",entrances:[door]))
        }
        let c = try accessCampus(), f = c.frame, router = OutdoorRouter(campus:c)
        let far = OutdoorEntrance(coordinate:f.coordinate(east:85,north:-21),nodeIndex:-1)
        XCTAssertNil(router.plan(from:c.graph.nodes[0],buildingID:"target",entrances:[far]))
        let invalid = OutdoorEntrance(coordinate:f.coordinate(east:85,north:5),nodeIndex:9999)
        XCTAssertNil(router.plan(from:c.graph.nodes[0],buildingID:"target",entrances:[invalid]))
    }
    func testRealCoordinateBindingDoesNotRequireDatasetIndex() throws {
        let c = try OutdoorCampus.decode(Data(contentsOf:source)), b = try XCTUnwrap(c.building(id:"w832289363"))
        let door = OutdoorEntrance(coordinate:try XCTUnwrap(b.entrances.first).coordinate,nodeIndex:-1)
        let route = try XCTUnwrap(OutdoorRouter(campus:c).plan(from:c.graph.nodes[0],buildingID:b.id,entrances:[door]))
        XCTAssertEqual(route.points.last,door.coordinate);XCTAssertEqual(route.entrance.nodeIndex,-1)
    }

    private func graphCampus(_ nodes:[[Double]],_ edges:[[Int]],blockStart:Bool = false) throws -> OutdoorCampus {
        let f = OutdoorLocalFrame(origin:.init(latitude:31,longitude:121))
        func point(_ p:[Double]) -> [Double] { let c = f.coordinate(east:p[0],north:p[1]);return [c.latitude,c.longitude] }
        var buildings:[[String:Any]] = [["osm":"target","name":"Target","ring":[[25.0,10],[30,10],[30,15],[25,15]].map(point),"centroid":point([27,12]),"doors":[]]]
        if blockStart { buildings.append(["osm":"wall","name":"wall","ring":[[4.0,1],[6,1],[6,1.1],[4,1.1]].map(point),"centroid":point([5,1.05]),"doors":[]]) }
        let encodedEdges:[[Any]] = edges.map { e in [e[0],e[1],hypot(nodes[e[0]][0]-nodes[e[1]][0],nodes[e[0]][1]-nodes[e[1]][1]),1,"footway",""] }
        let root:[String:Any] = ["v":1,"meta":["name":"test","source":"synthetic","origin":[31,121]],"campusRing":[[-20.0,-20],[120,-20],[120,40],[-20,40]].map(point),"buildings":buildings,"graph":["nodes":nodes.map(point),"edges":encodedEdges]]
        return try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root))
    }
    func testDetailedPlannerTriesSecondStartComponentWithoutChangingOldPlan() throws {
        let c = try graphCampus([[0,0],[20,0],[0,3],[20,3]],[[0,1],[2,3]]),f = c.frame,r = OutdoorRouter(campus:c)
        let door = OutdoorEntrance(coordinate:c.graph.nodes[3],nodeIndex:3),start = f.coordinate(east:5,north:0.2)
        XCTAssertNil(r.plan(from:start,buildingID:"target",entrances:[door],maximumSnapM:5))
        let result = r.planDetailed(from:start,buildingID:"target",entrances:[door],maximumSnapM:5)
        let route = try XCTUnwrap(result.route)
        XCTAssertNil(result.failure);XCTAssertEqual(result.attemptedStartCandidates,2)
        XCTAssertEqual(route.accessDistanceM,2.8,accuracy:0.01);XCTAssertEqual(route.nodeIndices.last,3)
    }
    func testDetailedPlannerTriesSecondCoordinateDoorEdge() throws {
        let c = try graphCampus([[0,0],[20,0],[15,3],[20,3]],[[0,1],[2,3]]),f = c.frame,r = OutdoorRouter(campus:c)
        let door = OutdoorEntrance(coordinate:f.coordinate(east:20,north:4),nodeIndex:-1,bindingID:"door-A")
        let result = r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[door],maximumSnapM:0.1,maximumEntranceSnapM:5)
        let route = try XCTUnwrap(result.route)
        XCTAssertNil(result.failure);XCTAssertEqual(result.entranceCandidateCount,2)
        XCTAssertEqual(route.lengthM,24,accuracy:0.01);XCTAssertEqual(route.entrance.bindingID,"door-A")
    }
    func testDetailedPlannerRejectsThinWallAtStartAndTriesClearSide() throws {
        let c = try graphCampus([[0,0],[20,0],[0,5],[20,5]],[[0,1],[2,3]],blockStart:true),f = c.frame
        let result = OutdoorRouter(campus:c).planDetailed(from:f.coordinate(east:5,north:2),buildingID:"target",entrances:[.init(coordinate:c.graph.nodes[3],nodeIndex:3)],maximumSnapM:4)
        XCTAssertNil(result.failure);XCTAssertEqual(result.attemptedStartCandidates,2)
        XCTAssertEqual(try XCTUnwrap(result.route).accessDistanceM,3,accuracy:0.01)
        let blocked = try graphCampus([[0,0],[20,0]],[[0,1]],blockStart:true)
        XCTAssertEqual(OutdoorRouter(campus:blocked).planDetailed(from:f.coordinate(east:5,north:2),buildingID:"target",entrances:[.init(coordinate:blocked.graph.nodes[1],nodeIndex:1)],maximumSnapM:4).failure,.startBlocked)
    }
    func testDetailedPlannerLeavesTheBuildingTheStartIsIn() throws {
        let c = try graphCampus([[0,0],[20,0]],[[0,1]],blockStart:true),f = c.frame
        // Inside the thin building: the connector may walk out of it, but not through another one.
        let route = try XCTUnwrap(OutdoorRouter(campus:c).planDetailed(from:f.coordinate(east:5,north:1.05),buildingID:"target",entrances:[.init(coordinate:c.graph.nodes[1],nodeIndex:1)],maximumSnapM:4).route)
        XCTAssertEqual(route.accessDistanceM,1.05,accuracy:0.01)
    }
    func testDetailedFailureReasonsDistinguishInputDistanceDoorAndConnectivity() throws {
        let c = try graphCampus([[0,0],[20,0],[0,3],[20,3]],[[0,1],[2,3]]),f = c.frame,r = OutdoorRouter(campus:c),door = OutdoorEntrance(coordinate:c.graph.nodes[3],nodeIndex:3)
        XCTAssertEqual(r.planDetailed(from:c.graph.nodes[0],buildingID:"missing").failure,.unknownBuilding)
        XCTAssertEqual(r.planDetailed(from:.init(latitude:.nan,longitude:0),buildingID:"target").failure,.invalidInput)
        XCTAssertEqual(r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[]).failure,.noEntrances)
        let far = r.planDetailed(from:f.coordinate(east:5,north:-2),buildingID:"target",entrances:[door],maximumSnapM:1)
        XCTAssertEqual(far.failure,.startTooFar);XCTAssertEqual(try XCTUnwrap(far.nearestStartDistanceM),2,accuracy:0.01)
        XCTAssertEqual(r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[door],maximumSnapM:1).failure,.disconnected)
        XCTAssertEqual(r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[.init(coordinate:f.coordinate(east:10,north:20),nodeIndex:-1)],maximumEntranceSnapM:1).failure,.entranceNoAccess)
        let empty = try graphCampus([[0,0]],[])
        XCTAssertEqual(OutdoorRouter(campus:empty).planDetailed(from:empty.graph.nodes[0],buildingID:"target",entrances:[.init(coordinate:empty.graph.nodes[0],nodeIndex:0)]).failure,.noCandidateEdges)
    }
    private func routeFixture(_ xy:[[Double]]) -> OutdoorRoute {
        let f = OutdoorLocalFrame(origin:.init(latitude:31,longitude:121)),points = xy.map { f.coordinate(east:$0[0],north:$0[1]) }
        var distances = [0.0]
        for i in 1..<points.count { distances.append(distances[i-1]+f.distance(points[i-1],points[i])) }
        return .init(buildingID:"test",entrance:.init(coordinate:points.last!,nodeIndex:0),nodeIndices:[],points:points,cumulativeM:distances,steps:[],selectionScore:0,accessDistanceM:0)
    }
    func testProgressWindowDoesNotJumpToParallelReturnLeg() throws {
        let route = routeFixture([[0,0],[100,0],[100,2],[0,2]]),f = OutdoorLocalFrame(origin:route.points[0]),p = f.coordinate(east:10,north:1.8)
        XCTAssertGreaterThan(route.projection(p).alongM,180)
        let local = try XCTUnwrap(route.projection(p,near:10,window:15))
        XCTAssertEqual(local.alongM,10,accuracy:0.01);XCTAssertEqual(local.lateralM,1.8,accuracy:0.01)
        XCTAssertLessThan(local.alongM,25)
    }
    func testProgressWindowClipsLongSegmentAndRejectsInvalidHints() throws {
        let route = routeFixture([[0,0],[100,0]]),f = OutdoorLocalFrame(origin:route.points[0]),p = f.coordinate(east:95,north:0)
        XCTAssertEqual(try XCTUnwrap(route.projection(p,near:10,window:5)).alongM,15,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(route.projection(p,near:10,window:0)).alongM,10,accuracy:0.01)
        XCTAssertEqual(route.projection(p).alongM,95,accuracy:0.01)
        for hint in [-1.0,101,.nan,.infinity] { XCTAssertNil(route.projection(p,near:hint,window:5)) }
        for window in [-1.0,.nan,.infinity] { XCTAssertNil(route.projection(p,near:10,window:window)) }
    }
    func testProgressAtIntersectionPrefersHintOnDistanceTie() throws {
        let route = routeFixture([[0,0],[20,20],[0,20],[20,0]]),f = OutdoorLocalFrame(origin:route.points[0]),p = f.coordinate(east:10,north:10),hint = route.lengthM-sqrt(200)
        let near = try XCTUnwrap(route.projection(p,near:hint,window:route.lengthM))
        XCTAssertGreaterThan(near.alongM,50);XCTAssertLessThan(route.projection(p).alongM,20)
    }

    func testHandDrawnAccessRemainsExactTailAndCountsTurnsAndLength() throws {
        let c = try accessCampus(blocker:true),f = c.frame,r = OutdoorRouter(campus:c)
        let path = [[85.0,10],[75,10],[75,0]].map { f.coordinate(east:$0[0],north:$0[1]) }
        let door = OutdoorEntrance(coordinate:path[0],nodeIndex:-1,bindingID:"manual-door",accessPath:path)
        for route in [r.plan(from:f.coordinate(east:20,north:0),buildingID:"target",entrances:[door]),r.planDetailed(from:f.coordinate(east:20,north:0),buildingID:"target",entrances:[door]).route] {
            let route = try XCTUnwrap(route)
            XCTAssertEqual(Array(route.points.suffix(path.count)),Array(path.reversed()))
            XCTAssertEqual(route.entrance,door);XCTAssertEqual(route.points.last,door.coordinate)
            XCTAssertEqual(route.lengthM,75,accuracy:0.02)
            XCTAssertTrue(route.steps.contains { $0.maneuver == .left });XCTAssertTrue(route.steps.contains { $0.maneuver == .right })
        }
        let noPath = OutdoorEntrance(coordinate:path[0],nodeIndex:-1,bindingID:"manual-door")
        XCTAssertNil(r.plan(from:c.graph.nodes[0],buildingID:"target",entrances:[noPath]))
    }
    func testManualAccessEndpointBeyondThreeMetresHasSpecificFailure() throws {
        let c = try accessCampus(),f = c.frame,r = OutdoorRouter(campus:c)
        let path = [[85.0,5],[85,3.2]].map { f.coordinate(east:$0[0],north:$0[1]) }
        let door = OutdoorEntrance(coordinate:path[0],nodeIndex:1,accessPath:path)
        let result = r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[door],maximumEntranceSnapM:100)
        XCTAssertEqual(result.failure,.entranceNoAccess);XCTAssertNil(result.route)
        XCTAssertNil(r.plan(from:c.graph.nodes[0],buildingID:"target",entrances:[door]))
    }
    func testManualAccessEndpointTriesNextConnectedEdge() throws {
        let c = try graphCampus([[0,0],[20,0],[15,3],[20,3]],[[0,1],[2,3]]),f = c.frame,r = OutdoorRouter(campus:c)
        let path = [[25.0,4],[23,2.5],[20,2.5]].map { f.coordinate(east:$0[0],north:$0[1]) }
        let door = OutdoorEntrance(coordinate:path[0],nodeIndex:-1,accessPath:path)
        let result = r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[door],maximumSnapM:0.1)
        let route = try XCTUnwrap(result.route)
        XCTAssertNil(result.failure);XCTAssertEqual(result.entranceCandidateCount,2)
        XCTAssertEqual(Array(route.points.suffix(path.count)),Array(path.reversed()))
    }
    func testInvalidAccessIsNotSilentlyReplacedByStraightConnector() throws {
        let c = try accessCampus(),f = c.frame,r = OutdoorRouter(campus:c),door = f.coordinate(east:85,north:5)
        for path in [[],[door],[f.coordinate(east:86,north:5),f.coordinate(east:85,north:0)],[door,.init(latitude:.nan,longitude:121)]] as [[OutdoorCoordinate]] {
            let result = r.planDetailed(from:c.graph.nodes[0],buildingID:"target",entrances:[.init(coordinate:door,nodeIndex:1,accessPath:path)])
            XCTAssertEqual(result.failure,.entranceNoAccess)
        }
    }
    func testAccessPathDecodesOldAndBothCoordinateRepresentations() throws {
        let data = try Data(contentsOf:source)
        XCTAssertTrue(try OutdoorCampus.decode(data).buildings.allSatisfy { $0.entrances.allSatisfy { $0.accessPath == nil } })
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        var buildings = try XCTUnwrap(root["buildings"] as? [[String:Any]])
        let index = try XCTUnwrap(buildings.firstIndex { ($0["doors"] as? [[String:Any]])?.isEmpty == false })
        var doors = try XCTUnwrap(buildings[index]["doors"] as? [[String:Any]])
        let pos = try XCTUnwrap(doors[0]["pos"] as? [Double]),end = [pos[0]+0.00001,pos[1]]
        for value:Any in [[pos,end],[["latitude":pos[0],"longitude":pos[1]],["latitude":end[0],"longitude":end[1]]]] {
            doors[0]["access_path"] = value;buildings[index]["doors"] = doors;root["buildings"] = buildings
            let decoded = try OutdoorCampus.decode(JSONSerialization.data(withJSONObject:root))
            XCTAssertEqual(decoded.buildings[index].entrances[0].accessPath?.count,2)
            XCTAssertEqual(decoded.buildings[index].entrances[0].accessPath?.first,decoded.buildings[index].entrances[0].coordinate)
        }
    }

}
