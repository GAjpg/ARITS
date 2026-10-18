import XCTest
@testable import ProbeCore

final class LiDARSupplementTests:XCTestCase {
    private let identity:[[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    private func obs(_ p:ProbePoint,depth:Double = 2,confidence:Int = 2) -> LiDARDepthObservation {
        LiDARDepthObservation(point:p,depth:depth,confidence:UInt8(confidence))
    }
    private func floor(_ x0:Double,_ x1:Double) -> [ProbePoint] {
        (0..<Int((x1-x0)*10+0.5)).flatMap { i in (0..<20).map { k in ProbePoint(x0+Double(i)*0.1+0.05,-1.5,Double(k)*0.1+0.05) } }
    }
    func testSeededMapSurvivesRollbackAndCountsTowardQuotas() throws {
        let budget = LiDARBlockBudget(settings:.init(globalCap:LiDARScanLimits.mapVoxelsV3))
        let old = floor(0,2)
        try budget.seed(old)
        XCTAssertEqual(budget.count,old.count);XCTAssertEqual(budget.seededCount,old.count)
        XCTAssertEqual(budget.floorY!,-1.5,accuracy:0.01)
        XCTAssertThrowsError(try budget.seed(old))
        // Re-observing the old area adds nothing new; a fresh area does.
        XCTAssertEqual(budget.preview(old.map { obs($0) }).novel,0)
        let commit = budget.commit(floor(4,6).map { obs($0) })
        XCTAssertEqual(commit.added,floor(4,6).count)
        budget.rollback(toBatch:0)
        XCTAssertEqual(budget.count,old.count)
        XCTAssertEqual(Set(budget.points.map { LiDARVoxelKey($0,size:0.1) }),Set(old.map { LiDARVoxelKey($0,size:0.1) }))
    }
    func testBetterObservationReplacesSeedAndRollbackRestoresIt() throws {
        let budget = LiDARBlockBudget()
        let p = ProbePoint(0.05,-1.45,0.05)
        try budget.seed(floor(0,2)+[p])
        let moved = ProbePoint(0.06,-1.45,0.06)
        budget.commit([obs(moved)])
        XCTAssertTrue(budget.points.contains(moved))
        budget.rollback(toBatch:0)
        XCTAssertFalse(budget.points.contains(moved))
    }
    func testLargeGeometryFileAndRouteLimits() throws {
        let points = (0..<120_000).map { ProbePoint(Double($0%400)*0.1,-1.5,Double($0/400)*0.1) }
        let data = try LiDARPointFile.encode(points)
        XCTAssertEqual(try LiDARPointFile.decode(data,count:points.count).count,points.count)
        XCTAssertThrowsError(try LiDARPointFile.encode(Array(repeating:ProbePoint(0,0,0),count:LiDARScanLimits.mapVoxelsV3+1)))
        var editor = LiDARRouteEditor()
        for i in 0..<300 { try editor.addNode(name:"P\(i)",position:ProbePoint(Double(i),-1.5,0)) }
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"长走廊",pointCount:120_000,voxel:0.1)
        try map.validate()
        XCTAssertEqual(map.nodes.count,300)
    }
    func testSupplementManifestAndSourcesValidate() throws {
        var m = LiDARScanManifest(role:.map,label:"补采",buildingID:"b",regionID:"r",regionName:"n",lighting:"day",hardware:"h",appVersion:"1")
        m.schema_version = 2
        m.supplement_of_map_id = UUID().uuidString
        XCTAssertThrowsError(try m.validate())                     // transform missing
        let turn:[[Double]] = [[0,0,1,3],[0,1,0,0],[-1,0,0,2],[0,0,0,1]]
        m.map_from_session = turn;try m.validate()
        m.map_from_session = [[2,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]];XCTAssertThrowsError(try m.validate())
        var map = LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"m",pointCount:500,
            nodes:[LiDARRouteNode(name:"A",position:ProbePoint(0,0,0),id:"a"),LiDARRouteNode(name:"B",position:ProbePoint(1,0,0),id:"b")],
            edges:[LiDARRouteEdge("a","b")])
        let first = LiDARMapSource(kind:LiDARMapSource.initial,scanID:UUID().uuidString,sessionID:map.session_id,mapFromSession:identity,confirmation:"identity",acceptedFrames:100)
        let more = LiDARMapSource(kind:LiDARMapSource.supplement,scanID:UUID().uuidString,sessionID:UUID().uuidString,mapFromSession:turn,acceptedFrames:80)
        map.sources = [first,more]
        XCTAssertTrue(first.valid);XCTAssertTrue(more.valid);try map.validate()
        let decoded = try JSONDecoder().decode(LiDARNavigationMap.self,from:JSONEncoder().encode(map))
        XCTAssertEqual(decoded.sources,map.sources)
        map.sources = [first,first];XCTAssertThrowsError(try map.validate())
        map.sources = [more,first];XCTAssertThrowsError(try map.validate())
        map.sources = nil;try map.validate()
    }
    private func publish(_ dir:URL,mapID:String,nodes:Int,points:Int) throws {
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var editor = LiDARRouteEditor()
        for i in 0..<nodes { try editor.addNode(name:"N\(i)",position:ProbePoint(Double(i),-1.5,0)) }
        let pts = (0..<points).map { ProbePoint(Double($0)*0.01,-1.5,0) }
        let map = editor.map(mapID:mapID,sessionID:UUID().uuidString,name:"会议中心",pointCount:pts.count,voxel:0.1)
        try LiDARPointFile.encode(pts).write(to:dir.appendingPathComponent("geometry.f32"))
        try LiDARNavigationArchive.write(map,to:dir.appendingPathComponent("navigation.json"))
    }
    func testSnapshotRestorePruneAndEvidenceCopy() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let dir = temp.appendingPathComponent("map"),id = UUID().uuidString
        try publish(dir,mapID:id,nodes:2,points:200)
        try Data("placement".utf8).write(to:dir.appendingPathComponent(LiDARMapPlacement.fileName))
        let plate = UUID().uuidString
        try FileManager.default.createDirectory(at:dir.appendingPathComponent("landmarks/\(plate)"),withIntermediateDirectories:true)
        try Data([1]).write(to:dir.appendingPathComponent("landmarks/\(plate)/crop.jpg"))
        let v1 = try LiDARMapVersions.snapshot(dir)
        // A supplement save: more nodes and points, a new sidecar, the old plate removed.
        try publish(dir,mapID:id,nodes:5,points:900)
        try Data("{}".utf8).write(to:dir.appendingPathComponent("magnetic-reference.json"))
        try FileManager.default.removeItem(at:dir.appendingPathComponent("landmarks/\(plate)"))
        XCTAssertEqual(LiDARMapVersions.list(dir).map(\.id),[v1])
        let backup = try LiDARMapVersions.restore(dir,id:v1)
        let (restored,points) = try LiDARNavigationArchive.load(dir)
        XCTAssertEqual(restored.nodes.count,2);XCTAssertEqual(points.count,200)
        XCTAssertFalse(FileManager.default.fileExists(atPath:dir.appendingPathComponent("magnetic-reference.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:dir.appendingPathComponent("landmarks/\(plate)/crop.jpg").path))
        XCTAssertEqual(try String(contentsOf:dir.appendingPathComponent(LiDARMapPlacement.fileName),encoding:.utf8),"placement")
        XCTAssertEqual(LiDARMapVersions.list(dir).first?.id,backup)          // the restore itself is undoable
        XCTAssertEqual(LiDARMapVersions.list(dir).first?.nodes,5)
        for _ in 0..<3 { try LiDARMapVersions.snapshot(dir) }
        try LiDARMapVersions.prune(dir,keep:3)
        XCTAssertEqual(LiDARMapVersions.list(dir).count,3)
        XCTAssertThrowsError(try LiDARMapVersions.restore(dir,id:"../x"))
        // Supplement evidence is copied in; an existing id is not overwritten.
        let scan = temp.appendingPathComponent("scan"),fresh = UUID().uuidString
        for p in [fresh,plate] {
            try FileManager.default.createDirectory(at:scan.appendingPathComponent("landmarks/\(p)"),withIntermediateDirectories:true)
            try Data([9]).write(to:scan.appendingPathComponent("landmarks/\(p)/crop.jpg"))
        }
        XCTAssertEqual(try LiDARMapVersions.copyEvidence(from:scan,to:dir,ids:[fresh,plate]),[fresh])
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("landmarks/\(plate)/crop.jpg")),Data([1]))
    }
}

final class LiDARMapPublishTests:XCTestCase {
    private func write(_ dir:URL,mapID:String,nodes:Int,points:Int) throws {
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        var editor = LiDARRouteEditor()
        for i in 0..<nodes { try editor.addNode(name:"N\(i)",position:ProbePoint(Double(i),-1.5,0)) }
        let pts = (0..<points).map { ProbePoint(Double($0)*0.01,-1.5,0) }
        try LiDARPointFile.encode(pts).write(to:dir.appendingPathComponent("geometry.f32"))
        try LiDARNavigationArchive.write(editor.map(mapID:mapID,sessionID:UUID().uuidString,name:"m",pointCount:points,voxel:0.1),to:dir.appendingPathComponent("navigation.json"))
    }
    func testStagedPublishSwapsAndBrokenMapRecovers() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let dir = temp.appendingPathComponent("map"),id = UUID().uuidString
        try write(dir,mapID:id,nodes:2,points:200)
        let stage = temp.appendingPathComponent("stage");try write(stage,mapID:id,nodes:4,points:700)
        let backup = try LiDARMapVersions.publish(dir,staged:stage)
        XCTAssertEqual(try LiDARNavigationArchive.load(dir).0.nodes.count,4)
        XCTAssertEqual(LiDARMapVersions.list(dir).first?.id,backup)
        // Another map's data is refused and the published map is untouched.
        let foreign = temp.appendingPathComponent("foreign");try write(foreign,mapID:UUID().uuidString,nodes:3,points:300)
        XCTAssertThrowsError(try LiDARMapVersions.publish(dir,staged:foreign))
        XCTAssertEqual(try LiDARNavigationArchive.load(dir).1.count,700)
        // Simulate a crash between geometry and navigation.json: the folder no longer loads.
        try LiDARPointFile.encode((0..<50).map { ProbePoint(Double($0),0,0) }).write(to:dir.appendingPathComponent("geometry.f32"))
        XCTAssertThrowsError(try LiDARNavigationArchive.load(dir))
        XCTAssertEqual(LiDARMapVersions.recoverIfBroken(dir),backup)
        XCTAssertEqual(try LiDARNavigationArchive.load(dir).0.nodes.count,2)
        XCTAssertNil(LiDARMapVersions.recoverIfBroken(dir))
    }
    func testInterruptedSwapWithSameSizeGeometryIsRolledBack() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let dir = temp.appendingPathComponent("map"),id = UUID().uuidString
        try write(dir,mapID:id,nodes:2,points:200)
        let original = try Data(contentsOf:dir.appendingPathComponent("geometry.f32"))
        // Simulate a crash inside publish: snapshot taken, marker written, geometry swapped (same size), route not yet.
        let backup = try LiDARMapVersions.snapshot(dir)
        try Data("{\"backup_id\":\"\(backup)\",\"operation\":\"publish\",\"started_utc\":\"x\"}".utf8).write(to:dir.appendingPathComponent(LiDARMapVersions.transactionFile))
        try LiDARPointFile.encode((0..<200).map { ProbePoint(100+Double($0)*0.01,-1.5,0) }).write(to:dir.appendingPathComponent("geometry.f32"))
        XCTAssertThrowsError(try LiDARNavigationArchive.load(dir))                // a pending transaction is never opened
        XCTAssertEqual(LiDARMapVersions.recoverIfBroken(dir),backup)
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("geometry.f32")),original)
        XCTAssertFalse(LiDARMapVersions.hasOpenTransaction(dir))
        // A completed publish leaves no marker.
        let stage = temp.appendingPathComponent("stage");try write(stage,mapID:id,nodes:3,points:300)
        try LiDARMapVersions.publish(dir,staged:stage);XCTAssertFalse(LiDARMapVersions.hasOpenTransaction(dir))
        XCTAssertNil(LiDARMapVersions.recoverIfBroken(dir))
    }
    func testFailedRecoveryKeepsTheMapClosedAndTheEvidence() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let dir = temp.appendingPathComponent("map"),id = UUID().uuidString
        try write(dir,mapID:id,nodes:2,points:200)
        // Marker names a backup that does not exist (deleted, or the disk filled before it was written).
        let marker = Data("{\"backup_id\":\"missing\",\"operation\":\"publish\",\"started_utc\":\"x\"}".utf8)
        try marker.write(to:dir.appendingPathComponent(LiDARMapVersions.transactionFile))
        XCTAssertNil(LiDARMapVersions.recoverIfBroken(dir))
        XCTAssertThrowsError(try LiDARNavigationArchive.load(dir))                    // not opened for navigation or supplement
        let stage = temp.appendingPathComponent("stage");try write(stage,mapID:id,nodes:3,points:300)
        XCTAssertThrowsError(try LiDARMapVersions.publish(dir,staged:stage))         // no new publish over it
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent(LiDARMapVersions.transactionFile)),marker)   // evidence untouched
        // A damaged marker behaves the same.
        try Data("garbage".utf8).write(to:dir.appendingPathComponent(LiDARMapVersions.transactionFile))
        XCTAssertNil(LiDARMapVersions.recoverIfBroken(dir));XCTAssertThrowsError(try LiDARNavigationArchive.load(dir))
    }
}
