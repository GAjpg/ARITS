import XCTest
@testable import ProbeCore

final class CampusTests: XCTestCase {
    private func matrix(_ x: Double, _ z: Double = 0) -> [[Double]] {
        [[1,0,0,x],[0,1,0,-1.2],[0,0,1,z],[0,0,0,1]]
    }
    private func fixture() throws -> CampusGraph {
        var g = CampusGraph(name: "两层测试楼")
        let f1 = CampusFloor(name: "一楼"), f2 = CampusFloor(name: "二楼")
        g.floors = [f1,f2]
        var r1 = CampusRegion(floorID: f1.id, name: "东区"), r2 = CampusRegion(floorID: f1.id, name: "西区")
        var r3 = CampusRegion(floorID: f2.id, name: "二楼区")
        r1.map_saved = true; r2.map_saved = true; r3.map_saved = true; g.regions = [r1,r2,r3]
        let room = CampusNode(floorID: f1.id, name: "101", kind: .room)
        let joint = CampusNode(floorID: f1.id, name: "交接点", kind: .junction)
        let stair1 = CampusNode(floorID: f1.id, name: "楼梯 A", kind: .stair)
        let stair2 = CampusNode(floorID: f2.id, name: "楼梯 A", kind: .stair)
        let destination = CampusNode(floorID: f2.id, name: "201", kind: .room)
        g.nodes = [room,joint,stair1,stair2,destination]
        for (region, node, x) in [(r1,room,0.0),(r1,joint,4.0),(r2,joint,100.0),(r2,stair1,106.0),(r3,stair2,0.0),(r3,destination,3.0)] {
            g.bindings.append(CampusBinding(regionID: region.id, nodeID: node.id, anchorID: UUID().uuidString, transform: matrix(x)))
        }
        try g.connect(room.id,joint.id,regionID: r1.id); try g.connect(joint.id,stair1.id,regionID: r2.id)
        g.edges.append(CampusEdge(stairFrom: stair1.id,to: stair2.id,cost: 8))
        try g.connect(stair2.id,destination.id,regionID: r3.id)
        try g.validate(); return g
    }
    func testSharedNodeConnectsDifferentCoordinateFramesAndFloors() throws {
        let g = try fixture(), p = try CampusRouter.plan(graph: g, from: g.nodes[0].id, to: g.nodes[4].id)
        XCTAssertEqual(p.total_cost_m, 21, accuracy: 1e-8)
        XCTAssertEqual(p.node_ids, g.nodes.map(\.id)); XCTAssertEqual(p.legs.count, 4)
        XCTAssertEqual(p.legs.map(\.kind), [.walk,.walk,.stairs,.walk])
        XCTAssertEqual(g.edges[1].length_m, 6) // Not 106m from another map's origin.
    }
    func testReverseRouteReversesArrowsAndStairEndpoints() throws {
        let g = try fixture(), p = try CampusRouter.plan(graph: g, from: g.nodes[4].id,to: g.nodes[0].id)
        XCTAssertEqual(p.node_ids, g.nodes.reversed().map(\.id)); XCTAssertEqual(p.total_cost_m,21)
        XCTAssertEqual(p.legs[1].node_ids,[g.nodes[3].id,g.nodes[2].id])
    }
    func testSecondStairCanBePreferredByTotalCost() throws {
        var g = try fixture()
        let a = CampusNode(floorID: g.floors[0].id,name: "楼梯 B",kind: .stair)
        let b = CampusNode(floorID: g.floors[1].id,name: "楼梯 B",kind: .stair)
        g.nodes += [a,b]
        for (r,n,x) in [(g.regions[0],a,1.0),(g.regions[2],b,2.0)] {
            g.bindings.append(CampusBinding(regionID: r.id,nodeID: n.id,anchorID: UUID().uuidString,transform: matrix(x)))
        }
        try g.connect(g.nodes[0].id,a.id,regionID: g.regions[0].id)
        g.edges.append(CampusEdge(stairFrom: a.id,to: b.id,cost: 8))
        try g.connect(b.id,g.nodes[4].id,regionID: g.regions[2].id)
        let p = try CampusRouter.plan(graph: g,from: g.nodes[0].id,to: g.nodes[4].id)
        XCTAssertEqual(p.total_cost_m,10); XCTAssertEqual(p.node_ids,[g.nodes[0].id,a.id,b.id,g.nodes[4].id])
    }
    func testDisconnectedDraftAndDisabledRoutesFail() throws {
        var g = try fixture(); g.regions[1].map_saved = false
        XCTAssertThrowsError(try CampusRouter.plan(graph: g,from: g.nodes[0].id,to: g.nodes[4].id))
        g.regions[1].map_saved = true; g.edges[2].enabled = false
        XCTAssertThrowsError(try CampusRouter.plan(graph: g,from: g.nodes[0].id,to: g.nodes[4].id))
    }
    func testGraphRejectsDuplicateIDsAndCrossMapMeasurement() throws {
        var g = try fixture(); g.nodes.append(g.nodes[0]); XCTAssertThrowsError(try g.validate())
        g = try fixture(); XCTAssertThrowsError(try g.connect(g.nodes[0].id,g.nodes[2].id,regionID: g.regions[0].id))
    }
    func testUnrelatedNodesDoNotAutomaticallyConnect() throws {
        var g = try fixture(); g.edges.removeAll()
        XCTAssertThrowsError(try CampusRouter.plan(graph: g,from: g.nodes[0].id,to: g.nodes[4].id))
    }
    func testStairMustJoinTwoFloorsAndStairNodes() throws {
        var g = try fixture(); g.edges[2].to = g.nodes[0].id; XCTAssertThrowsError(try g.validate())
        g = try fixture(); g.nodes[3].floor_id = g.floors[0].id; XCTAssertThrowsError(try g.validate())
    }
    func testSameRegionEdgesBecomeOneLegAndDuplicateEdgeIsNotAdded() throws {
        var g = try fixture()
        let count = g.edges.count
        try g.connect(g.nodes[1].id,g.nodes[0].id,regionID: g.regions[0].id)
        XCTAssertEqual(g.edges.count,count)
        let p = try CampusRouter.plan(graph: g,from: g.nodes[0].id,to: g.nodes[1].id)
        XCTAssertEqual(p.legs.count,1)
        XCTAssertEqual(try CampusRouter.plan(graph:g,from:g.nodes[0].id,to:g.nodes[0].id).legs.count,0)
    }
    private func package(_ g: CampusGraph, base: URL) throws -> (CampusLibrary, CampusGraph) {
        let library = CampusLibrary(root: base.appendingPathComponent("library"))
        var current = try library.save(CampusGraph(name: g.name,id: g.building_id))
        var draft = g; draft.revision = current.revision
        for r in g.regions {
            let source = base.appendingPathComponent("region-"+r.id)
            try FileManager.default.createDirectory(at: source.appendingPathComponent("references"),withIntermediateDirectories: true)
            let snapshot = CampusRegionSnapshot(graph: g,region: r,sessionID: UUID().uuidString,features: 100)
            try CampusFiles.encode(snapshot,to: source.appendingPathComponent("region.json"))
            // Synthetic archive bytes only; real AR unarchiving is validated by the iOS importer.
            try Data("synthetic-map".utf8).write(to:source.appendingPathComponent("environment.arworldmap"))
            for b in snapshot.bindings {
                try Data("synthetic-jpeg".utf8).write(to:source.appendingPathComponent("references/\(b.node_id).jpg"))
                try CampusFiles.encode(["synthetic_fixture":true],to:source.appendingPathComponent("references/\(b.node_id).json"))
            }
            try CampusFiles.manifest(source)
            current = try library.save(draft,regionSource: source,regionID: r.id); draft = current
        }
        return (library,current)
    }
    func testCompleteBackupRoundTripAndConflictCopiesWithoutOverwrite() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }; try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let (library,g) = try package(fixture(),base:base)
        let zip = base.appendingPathComponent("backup.zip"); try library.export(g.building_id,destination:zip)
        let imported = try library.importBackup(zip)
        XCTAssertNotEqual(imported.building_id,g.building_id); XCTAssertEqual(imported.nodes,g.nodes)
        XCTAssertEqual(try library.load(g.building_id),g)
        XCTAssertEqual(try CampusRouter.plan(graph:imported,from:g.nodes[0].id,to:g.nodes[4].id).total_cost_m,21)
        for r in imported.regions {
            let s = try library.verifyRegion(graph:imported,region:r,in:library.regionDirectory(buildingID:imported.building_id,regionID:r.id))
            XCTAssertEqual(s.building_id,imported.building_id)
        }
    }
    func testCorruptNativeArchiveValidatorLeavesLibraryUntouched() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }; try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let (library,g) = try package(fixture(),base:base)
        let zip = base.appendingPathComponent("backup.zip"); try library.export(g.building_id,destination:zip)
        XCTAssertThrowsError(try library.importBackup(zip,validateMap: { _,_ in throw CampusError.corrupt }))
        XCTAssertEqual(library.list().count,1); XCTAssertEqual(try library.load(g.building_id),g)
    }
    func testSingleRegionBackupRemainsRestorableWithAnUnfinishedRegion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }; try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let (library,original) = try package(fixture(),base:base)
        var draft = original; draft.regions.append(CampusRegion(floorID:original.floors[0].id,name:"未采集"))
        let g = try library.save(draft), zip = base.appendingPathComponent("region.zip")
        XCTAssertThrowsError(try library.export(g.building_id,destination:zip))
        try library.export(g.building_id,destination:zip,regionID:g.regions[0].id)
        let restored = try library.importBackup(zip)
        XCTAssertEqual(restored.regions,[g.regions[0]])
        XCTAssertEqual(restored.nodes.map(\.id),Array(g.nodes.prefix(2)).map(\.id))
        XCTAssertEqual(restored.edges.count,1); XCTAssertEqual(restored.bindings.count,2)
        XCTAssertEqual(try CampusRouter.plan(graph:restored,from:g.nodes[0].id,to:g.nodes[1].id).total_cost_m,4)
        XCTAssertEqual(try library.load(g.building_id),g)
    }
    func testImportPreservesAnExistingDamagedBuildingDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }; try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let (library,g) = try package(fixture(),base:base), zip = base.appendingPathComponent("backup.zip")
        try library.export(g.building_id,destination:zip)
        let pointer = library.root.appendingPathComponent(g.building_id+"/current.json")
        let damaged = Data("damaged-pointer".utf8); try damaged.write(to:pointer)
        let imported = try library.importBackup(zip)
        XCTAssertNotEqual(imported.building_id,g.building_id)
        XCTAssertEqual(try Data(contentsOf:pointer),damaged)
        XCTAssertThrowsError(try library.save(g))
    }
    func testStaleRevisionCannotReplaceSavedGraph() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let l = CampusLibrary(root:base), first = try l.save(CampusGraph(name:"楼"))
        var changed = first; changed.name = "楼二"; let second = try l.save(changed)
        XCTAssertThrowsError(try l.save(first)); XCTAssertEqual(try l.load(first.building_id),second)
    }
    func testZIPCRCDetectsTamperingAndExtractionIsRemoved() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let source = base.appendingPathComponent("source"); try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("hello".utf8).write(to:source.appendingPathComponent("a.txt"))
        let zip = base.appendingPathComponent("a.zip"); try ProbeZip.create(directory:source,destination:zip)
        var bytes = try Data(contentsOf:zip); let range = bytes.range(of:Data("hello".utf8))!; bytes[range.lowerBound] = 0
        try bytes.write(to:zip)
        let dest = base.appendingPathComponent("extracted")
        XCTAssertThrowsError(try CampusBackupZIP.extract(zip,to:dest)); XCTAssertFalse(FileManager.default.fileExists(atPath:dest.path))
    }
    func testZIPRejectsTraversalBeforeWritingOutsideDestination() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        try Data("safe".utf8).write(to:source.appendingPathComponent("a.txt"))
        let zip = base.appendingPathComponent("a.zip"); try ProbeZip.create(directory:source,destination:zip)
        var bytes = try Data(contentsOf:zip)
        let original = Data("source/a.txt".utf8), malicious = Data("../bad/a.txt".utf8)
        XCTAssertEqual(original.count,malicious.count)
        while let range = bytes.range(of:original) { bytes.replaceSubrange(range,with:malicious) }
        try bytes.write(to:zip)
        let dest = base.appendingPathComponent("extracted")
        XCTAssertThrowsError(try CampusBackupZIP.extract(zip,to:dest))
        XCTAssertFalse(FileManager.default.fileExists(atPath:base.appendingPathComponent("bad/a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:dest.path))
    }
    func testManifestRejectsUnlistedAndChangedFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }; try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let f = base.appendingPathComponent("a.json"); try Data("{}".utf8).write(to:f); try CampusFiles.manifest(base)
        try CampusFiles.verify(base)
        try Data("unexpected".utf8).write(to:base.appendingPathComponent("b")); XCTAssertThrowsError(try CampusFiles.verify(base))
        try FileManager.default.removeItem(at:base.appendingPathComponent("b")); try Data("tampered".utf8).write(to:f)
        XCTAssertThrowsError(try CampusFiles.verify(base))
    }
    func testWaypointNamesAreGeneratedWithoutCollidingWithExistingNames() throws {
        var g = try fixture(); XCTAssertEqual(g.nextWaypointName(),"P001")
        g.nodes[0].name = "P001";g.nodes[1].name = "P003"
        XCTAssertEqual(g.nextWaypointName(),"P002")
    }
    func testCurrentPositionIsProjectedInItsOwnRegionAndFarPositionsRejected() throws {
        let g = try fixture(),r = g.regions[1]
        let p = try CampusPositionLocator.locate(graph:g,regionID:r.id,point:[103,1,0.4])
        XCTAssertEqual(p.position.edge_id,g.edges[1].id);XCTAssertEqual(p.position.fraction,0.5,accuracy:1e-8)
        XCTAssertEqual(p.point,[103,-1.2,0]);XCTAssertEqual(p.distance_m,0.4,accuracy:1e-8)
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:r.id,point:[103,1,3]))
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:r.id,point:[.nan,1,0]))
        var disabled = g;disabled.edges[1].enabled = false
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:disabled,regionID:r.id,point:[103,1,0]))
    }
    func testMidEdgeRoomNavigationConvertsStoredSideToTravelDirection() throws {
        var g = try fixture();let e = g.edges[0],r = CampusRoom(name:"102",edgeID:e.id,fraction:0.75,side:.left);g.rooms = [r]
        let planner:any CampusRoutePlanning = CampusOfflinePlanner()
        for (start,cost,side) in [(0.25,2.0,"左侧"),(1.0,1.0,"右侧")] {
            let p = try planner.plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:e.region_id!,edgeID:e.id,fraction:start),destination:CampusDestination(roomID:r.id)))
            XCTAssertEqual(p.path.total_cost_m,cost,accuracy:1e-8);XCTAssertEqual(p.path.node_ids.count,2)
            XCTAssertEqual(p.path.edge_ids,[e.id]);XCTAssertTrue(p.arrival_hint!.contains(side))
            XCTAssertEqual(p.point(nodeID:p.path.node_ids.last!,regionID:e.region_id!)!.map_position,[3,-1.2,0])
            let roundtrip = try JSONDecoder().decode(CampusNavigationPlan.self,from:JSONEncoder().encode(p))
            XCTAssertEqual(roundtrip.path,p.path);XCTAssertEqual(roundtrip.points,p.points)
        }
        XCTAssertEqual(g.nodes.count,5);XCTAssertEqual(g.bindings.count,6) // Rooms never add stored AR anchors.
    }
    func testOneWayMidEdgeRouteCannotGoBackwards() throws {
        var g = try fixture();g.edges[0].bidirectional = false;let e = g.edges[0]
        let r = CampusRoom(name:"102",edgeID:e.id,fraction:0.5,side:.right);g.rooms = [r]
        let planner = CampusOfflinePlanner()
        XCTAssertThrowsError(try planner.plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:e.region_id!,edgeID:e.id,fraction:0.75),destination:CampusDestination(roomID:r.id))))
        let p = try planner.plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:e.region_id!,edgeID:e.id,fraction:0.25),destination:CampusDestination(roomID:r.id)))
        XCTAssertEqual(p.path.total_cost_m,1,accuracy:1e-8)
    }
    func testRoomAtJunctionDoesNotGuessSideWhenApproachedFromAnotherBranch() throws {
        var g = try fixture();let target = g.edges[0],rid = target.region_id!
        let entry = CampusNode(floorID:g.floors[0].id,name:"支路",kind:.waypoint)
        g.nodes.append(entry);g.bindings.append(CampusBinding(regionID:rid,nodeID:entry.id,anchorID:UUID().uuidString,transform:matrix(-1,2)))
        try g.connect(entry.id,target.from,regionID:rid)
        let approach = g.edges.last!,room = CampusRoom(name:"岔口房间",edgeID:target.id,fraction:0,side:.left)
        g.rooms = [room]
        let plan = try CampusOfflinePlanner().plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:rid,edgeID:approach.id,fraction:0.5),destination:CampusDestination(roomID:room.id)))
        XCTAssertEqual(plan.path.legs.last?.edge_ids.last,approach.id)
        XCTAssertTrue(plan.arrival_hint!.contains(room.name));XCTAssertTrue(plan.arrival_hint!.contains("核对门牌"))
        XCTAssertFalse(plan.arrival_hint!.contains("左侧"));XCTAssertFalse(plan.arrival_hint!.contains("右侧"))
    }
    func testRoomAndStartAtSameLocationHaveAnEmptyRoute() throws {
        var g = try fixture();let e = g.edges[0],r = CampusRoom(name:"102",edgeID:e.id,fraction:0.5,side:.left);g.rooms = [r]
        let p = try CampusOfflinePlanner().plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:e.region_id!,edgeID:e.id,fraction:0.5),destination:CampusDestination(roomID:r.id)))
        XCTAssertEqual(p.path.total_cost_m,0);XCTAssertTrue(p.path.legs.isEmpty)
        XCTAssertEqual(p.points.count,1);XCTAssertEqual(p.destination.id,r.id)
    }
    func testRouteFromCurrentPositionAcrossIndependentRegionsAndStairs() throws {
        var g = try fixture();let e = g.edges[0],target = g.edges[3]
        let r = CampusRoom(name:"202",edgeID:target.id,fraction:0.5,side:.right);g.rooms = [r]
        let p = try CampusOfflinePlanner().plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:e.region_id!,edgeID:e.id,fraction:0.5),destination:CampusDestination(roomID:r.id)))
        XCTAssertEqual(p.path.total_cost_m,17.5,accuracy:1e-8)
        XCTAssertEqual(p.path.legs.map(\.kind),[.walk,.walk,.stairs,.walk])
        XCTAssertEqual(p.point(nodeID:g.nodes[1].id,regionID:g.regions[0].id)!.map_position[0],4)
        XCTAssertEqual(p.point(nodeID:g.nodes[1].id,regionID:g.regions[1].id)!.map_position[0],100)
        XCTAssertTrue(p.arrival_hint!.contains("右侧"))
    }
    func testUnsavedRegionCannotProduceEvenAZeroLengthCurrentPositionRoute() throws {
        var g = try fixture();let e = g.edges[0];g.regions[0].map_saved = false
        let r = CampusRoom(name:"102",edgeID:e.id,fraction:0.5,side:.left);g.rooms = [r]
        XCTAssertThrowsError(try CampusOfflinePlanner().plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:e.region_id!,edgeID:e.id,fraction:0.5),destination:CampusDestination(roomID:r.id))))
    }
    func testFarFromNetworkCanPlanBackWithoutChangingRoomPlacementTolerance() throws {
        let g = try fixture(),rid = g.regions[0].id
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:rid,point:[2,0,8]))
        let location = try CampusPositionLocator.locate(graph:g,regionID:rid,point:[2,0,8],maxDistance:nil)
        XCTAssertEqual(location.distance_m,8,accuracy:1e-8)
        XCTAssertEqual(location.position.fraction,0.5,accuracy:1e-8)
        XCTAssertEqual(location.point,[2,-1.2,0])
        let plan = try CampusOfflinePlanner().plan(.init(graph:g,start:location.position,destination:.init(nodeID:g.nodes[4].id)))
        XCTAssertEqual(plan.path.total_cost_m,19,accuracy:1e-8)
        // Graph route excludes the unmapped approach; the client must guide back before advancing.
        XCTAssertGreaterThan(location.distance_m,CampusRouteAccess.joinRadius)
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:rid,point:[.nan,0,0],maxDistance:nil))
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:rid,point:[2,0,8],maxDistance:-1))
    }
    func testNearestBranchChangeReplansAndHysteresisRejectsTinyDistanceChanges() throws {
        var g = try fixture();let rid = g.regions[0].id
        let joint = g.bindings.firstIndex { $0.region_id == rid && $0.node_id == g.nodes[1].id }!
        g.bindings[joint].anchor_to_map = matrix(40);g.edges[0].length_m = 40;g.edges[0].cost_m = 40
        let a = CampusNode(floorID:g.floors[0].id,name:"另一走廊起点",kind:.waypoint),b = CampusNode(floorID:g.floors[0].id,name:"另一走廊终点",kind:.waypoint)
        g.nodes += [a,b]
        g.bindings += [CampusBinding(regionID:rid,nodeID:a.id,anchorID:UUID().uuidString,transform:matrix(0,8)),CampusBinding(regionID:rid,nodeID:b.id,anchorID:UUID().uuidString,transform:matrix(40,8))]
        try g.connect(a.id,b.id,regionID:rid);try g.connect(b.id,g.nodes[1].id,regionID:rid)
        let original = g.edges[0].id,other = g.edges[g.edges.count-2].id
        let tied = try CampusPositionLocator.locate(graph:g,regionID:rid,point:[2,0,4.05],previousEdgeID:original,maxDistance:nil)
        XCTAssertEqual(tied.position.edge_id,original)
        let changed = try CampusPositionLocator.locate(graph:g,regionID:rid,point:[2,0,7.5],previousEdgeID:original,maxDistance:nil)
        XCTAssertEqual(changed.position.edge_id,other)
        let destination = CampusDestination(nodeID:g.nodes[0].id)
        let first = try CampusOfflinePlanner().plan(.init(graph:g,start:tied.position,destination:destination))
        let second = try CampusOfflinePlanner().plan(.init(graph:g,start:changed.position,destination:destination))
        XCTAssertEqual(first.path.edge_ids.first,original);XCTAssertEqual(second.path.edge_ids.first,other)
        XCTAssertGreaterThan(second.path.total_cost_m,first.path.total_cost_m)
    }
    func testUnboundedDistanceStillRespectsStartHintAndDoesNotInventNetworkEdges() throws {
        let g = try fixture(),rid = g.regions[0].id,eid = g.edges[0].id
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:rid,point:[3,0,10],maxDistance:nil,allowedRanges:[eid:[0...0.25]]))
        var empty = g;empty.edges[0].enabled = false
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:empty,regionID:rid,point:[2,0,10],maxDistance:nil))
        let goal = try CampusPositionLocator.locate(graph:g,regionID:rid,point:[4,0,10],maxDistance:nil)
        let plan = try CampusOfflinePlanner().plan(.init(graph:g,start:goal.position,destination:.init(nodeID:g.nodes[1].id)))
        XCTAssertTrue(plan.path.legs.isEmpty)
        XCTAssertGreaterThan(goal.distance_m,CampusRouteAccess.transferRadius) // Not physically at the destination.
    }
    func testRoomsValidateAndAreRemovedWithTheirConnection() throws {
        var g = try fixture(),r = CampusRoom(name:"102",edgeID:g.edges[0].id,fraction:0.5,side:.left)
        g.rooms = [r];try g.validate();g.removeNode(g.nodes[0].id);XCTAssertTrue(g.rooms.isEmpty)
        g = try fixture();r.fraction = 1.01;g.rooms = [r];XCTAssertThrowsError(try g.validate())
        r.fraction = 0.5;r.edge_id = g.edges[2].id;g.rooms = [r];XCTAssertThrowsError(try g.validate())
        r.edge_id = g.edges[0].id;r.id = g.nodes[0].id;g.rooms = [r];XCTAssertThrowsError(try g.validate())
    }
    func testOldGraphWithoutRoomsDecodesAndUpgradesWithoutLosingBindings() throws {
        let old = try fixture()
        var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        object["schema_version"] = 1;object.removeValue(forKey:"rooms")
        let restored = try JSONDecoder().decode(CampusGraph.self,from:JSONSerialization.data(withJSONObject:object))
        try restored.validate();XCTAssertTrue(restored.rooms.isEmpty);XCTAssertEqual(restored.bindings,old.bindings)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root),saved = try l.save(restored)
        XCTAssertEqual(saved.schema_version,3);XCTAssertEqual(saved.bindings,old.bindings)
    }
    func testRoomBackupAndJSONImportsKeepOriginalAndFilterSingleRegion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) };try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        var graph = try fixture();graph.rooms = [CampusRoom(name:"102",edgeID:graph.edges[0].id,fraction:0.5,side:.left),CampusRoom(name:"202",edgeID:graph.edges[3].id,fraction:0.25,side:.right)]
        let (l,g) = try package(graph,base:base),zip = base.appendingPathComponent("region.zip")
        try l.export(g.building_id,destination:zip,regionID:g.regions[0].id)
        let single = try l.importBackup(zip);XCTAssertEqual(single.rooms,[g.rooms[0]])
        let json = base.appendingPathComponent("graph.json");try CampusFiles.encode(g,to:json)
        let imported = try l.importGraph(json);XCTAssertNotEqual(imported.building_id,g.building_id)
        XCTAssertEqual(imported.rooms,g.rooms);XCTAssertEqual(imported.bindings,g.bindings)
        XCTAssertEqual(try l.load(g.building_id),g)
        XCTAssertFalse(FileManager.default.fileExists(atPath:try l.regionDirectory(buildingID:imported.building_id,regionID:g.regions[0].id).appendingPathComponent("environment.arworldmap").path))
        XCTAssertThrowsError(try l.export(imported.building_id,destination:base.appendingPathComponent("missing.zip")))
    }

    func testStartScopeUsesWalkDistancesAcrossMapsWithoutCrossingStairs() throws {
        let g = try fixture()
        let scope = try CampusLocalizationScope.make(graph:g,start:.place(CampusDestination(nodeID:g.nodes[0].id)),maxWalkDistance:7)
        XCTAssertEqual(scope.regionIDs,Set(g.regions.prefix(2).map(\.id)))
        XCTAssertNil(scope.edgeRanges[g.edges[2].id]);XCTAssertNil(scope.edgeRanges[g.edges[3].id])
        // The west map's origin is x=100, but only 4m of walking separates it from the start.
        XCTAssertTrue(scope.edgeRanges[g.edges[1].id]!.contains { $0.contains(0.5) })
        XCTAssertFalse(scope.edgeRanges[g.edges[1].id]!.contains { $0.contains(0.51) })
        XCTAssertNoThrow(try CampusPositionLocator.locate(graph:g,regionID:g.regions[1].id,point:[102,0,0],allowedRanges:scope.edgeRanges))
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:g.regions[1].id,point:[105,0,0],allowedRanges:scope.edgeRanges))
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:g.regions[2].id,point:[1,0,0],allowedRanges:scope.edgeRanges))
    }
    func testRoomStartInMiddleOfLongEdgeRestrictsFractionsWithoutReachingEndpoints() throws {
        var g = try fixture()
        let endpoint = g.bindings.firstIndex { $0.region_id == g.regions[0].id && $0.node_id == g.nodes[1].id }!
        g.bindings[endpoint].anchor_to_map = matrix(200);g.edges[0].length_m = 200;g.edges[0].cost_m = 200
        let room = CampusRoom(name:"走廊中间房间",edgeID:g.edges[0].id,fraction:0.5,side:.right);g.rooms = [room]
        let scope = try CampusLocalizationScope.make(graph:g,start:.place(CampusDestination(roomID:room.id)))
        XCTAssertEqual(scope.regionIDs,[g.regions[0].id])
        XCTAssertEqual(scope.edgeRanges[g.edges[0].id],[0.4...0.6])
        XCTAssertNoThrow(try CampusPositionLocator.locate(graph:g,regionID:g.regions[0].id,point:[115,0,0],allowedRanges:scope.edgeRanges))
        XCTAssertThrowsError(try CampusPositionLocator.locate(graph:g,regionID:g.regions[0].id,point:[20,0,0],allowedRanges:scope.edgeRanges))
    }
    func testKnownRegionScopeIncludesItsEdgesAndOnlyConnectedNeighbors() throws {
        var g = try fixture()
        let disconnected = CampusRegion(floorID:g.floors[0].id,name:"独立区域")
        var saved = disconnected;saved.map_saved = true;g.regions.append(saved)
        let a = CampusNode(floorID:g.floors[0].id,name:"独立一",kind:.waypoint),b = CampusNode(floorID:g.floors[0].id,name:"独立二",kind:.waypoint)
        g.nodes += [a,b]
        g.bindings += [CampusBinding(regionID:saved.id,nodeID:a.id,anchorID:UUID().uuidString,transform:matrix(0)),CampusBinding(regionID:saved.id,nodeID:b.id,anchorID:UUID().uuidString,transform:matrix(2))]
        try g.connect(a.id,b.id,regionID:saved.id)
        let scope = try CampusLocalizationScope.make(graph:g,start:.region(g.regions[0].id),maxWalkDistance:2)
        XCTAssertEqual(scope.regionIDs,Set(g.regions.prefix(2).map(\.id)))
        XCTAssertTrue(scope.edgeRanges[g.edges[0].id]!.contains { $0.contains(1) })
        XCTAssertTrue(scope.edgeRanges[g.edges[1].id]!.contains { $0.contains(0.3) })
        XCTAssertFalse(scope.edgeRanges[g.edges[1].id]!.contains { $0.contains(0.4) })
        XCTAssertNil(scope.edgeRanges[g.edges.last!.id])
    }
    func testUnknownStartSearchesAllSavedWalkRegionsAndExcludesUnusableEdges() throws {
        var g = try fixture()
        let all = try CampusLocalizationScope.make(graph:g,start:.unknown)
        XCTAssertEqual(all.regionIDs,Set(g.regions.map(\.id)));XCTAssertEqual(all.edgeRanges.count,3)
        g.edges[0].enabled = false;g.regions[2].map_saved = false
        let scope = try CampusLocalizationScope.make(graph:g,start:.unknown)
        XCTAssertEqual(scope.regionIDs,[g.regions[1].id]);XCTAssertEqual(scope.edgeRanges.count,1)
        XCTAssertThrowsError(try CampusLocalizationScope.make(graph:g,start:.place(CampusDestination(nodeID:g.nodes[0].id))))
        XCTAssertThrowsError(try CampusLocalizationScope.make(graph:g,start:.region(g.regions[2].id)))
        XCTAssertThrowsError(try CampusLocalizationScope.make(graph:g,start:.place(CampusDestination(nodeID:"missing"))))
        XCTAssertThrowsError(try CampusLocalizationScope.make(graph:g,start:.unknown,maxWalkDistance:.nan))
    }
    func testNearbyWaypointConfirmationUsesRelaxedSixMeterRadius() {
        for distance in [0.0,2,5.9,6] { XCTAssertTrue(CampusNavigationProgress.canConfirm(horizontalDistance:distance)) }
        for distance in [-1.0,6.01,.infinity,.nan] { XCTAssertFalse(CampusNavigationProgress.canConfirm(horizontalDistance:distance)) }
    }
    func testLegacyRoomSideValuesKeepPositionsAndDecodeAsFixedColors() throws {
        let yellow = try JSONDecoder().decode(CampusRoom.Side.self,from:Data("\"left\"".utf8))
        let blue = try JSONDecoder().decode(CampusRoom.Side.self,from:Data("\"right\"".utf8))
        XCTAssertEqual(yellow.title,"黄侧");XCTAssertEqual(blue.title,"蓝侧")
        XCTAssertEqual(String(data:try JSONEncoder().encode(yellow),encoding:.utf8),"\"left\"")
        XCTAssertEqual(String(data:try JSONEncoder().encode(blue),encoding:.utf8),"\"right\"")
    }
    func testExplicitEnvironmentDoesNotExpandToOtherMapsAndNodeIsOptional() throws {
        let g = try fixture(),rid = g.regions[0].id
        let unrestricted = try CampusLocalizationScope.make(graph:g,start:.environment(regionID:rid,nodeID:nil))
        XCTAssertEqual(unrestricted.regionIDs,[rid]);XCTAssertEqual(unrestricted.edgeRanges.count,1)
        let start = CampusStartSelection.environment(regionID:rid,nodeID:g.nodes[1].id)
        XCTAssertEqual(start.directRegionID,rid);XCTAssertEqual(start.nearbyNodeID,g.nodes[1].id)
        let nearby = try CampusLocalizationScope.make(graph:g,start:start,maxWalkDistance:2)
        XCTAssertEqual(nearby.regionIDs,[rid]);XCTAssertNil(nearby.edgeRanges[g.edges[1].id])
        XCTAssertTrue(nearby.edgeRanges[g.edges[0].id]!.contains { $0.contains(0.75) })
        XCTAssertFalse(nearby.edgeRanges[g.edges[0].id]!.contains { $0.contains(0.25) })
        XCTAssertThrowsError(try CampusLocalizationScope.make(graph:g,start:.environment(regionID:rid,nodeID:g.nodes[3].id)))
    }
    func testUnknownEnvironmentCanBeRestrictedToOneFloor() throws {
        let g = try fixture(),start = CampusStartSelection.floor(g.floors[1].id)
        let scope = try CampusLocalizationScope.make(graph:g,start:start)
        XCTAssertNil(start.directRegionID);XCTAssertEqual(scope.regionIDs,[g.regions[2].id])
        XCTAssertEqual(scope.edgeRanges.count,1)
        XCTAssertThrowsError(try CampusLocalizationScope.make(graph:g,start:.floor("missing")))
    }
    func testRecoveryGuideIsRelativeToExistingNodeAndRejectsInvalidPose() throws {
        let g = try fixture(),node = g.nodes[0].id
        var guide = CampusRecoveryGuide(nodeID:node,name:"门框",lighting:.daylight,cameraRelativeToNode:matrix(1))
        try guide.validate(nodeIDs:[node])
        XCTAssertEqual(try JSONDecoder().decode(CampusRecoveryGuide.self,from:JSONEncoder().encode(guide)),guide)
        XCTAssertThrowsError(try guide.validate(nodeIDs:[]))
        guide.camera_relative_to_node[0][0] = 2;XCTAssertThrowsError(try guide.validate(nodeIDs:[node]))
    }
    func testBackupBeforeSupplementKeepsOldEnvironmentAndBindingsAfterUpdating() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) };try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let (l,old) = try package(fixture(),base:base),rid = old.regions[0].id,backup = base.appendingPathComponent("before.zip")
        try l.export(old.building_id,destination:backup,regionID:rid)
        let previousDirectory = try l.directory(old.building_id)
        var changed = old;changed.name = "补采后";let updated = try l.save(changed)
        XCTAssertNotEqual(try l.directory(old.building_id),previousDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath:try l.regionDirectory(buildingID:old.building_id,regionID:rid).appendingPathComponent("environment.arworldmap").path))
        let restored = try l.importBackup(backup)
        XCTAssertEqual(restored.regions,[old.regions[0]]);XCTAssertEqual(restored.bindings,old.bindings.filter { $0.region_id == rid })
        XCTAssertEqual(try l.load(updated.building_id),updated)
    }
    func testSupplementGuidesSurviveFullAndRegionBackupsWithoutChangingOldVersion() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) };try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let (library,old) = try package(fixture(),base:base),rid = old.regions[0].id
        let oldRegion = try library.regionDirectory(buildingID:old.building_id,regionID:rid)
        let source = base.appendingPathComponent("supplement")
        try FileManager.default.copyItem(at:oldRegion,to:source)
        let guides = source.appendingPathComponent("guides")
        try FileManager.default.createDirectory(at:guides,withIntermediateDirectories:true)
        let guide = CampusRecoveryGuide(nodeID:old.nodes[0].id,name:"白天门框",lighting:.daylight,cameraRelativeToNode:matrix(1))
        try CampusFiles.encode(guide,to:guides.appendingPathComponent(guide.id+".json"))
        let image = Data("synthetic-guide-jpeg".utf8)
        try image.write(to:guides.appendingPathComponent(guide.id+".jpg"));try CampusFiles.manifest(source)
        let updated = try library.save(old,regionSource:source,regionID:rid)
        XCTAssertFalse(FileManager.default.fileExists(atPath:oldRegion.appendingPathComponent("guides").path))
        for regionID in [nil,Optional(rid)] {
            let zip = base.appendingPathComponent(regionID == nil ? "full.zip" : "region.zip")
            try library.export(updated.building_id,destination:zip,regionID:regionID)
            let restored = try library.importBackup(zip)
            let dir = try library.regionDirectory(buildingID:restored.building_id,regionID:rid).appendingPathComponent("guides")
            XCTAssertEqual(try JSONDecoder().decode(CampusRecoveryGuide.self,from:Data(contentsOf:dir.appendingPathComponent(guide.id+".json"))),guide)
            XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent(guide.id+".jpg")),image)
        }
        XCTAssertEqual(try library.load(updated.building_id),updated)
    }

}
