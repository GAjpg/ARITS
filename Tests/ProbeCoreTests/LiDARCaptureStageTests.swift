import XCTest
@testable import ProbeCore

final class LiDARCaptureStageTests: XCTestCase {
    private let identity: [[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    private func pose(x: Double = 0, z: Double = 0, pitchDeg: Double = 0) -> [[Double]] {
        let r = pitchDeg*Double.pi/180,c = cos(r),s = sin(r)
        return [[1,0,0,x],[0,c,-s,0],[0,s,c,z],[0,0,0,1]]
    }
    private func wall(x0: Double, x1: Double, z: Double, depth: Double = 2, confidence: UInt8 = 2) -> [LiDARDepthObservation] {
        var o = [LiDARDepthObservation]()
        for x in stride(from:x0,through:x1,by:0.05) { for y in stride(from:-1.0,through:1.0,by:0.05) {
            o.append(LiDARDepthObservation(point:ProbePoint(x,y,z),depth:depth,confidence:confidence))
        } }
        return o
    }
    private func floor(x0: Double, x1: Double, z0: Double, z1: Double) -> [LiDARDepthObservation] {
        var o = [LiDARDepthObservation]()
        for x in stride(from:x0,through:x1,by:0.05) { for z in stride(from:z0,through:z1,by:0.05) {
            o.append(LiDARDepthObservation(point:ProbePoint(x,-1.5,z),depth:2,confidence:2))
        } }
        return o
    }

    // MARK: navigation v2

    func testVersionOneMapLoadsWithStableDerivedEdgeIDs() throws {
        let a = UUID().uuidString,b = UUID().uuidString,c = UUID().uuidString
        let json = """
        {"schema_version":1,"kind":"lidar_navigation_map","map_id":"\(UUID().uuidString)","session_id":"\(UUID().uuidString)",
         "name":"旧图","coordinate_system":"ARKit_Y_up_camera_minus_Z_row_major_meters","created_utc":"2026-10-16T00:00:00Z",
         "initial_world_map_used":false,"points_file":"geometry.f32","point_count":500,"voxel_m":0.12,
         "nodes":[{"id":"\(a)","name":"西口","position":{"x":0,"y":-1.5,"z":0}},{"id":"\(b)","name":"节点2","position":{"x":3,"y":-1.5,"z":0}},
                  {"id":"\(c)","name":"楼梯口","position":{"x":3,"y":-1.5,"z":3}}],
         "edges":[{"from":"\(a)","to":"\(b)"},{"from":"\(b)","to":"\(c)"}]}
        """
        let first = try JSONDecoder().decode(LiDARNavigationMap.self,from:Data(json.utf8))
        let second = try JSONDecoder().decode(LiDARNavigationMap.self,from:Data(json.utf8))
        XCTAssertEqual(first.schema_version,1);try first.validate()
        XCTAssertEqual(first.edges.map(\.id),second.edges.map(\.id));XCTAssertTrue(first.edges.allSatisfy { $0.id != nil })
        XCTAssertEqual(Set(first.edges.compactMap(\.id)).count,2)
        XCTAssertEqual(first.nodes.map(\.name),["西口","节点2","楼梯口"]);XCTAssertEqual(first.nodes[0].resolvedKind,.waypoint)
        XCTAssertEqual(try first.route(from:ProbePoint(0.5,0,0.2),to:c).last,ProbePoint(3,-1.5,3))
    }
    func testVersionTwoKeepsKindAndCaptureAndRejectsThemInVersionOne() throws {
        var editor = LiDARRouteEditor()
        let context = LiDARNodeCaptureContext(timestamp:12.5,session_id:"s",generation:1,camera_to_session:identity,keyframe_index:4,keyframe_dt_s:0.2)
        try editor.addNode(name:"西口",kind:.junction,position:ProbePoint(0,-1.5,0),capture:context)
        try editor.addNode(name:nil,kind:.stair,position:ProbePoint(4,-1.5,0))
        var map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"新图",pointCount:500,voxel:0.12)
        XCTAssertEqual(map.schema_version,2);try map.validate()
        let decoded = try JSONDecoder().decode(LiDARNavigationMap.self,from:JSONEncoder().encode(map))
        XCTAssertEqual(decoded.nodes[0].capture,context);XCTAssertEqual(decoded.nodes[1].kind,.stair)
        XCTAssertEqual(decoded.edges.map(\.id),map.edges.map(\.id))
        map.schema_version = 1;XCTAssertThrowsError(try map.validate())
    }
    func testDraftMayHaveBranchesButNavigationRequiresOneComponent() throws {
        var editor = LiDARRouteEditor()
        try editor.addNode(name:"A",position:ProbePoint(0,0,0));try editor.addNode(name:"B",position:ProbePoint(2,0,0))
        editor.startNewBranch()
        try editor.addNode(name:"C",position:ProbePoint(0,0,5));try editor.addNode(name:"D",position:ProbePoint(2,0,5))
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"草稿",pointCount:500,voxel:0.12)
        XCTAssertEqual(map.components().count,2)
        XCTAssertNoThrow(try map.validate(requireConnected:false));XCTAssertThrowsError(try map.validate())
        XCTAssertTrue(editor.issues().contains { $0.contains("2 段") })
        try editor.connect(editor.nodes[1].id,editor.nodes[2].id);XCTAssertTrue(editor.issues().isEmpty)
    }

    // MARK: route editor

    func testEditorNamesConnectsAndUndoesWholeCommands() throws {
        var editor = LiDARRouteEditor()
        let a = try editor.addNode(name:"  ",position:ProbePoint(0,0,0))
        let b = try editor.addNode(name:"化学实验室",kind:.room,position:ProbePoint(3,0,0))
        let c = try editor.addNode(name:nil,position:ProbePoint(6,0,0))
        XCTAssertEqual([a.name,b.name,c.name],["节点1","化学实验室","节点2"])
        XCTAssertEqual(editor.edges.count,2);XCTAssertEqual(editor.connectFrom,c.id);XCTAssertTrue(editor.dirty)
        try editor.setConnectFrom(a.id)
        let d = try editor.addNode(name:"楼梯口",kind:.stair,position:ProbePoint(0,0,3))
        XCTAssertTrue(editor.edges.contains { $0.from == a.id && $0.to == d.id })
        XCTAssertThrowsError(try editor.connect(a.id,d.id));XCTAssertThrowsError(try editor.connect(a.id,a.id))
        XCTAssertThrowsError(try editor.rename(b.id,to:" "))
        XCTAssertEqual(editor.undo(),"标点");XCTAssertNil(editor.node(d.id));XCTAssertEqual(editor.connectFrom,a.id)
        XCTAssertEqual(editor.undo(),"切换连线起点");XCTAssertEqual(editor.connectFrom,c.id)
        try editor.removeNode(b.id);XCTAssertTrue(editor.edges.isEmpty);XCTAssertEqual(editor.nodes.count,2)
        editor.undo();XCTAssertEqual(editor.edges.count,2);XCTAssertEqual(editor.node(b.id)?.name,"化学实验室")
        editor.markSaved();XCTAssertFalse(editor.dirty)
    }

    // MARK: scan limits

    func testSchemaTwoMapsAllowMoreFramesWhileQueriesAndLegacyStayCapped() throws {
        XCTAssertEqual(LiDARScanRole.map.frameLimit,100)
        XCTAssertEqual(LiDARScanRole.map.frameLimit(schemaVersion:2),600)
        XCTAssertEqual(LiDARScanRole.query.frameLimit(schemaVersion:2),64)   // relocalization collects 16…64 frames (default 32)
        XCTAssertEqual(LiDARScanRole.query.frameLimit,24)                      // schema 1 queries stay at 24
        var manifest = LiDARScanManifest(role:.map,label:"x",buildingID:"b",regionID:"r",regionName:"n",lighting:"day",hardware:"h",appVersion:"a")
        XCTAssertEqual(manifest.frameLimit,100);manifest.schema_version = 2;XCTAssertEqual(manifest.frameLimit,600)
        try manifest.validate();manifest.schema_version = 3;XCTAssertThrowsError(try manifest.validate())
        let calibration = LiDARCalibration(width:4,height:4,imageWidth:4,imageHeight:4,fx:2,fy:2,cx:2,cy:2)
        XCTAssertNoThrow(try LiDARFrame(index:150,timestamp:1,transform:identity,calibration:calibration,validFraction:1).validate())
    }

    // MARK: block budget

    func testBudgetSeparatesFloorAndStructureQuotasAndReplacesOnlyBetterQuality() {
        var s = LiDARBlockBudget.Settings();s.floor_quota = 50;s.structure_quota = 80
        let budget = LiDARBlockBudget(settings:s)
        budget.commit(floor(x0:0.02,x1:1.98,z0:0.02,z1:1.98)+wall(x0:0.02,x1:1.98,z:1.0))   // floor estimate needs data first
        XCTAssertNotNil(budget.floorY)
        let stats = budget.snapshot().blocks.first { $0.bx == 0 && $0.bz == 0 }!
        XCTAssertLessThanOrEqual(stats.floor_voxels,50);XCTAssertLessThanOrEqual(stats.structure_voxels,80)
        XCTAssertEqual(stats.status,"refusing")
        // Same wall, worse depth: no replacement. Better depth: replaced, count unchanged.
        let before = budget.count
        let farther = budget.commit(wall(x0:0.02,x1:1.98,z:1.0,depth:4.4,confidence:1))
        XCTAssertEqual(farther.replaced,0);XCTAssertEqual(budget.count,before)
        let preview = budget.preview(wall(x0:0.02,x1:1.98,z:1.0,depth:2,confidence:2))
        XCTAssertEqual(preview.novel,0,"a full block offers nothing new");XCTAssertGreaterThan(preview.blocked,0)
    }
    func testRollbackRestoresTheAcceptedStateBeforeAnAnomaly() {
        let budget = LiDARBlockBudget()
        budget.commit(floor(x0:0,x1:3,z0:0,z1:3)+wall(x0:0,x1:3,z:3))
        let checkpoint = budget.batch,saved = budget.snapshot()
        budget.commit(wall(x0:0,x1:3,z:3.25))   // a drifted second copy of the wall
        XCTAssertGreaterThan(budget.count,saved.voxels)
        budget.rollback(toBatch:checkpoint)
        XCTAssertEqual(budget.count,saved.voxels);XCTAssertEqual(budget.snapshot().blocks,saved.blocks)
    }
    func testRuntimePointsKeepEveryBlockWhenThinning() {
        let budget = LiDARBlockBudget()
        budget.commit(floor(x0:0,x1:1.9,z0:0,z1:1.9)+wall(x0:10,x1:10.4,z:10.5))
        let thinned = budget.runtimePoints(limit:600)
        XCTAssertLessThanOrEqual(thinned.count,600)
        XCTAssertTrue(thinned.contains { $0.x > 9 },"the small far block must not be thinned away")
    }

    // MARK: keyframe policy

    func testKeyframePolicyNeedsPacingAndContentOrManual() {
        var policy = LiDARKeyframePolicy()
        let novel = LiDARBudgetPreview(novel:900,improvable:0,total:1000),stale = LiDARBudgetPreview(novel:10,improvable:5,total:1000)
        func input(_ t: Double,_ p: [[Double]],_ preview: LiDARBudgetPreview,manual: Bool = false,tracking: Bool = true) -> LiDARKeyframePolicy.Input {
            LiDARKeyframePolicy.Input(timestamp:t,cameraToSession:p,trackingNormal:tracking,validDepthFraction:0.6,preview:preview,manual:manual)
        }
        XCTAssertEqual(policy.decide(input(0,pose(),novel)).reasons,["first"]);policy.didAccept(timestamp:0,cameraToSession:pose())
        XCTAssertEqual(policy.decide(input(1,pose(x:0.05),novel)).skip_reason,"no_motion")
        XCTAssertEqual(policy.decide(input(1,pose(x:0.5),stale)).skip_reason,"nothing_new")
        XCTAssertEqual(policy.decide(input(0.1,pose(x:0.5),novel)).skip_reason,"too_soon")
        XCTAssertEqual(policy.decide(input(1,pose(x:0.5),novel)).reasons,["moved","novel_surface"])
        let pitched = policy.decide(input(1,pose(pitchDeg:20),novel))
        XCTAssertEqual(pitched.reasons,["rotated","novel_surface"]);XCTAssertEqual(pitched.rotated_deg ?? 0,20,accuracy:1e-6)
        XCTAssertEqual(policy.decide(input(1,pose(),stale,manual:true)).reasons,["manual"])
        XCTAssertEqual(policy.decide(input(1,pose(),novel,manual:true,tracking:false)).skip_reason,"tracking")
    }

    // MARK: revisit check

    func testRevisitFlagsAnOffsetCopyOnlyAfterRepeatedSuspectReports() {
        var s = LiDARBlockBudget.Settings();s.structure_quota = 200
        let budget = LiDARBlockBudget(settings:s)
        budget.commit(floor(x0:0.02,x1:1.98,z0:0.02,z1:1.98)+wall(x0:0.02,x1:1.98,z:1.5))
        XCTAssertEqual(budget.revisitCheck(wall(x0:0.02,x1:1.98,z:1.5)).status,"ok")
        let shifted = budget.revisitCheck(wall(x0:0.02,x1:1.98,z:1.75))
        XCTAssertEqual(shifted.status,"suspect");XCTAssertEqual(shifted.median_m ?? 0,0.25,accuracy:0.06)
        XCTAssertEqual(budget.revisitCheck(wall(x0:20,x1:21,z:20)).status,"unknown")
        var monitor = LiDARRevisitMonitor()
        XCTAssertFalse(monitor.observe(shifted));XCTAssertFalse(monitor.observe(shifted))
        XCTAssertFalse(monitor.observe(LiDARRevisitReport(status:"unknown",checked:0,comparable:0,coverage:0,median_m:nil,p90_m:nil,reason:"x")))
        XCTAssertTrue(monitor.observe(shifted))
    }

    func testStationaryQualityGainIsRateLimitedAndCommitReportsUpdatedPoints() {
        var policy = LiDARKeyframePolicy()
        let better = LiDARBudgetPreview(novel:0,improvable:600,total:1000)
        func input(_ t: Double) -> LiDARKeyframePolicy.Input {
            LiDARKeyframePolicy.Input(timestamp:t,cameraToSession:pose(),trackingNormal:true,validDepthFraction:0.6,preview:better)
        }
        policy.didAccept(timestamp:0,cameraToSession:pose())
        XCTAssertEqual(policy.decide(input(0.5)).skip_reason,"no_motion")
        XCTAssertEqual(policy.decide(input(1.2)).reasons,["quality_gain"])
        let budget = LiDARBlockBudget()
        let first = budget.commit(wall(x0:0,x1:1,z:2,depth:4.4,confidence:1))
        XCTAssertEqual(first.updated_points.count,first.added)
        let second = budget.commit(wall(x0:0,x1:1,z:2,depth:2,confidence:2))
        XCTAssertEqual(second.added,0);XCTAssertEqual(second.updated_points.count,second.replaced);XCTAssertGreaterThan(second.replaced,0)
    }
    func testRuntimePointsNeverExceedTheLimitEvenWithManyBlocks() {
        let budget = LiDARBlockBudget()
        var obs = [LiDARDepthObservation]()
        for bx in 0..<30 { for i in 0..<10 { obs.append(LiDARDepthObservation(point:ProbePoint(Double(bx)*2+Double(i)*0.11,0,0.5),depth:2,confidence:2)) } }
        budget.commit(obs)
        XCTAssertLessThanOrEqual(budget.runtimePoints(limit:20).count,20)
        XCTAssertEqual(budget.runtimePoints(limit:150).count,150)
        let report = budget.revisitCheck(obs)
        XCTAssertEqual(report.metric,"point_to_nearest_voxel_representative");XCTAssertNil(report.normal_support)
    }
    func testLightweightExportKeepsBudgetAndCaptureSidecars() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let source = temp.appendingPathComponent("source");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        var editor = LiDARRouteEditor()
        try editor.addNode(name:"A",position:ProbePoint(0,0,0));try editor.addNode(name:"B",position:ProbePoint(2,0,0))
        let points = (0..<200).map { ProbePoint(Double($0)*0.05,0,0) }
        try LiDARNavigationArchive.write(editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"带统计",pointCount:points.count,voxel:0.12),
                                         to:source.appendingPathComponent("navigation.json"))
        try LiDARPointFile.encode(points).write(to:source.appendingPathComponent("geometry.f32"))
        try LiDARNavigationArchive.write(LiDARBlockBudget().snapshot(),to:source.appendingPathComponent("budget-summary.json"))
        try Data("{}".utf8).write(to:source.appendingPathComponent("capture-summary.json"))
        let zip = temp.appendingPathComponent("light.zip");try LiDARNavigationArchive.exportZIP(source,to:zip)
        let imported = try LiDARNavigationArchive.importZIP(zip,into:temp.appendingPathComponent("imported"))
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.appendingPathComponent("budget-summary.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.appendingPathComponent("capture-summary.json").path))
    }

    // MARK: revisit gate

    private func report(_ status: String) -> LiDARRevisitReport {
        LiDARRevisitReport(status:status,checked:100,comparable:status == "unknown" ? 0 : 100,coverage:status == "unknown" ? 0 : 0.8,
                           median_m:status == "suspect" ? 0.25 : status == "ok" ? 0.04 : nil,p90_m:status == "suspect" ? 0.3 : nil,
                           reason:status == "unknown" ? "no_full_block_in_view" : "x")
    }
    func testSingleSuspectThenNewAreaKeepsMergingGeometry() {
        // The field failure: one suspect, then walking into unscanned space (unknown) must not lock capture.
        let budget = LiDARBlockBudget()
        var gate = LiDARRevisitGate()
        budget.commit(floor(x0:0,x1:3,z0:0,z1:3))
        let isolated = gate.step(report("suspect"),batchBeforeCommit:budget.batch)
        XCTAssertFalse(isolated.commitGeometry);XCTAssertEqual(isolated.reason,"isolated_single_suspect");XCTAssertTrue(isolated.captureBaseline)
        XCTAssertFalse(gate.blocksEditing)
        for i in 0..<5 {
            let step = gate.step(i%2 == 0 ? report("unknown") : nil,batchBeforeCommit:budget.batch)
            XCTAssertTrue(step.commitGeometry,"new-area frame \(i) must merge")
            if step.commitGeometry { budget.commit(floor(x0:Double(4+i*2),x1:Double(5+i*2),z0:0,z1:1)) }
        }
        XCTAssertEqual(gate.mode,.normal)
        XCTAssertTrue(budget.points.contains { $0.x > 12 },"geometry from the new area is in the map")
    }
    func testThreeConsecutiveSuspectsFlagAndPointToThePreStreakBatch() {
        let budget = LiDARBlockBudget()
        var gate = LiDARRevisitGate()
        budget.commit(floor(x0:0,x1:3,z0:0,z1:3))
        let before = budget.batch,saved = budget.count
        XCTAssertTrue(gate.step(report("suspect"),batchBeforeCommit:budget.batch).captureBaseline)
        // An unknown frame between suspects still merges, and does not break the streak.
        XCTAssertTrue(gate.step(report("unknown"),batchBeforeCommit:budget.batch).commitGeometry)
        budget.commit(floor(x0:5,x1:6,z0:0,z1:1))
        XCTAssertFalse(gate.step(report("suspect"),batchBeforeCommit:budget.batch).captureBaseline)
        let flagged = gate.step(report("suspect"),batchBeforeCommit:budget.batch)
        XCTAssertTrue(flagged.newlyFlagged);XCTAssertEqual(flagged.rollbackToBatch,before);XCTAssertTrue(gate.blocksEditing)
        budget.rollback(toBatch:flagged.rollbackToBatch!);XCTAssertEqual(budget.count,saved)
        let after = gate.step(report("ok"),batchBeforeCommit:budget.batch)
        XCTAssertFalse(after.commitGeometry,"flag stays until the user decides");XCTAssertFalse(after.newlyFlagged)
        gate.continueAsDiagnostic()
        XCTAssertEqual(gate.step(report("ok"),batchBeforeCommit:budget.batch).reason,"diagnostic_segment")
        gate.reset();XCTAssertTrue(gate.step(report("ok"),batchBeforeCommit:budget.batch).commitGeometry)
    }
    func testOkEndsASuspectStreak() {
        var gate = LiDARRevisitGate()
        _ = gate.step(report("suspect"),batchBeforeCommit:1);_ = gate.step(report("suspect"),batchBeforeCommit:1)
        XCTAssertTrue(gate.step(report("ok"),batchBeforeCommit:1).commitGeometry);XCTAssertNil(gate.streakStartBatch)
        XCTAssertTrue(gate.step(report("suspect"),batchBeforeCommit:2).captureBaseline,"a new streak starts after ok")
        XCTAssertEqual(gate.mode,.normal)
    }

    func testSameRoomWithTwoEntrancesRoutesToTheNearerOneByWalkingDistance() throws {
        // Room 1309 has two entrances: W off the west end, E at the far end of a loop A-B-C-E.
        var editor = LiDARRouteEditor()
        let a = try editor.addNode(name:"西口",position:ProbePoint(0,0,0))
        let w = try editor.addNode(name:"1309",kind:.room,position:ProbePoint(0,0,3))
        try editor.setConnectFrom(a.id)
        let b = try editor.addNode(name:nil,position:ProbePoint(10,0,0))
        let c = try editor.addNode(name:nil,position:ProbePoint(10,0,8))
        let e = try editor.addNode(name:"1309",kind:.room,position:ProbePoint(2,0,8))
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"两入口",pointCount:200,voxel:0.12)
        _ = (b,c)
        let near = try map.route(from:ProbePoint(1,0,0.2),toAnyOf:[w.id,e.id])
        XCTAssertEqual(near.destination,w.id);XCTAssertEqual(near.length_m,LiDARNavigationMap.length(near.route),accuracy:1e-9)
        // Near C the shorter walk is to E.
        let walk = try map.route(from:ProbePoint(9.5,0,7.6),toAnyOf:[w.id,e.id])
        XCTAssertEqual(walk.destination,e.id)
        let groups = map.destinationGroups()
        XCTAssertEqual(groups.first { $0.name == "1309" }?.nodeIDs.count,2,"one list entry, two separate entrances")
        XCTAssertThrowsError(try map.route(from:ProbePoint(0,0,0),toAnyOf:["missing"]))
    }

    // MARK: room entrances

    private func corridorEditor() throws -> LiDARRouteEditor {
        var editor = LiDARRouteEditor()
        try editor.addNode(name:"西口",kind:.junction,position:ProbePoint(0,0,0))
        try editor.addNode(name:nil,position:ProbePoint(10,0,0))
        return editor
    }
    func testEntranceSplitsTheNearestEdgeAndKeepsTheConnectionStart() throws {
        var editor = try corridorEditor()
        let from = editor.connectFrom
        let (room,attach) = try editor.addEntrance(name:"1309",position:ProbePoint(4,0,1.2))
        XCTAssertEqual(attach.kind,"split_edge");XCTAssertEqual(attach.distance_m,1.2,accuracy:1e-9)
        XCTAssertEqual(attach.join.x,4,accuracy:1e-9);XCTAssertEqual(room.resolvedKind,.room)
        XCTAssertEqual(editor.connectFrom,from,"marking the corridor continues where it was")
        XCTAssertEqual(editor.nodes.count,4);XCTAssertEqual(editor.edges.count,3)
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"x",pointCount:200,voxel:0.12)
        try map.validate()
        XCTAssertEqual(try map.route(from:ProbePoint(0.5,0,0),to:room.id).last,room.position)
        XCTAssertEqual(editor.undo(),"添加房间入口");XCTAssertEqual(editor.nodes.count,2);XCTAssertEqual(editor.edges.count,1)
    }
    func testEntranceNearAnEndpointJoinsItAndFarEntrancesAreRefused() throws {
        var editor = try corridorEditor()
        let (_,attach) = try editor.addEntrance(name:"楼梯间",position:ProbePoint(9.85,0,0.8))
        XCTAssertEqual(attach.kind,"connected_to_node");XCTAssertEqual(editor.nodes.count,3)
        XCTAssertThrowsError(try editor.addEntrance(name:"远处",position:ProbePoint(5,0,6)))
        XCTAssertThrowsError(try editor.addEntrance(name:" ",position:ProbePoint(5,0,1)))
        var empty = LiDARRouteEditor()
        XCTAssertThrowsError(try empty.addEntrance(name:"空图",position:ProbePoint(0,0,0)),"needs a route first")
    }
    func testDestinationsAreConnectedRoomsAndNamedStairsGroupedByName() throws {
        var editor = try corridorEditor()
        try editor.addNode(name:"楼梯口",kind:.stair,position:ProbePoint(10,0,4))
        try editor.addEntrance(name:"1309",position:ProbePoint(2,0,1))
        try editor.addEntrance(name:"1309",position:ProbePoint(8,0,1))
        try editor.addEntrance(name:"厕所",position:ProbePoint(5,0,-1))
        let map = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"x",pointCount:200,voxel:0.12)
        let groups = map.destinationGroups()
        XCTAssertEqual(Set(groups.map(\.name)),["楼梯口","1309","厕所"],"the junction 西口 and plain waypoints are not destinations")
        XCTAssertEqual(groups.first { $0.name == "1309" }?.nodeIDs.count,2)
    }
    func testSuggestedEntranceDropsThePlateToTheFloorAlongItsNormal() throws {
        let plate = LiDARLandmarkGeometryResult(status:"measured",center:ProbePoint(1,0.4,-2),normal:ProbePoint(0,0,1),spread_m:0.01,observations:3,reason:"x")
        let p = try XCTUnwrap(LiDARLandmarkGeometry.suggestedEntrance(plate,floorY:-1.5))
        XCTAssertEqual(p,ProbePoint(1,-1.5,-1.5))
        XCTAssertNil(LiDARLandmarkGeometry.suggestedEntrance(.unknown(),floorY:-1.5))
    }
    func testWalkThroughAStoredWallIsFlagged() {
        let budget = LiDARBlockBudget()
        budget.commit(floor(x0:0,x1:3,z0:0,z1:3)+wall(x0:0,x1:3,z:1.5))
        XCTAssertTrue(budget.crossesStructure(from:ProbePoint(1,-1.5,0.5),to:ProbePoint(1,-1.5,2.5)))
        XCTAssertFalse(budget.crossesStructure(from:ProbePoint(0.5,-1.5,0.5),to:ProbePoint(2.5,-1.5,0.5)))
    }

    func testSaveCheckSeparatesBlockingProblemsFromPlateReminders() throws {
        var editor = try corridorEditor()
        let (room,_) = try editor.addEntrance(name:"1309",position:ProbePoint(4,0,1))
        let mapID = UUID().uuidString
        let map = editor.map(mapID:mapID,sessionID:UUID().uuidString,name:"x",pointCount:200,voxel:0.12)
        func plate(_ destination: LiDARLandmarkDestination) -> LiDARLandmark {
            LiDARLandmark(category:.room_plate,trigger:.manual,text:LiDARLandmarkText(raw:"1309",candidates:[],confirmedByUser:true,edited:false),
                          destination:destination,geometry:.unknown(),evidence:[])
        }
        let set = LiDARLandmarkSet(mapID:mapID,geometrySHA256:nil,landmarks:[plate(.init(enabled:true,node_id:room.id)),plate(.init(enabled:false,node_id:nil))])
        try set.validate(against:map)
        let check = editor.saveCheck(landmarks:set)
        XCTAssertTrue(check.blocking.isEmpty);XCTAssertEqual(check.platesWithoutEntrance.count,1);XCTAssertEqual(check.warnings.count,1)
        editor.startNewBranch();try editor.addNode(name:"孤立",position:ProbePoint(0,0,9));try editor.addNode(name:nil,position:ProbePoint(1,0,9))
        XCTAssertFalse(editor.saveCheck(landmarks:set).blocking.isEmpty,"a split network blocks saving")
    }
    func testLegacyPlateBoundToAWaypointStillLoadsWithItsDestinationDisabled() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        let editor = try corridorEditor()
        let mapID = UUID().uuidString,map = editor.map(mapID:mapID,sessionID:UUID().uuidString,name:"旧图",pointCount:200,voxel:0.12)
        let legacy = LiDARLandmark(category:.room_plate,trigger:.manual,text:LiDARLandmarkText(raw:"1309",candidates:[],confirmedByUser:true,edited:false),
                                   destination:LiDARLandmarkDestination(enabled:true,node_id:editor.nodes[0].id),geometry:.unknown(),evidence:[])
        let set = LiDARLandmarkSet(mapID:mapID,geometrySHA256:nil,landmarks:[legacy])
        let url = temp.appendingPathComponent(LiDARLandmarkSet.fileName)
        try LiDARNavigationArchive.write(set,to:url);let before = try Data(contentsOf:url)
        XCTAssertThrowsError(try set.validate(against:map),"new rule: destinations bind room entrances")
        let report = try XCTUnwrap(LiDARLandmarkSet.loadReport(temp,map:map))
        XCTAssertEqual(report.downgraded,[legacy.id]);XCTAssertFalse(report.set.landmarks[0].destination.enabled)
        XCTAssertEqual(report.set.landmarks[0].destination.node_id,editor.nodes[0].id,"binding kept for later review")
        XCTAssertEqual(try Data(contentsOf:url),before,"the file on disk is not rewritten")
    }

    func testNewMapsWithoutRoomsDoNotExposeNamedJunctionsButOldMapsKeepTheirDestinations() throws {
        let editor = try corridorEditor()   // only the named junction 西口, no rooms yet
        let fresh = editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"新图",pointCount:200,voxel:0.12)
        XCTAssertEqual(fresh.destination_policy,LiDARNavigationMap.roomsAndNamedStairs)
        XCTAssertTrue(fresh.destinationGroups().isEmpty,"a new map without entrances has no destinations")
        var old = fresh;old.destination_policy = nil
        XCTAssertEqual(old.destinationGroups().map(\.name),["西口"],"older maps keep named nodes")
        let decoded = try JSONDecoder().decode(LiDARNavigationMap.self,from:JSONEncoder().encode(fresh))
        XCTAssertEqual(decoded.destination_policy,fresh.destination_policy);try decoded.validate()
        var bad = fresh;bad.destination_policy = "everything";XCTAssertThrowsError(try bad.validate())
    }
}
