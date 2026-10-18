import XCTest
@testable import ProbeCore

final class LiDARLocalizationModeTests: XCTestCase {
    private let identity: [[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    private func yawMatrix(_ degrees: Double, x: Double = 0, z: Double = 0) -> [[Double]] {
        let r = degrees*Double.pi/180,c = cos(r),s = sin(r)
        return [[c,0,s,x],[0,1,0,0],[-s,0,c,z],[0,0,0,1]]
    }
    /// A featureless straight corridor: floor plus two parallel walls along x.
    private func corridor(length: Double = 20) -> [ProbePoint] {
        var points = [ProbePoint]()
        for x in stride(from:0.0,through:length,by:0.12) {
            for z in stride(from:0.0,through:2.4,by:0.2) { points.append(ProbePoint(x,-1.5,z)) }
            for y in stride(from:-1.5,through:1.0,by:0.15) { points.append(ProbePoint(x,y,0));points.append(ProbePoint(x,y,2.4)) }
        }
        return points
    }
    private func room() -> [ProbePoint] {
        var points = [ProbePoint]()
        for x in stride(from:0.0,through:5.4,by:0.18) {
            for z in stride(from:-4.0,through:0.0,by:0.18) { points.append(ProbePoint(x,-1.5,z)) }
            for y in stride(from:-1.5,through:1.0,by:0.18) { points.append(ProbePoint(x,y,-4)) }
        }
        for z in stride(from:-4.0,through:0.0,by:0.18) { for y in stride(from:-1.5,through:1.0,by:0.18) { points.append(ProbePoint(0,y,z)) } }
        for x in stride(from:2.6,through:3.4,by:0.12) { for y in stride(from:-1.5,through:0.6,by:0.15) { points.append(ProbePoint(x,y,-1.3));points.append(ProbePoint(3.4,y,x-4.7)) } }
        return points
    }

    func testFeaturelessCorridorIsNeverReportedAsSingleCandidate() {
        let map = corridor()
        let query = map.filter { $0.x > 7 && $0.x < 13 }.map { ProbePoint($0.x-9,$0.y+0.1,$0.z-1.2) }
        let result = LiDARLocalizer.solve(map:map,query:query,sessionID:"corridor",maxSeconds:60)
        XCTAssertNotEqual(result.status,"candidate_requires_review",result.reason)
        XCTAssertEqual(result.schema_version,2)
        if result.status == "ambiguous" {
            let codes = Set(result.decision_reasons ?? [])
            XCTAssertFalse(codes.isDisjoint(with:["along_axis_spread","multiple_modes","weak_structure"]),"\(codes)")
        }
    }

    func testDistinctRoomReportsCompleteSearchModesAndParameters() throws {
        let map = room(),yaw = 1.13,c = cos(yaw),s = sin(yaw)
        let query = map.enumerated().filter { $0.offset%3 != 0 && $0.element.x < 4.4 }.map { _,p -> ProbePoint in
            let x = p.x-1.1,z = p.z+2.3
            return ProbePoint(c*x-s*z,p.y+0.28,s*x+c*z)
        }
        let result = LiDARLocalizer.solve(map:map,query:query,sessionID:"room",maxSeconds:60)
        XCTAssertTrue(["candidate_requires_review","ambiguous"].contains(result.status),result.reason)
        XCTAssertEqual(result.search_complete,true,"\(result.incomplete_reasons ?? [])")
        let modes = try XCTUnwrap(result.modes);XCTAssertFalse(modes.isEmpty)
        XCTAssertGreaterThanOrEqual(result.coarse_components ?? 0,1)
        XCTAssertTrue(result.candidates.allSatisfy { $0.mode_id != nil })
        XCTAssertEqual(result.parameters_hash,LiDARLocalizerParameters().hash)
        XCTAssertEqual(result.parameters?["mode_delta"],0.03)
        XCTAssertNotNil(result.stage_seconds?["coarse"])
        XCTAssertNil(result.provenance)
    }

    func testRepeatedRoomsKeepEachModeVisible() {
        let original = room(),repeated = original+original.map { ProbePoint($0.x+9,$0.y,$0.z) }
        let result = LiDARLocalizer.solve(map:repeated,query:original,sessionID:"repeated",maxSeconds:60)
        XCTAssertEqual(result.status,"ambiguous",result.reason)
        XCTAssertTrue(result.decision_reasons?.contains("multiple_modes") ?? false)
        let modeIDs = Set(result.candidates.filter(\.quality_gate).compactMap(\.mode_id))
        XCTAssertGreaterThanOrEqual(modeIDs.count,2)
    }

    func testVersionOneResultStillDecodesWithNilDiagnostics() throws {
        let json = """
        {"algorithm":"gravity_correlative_search_3d_icp_v1","session_id":"s","status":"ambiguous","reason":"r",
         "candidates":[{"transform_query_to_map":[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],"overlap":0.9,
           "structural_overlap":0.8,"rmse_m":0.08,"geometry_score":0.8,"quality_gate":true}],
         "registration_seconds":0.2,"map_points":100,"query_points":100,"structural_constraint_ratio":0.3,
         "requires_physical_confirmation":true,"initial_world_map_used":false}
        """
        let result = try JSONDecoder().decode(LiDARLocalizationResult.self,from:Data(json.utf8))
        XCTAssertNil(result.schema_version);XCTAssertNil(result.search_complete);XCTAssertNil(result.modes)
        XCTAssertNil(result.candidates[0].mode_id)
    }

    func testParameterHashChangesWithAnyValue() {
        var p = LiDARLocalizerParameters();let original = p.hash
        p.mode_delta = 0.05;XCTAssertNotEqual(p.hash,original)
    }

    private func reference(_ transform: [[Double]]) -> LiDARConfirmedAlignment {
        LiDARConfirmedAlignment(map_id:"m",geometry_sha256:"g",session_id:"s",generation:1,attempt_id:"a",candidate_index:0,transform:transform)
    }
    func testConsistencyUsesCameraCorrectionAndWrapsYaw() throws {
        let ref = reference(yawMatrix(170,x:1,z:2))
        var camera = identity;camera[0][3] = 3;camera[2][3] = -1
        let same = LiDARSessionConsistency.compare(reference:ref,transform:yawMatrix(-175,x:1,z:2),mapID:"m",geometrySHA256:"g",
                                                   sessionID:"s",generation:1,cameraInSession:camera)
        XCTAssertEqual(same.reason,"ok");XCTAssertEqual(try XCTUnwrap(same.yaw_delta_deg),15,accuracy:1e-6)
        let flipped = LiDARSessionConsistency.compare(reference:ref,transform:yawMatrix(-10,x:1,z:2),mapID:"m",geometrySHA256:"g",
                                                      sessionID:"s",generation:1,cameraInSession:camera)
        XCTAssertEqual(try XCTUnwrap(flipped.yaw_delta_deg),180,accuracy:1e-6)
        XCTAssertEqual(flipped.consistent,false)
        // A pure rotation about the session origin moves a camera 3.16 m away by 2*r*sin(90°).
        XCTAssertEqual(try XCTUnwrap(flipped.camera_correction_m),2*sqrt(10),accuracy:1e-6)
        let shifted = LiDARSessionConsistency.compare(reference:ref,transform:yawMatrix(170,x:1.5,z:2),mapID:"m",geometrySHA256:"g",
                                                      sessionID:"s",generation:1,cameraInSession:camera)
        XCTAssertEqual(shifted.consistent,true);XCTAssertEqual(try XCTUnwrap(shifted.camera_correction_m),0.5,accuracy:1e-6)
    }
    func testConsistencyIsUnavailableAcrossBindingsAndFallsBackWithoutCamera() {
        let ref = reference(identity)
        XCTAssertEqual(LiDARSessionConsistency.compare(reference:nil,transform:identity,mapID:"m",geometrySHA256:"g",sessionID:"s",generation:1).reason,"no_reference")
        XCTAssertEqual(LiDARSessionConsistency.compare(reference:ref,transform:identity,mapID:"x",geometrySHA256:"g",sessionID:"s",generation:1).reason,"different_map")
        XCTAssertEqual(LiDARSessionConsistency.compare(reference:ref,transform:identity,mapID:"m",geometrySHA256:"h",sessionID:"s",generation:1).reason,"different_geometry")
        XCTAssertEqual(LiDARSessionConsistency.compare(reference:ref,transform:identity,mapID:"m",geometrySHA256:"g",sessionID:"t",generation:1).reason,"different_session")
        let restarted = LiDARSessionConsistency.compare(reference:ref,transform:identity,mapID:"m",geometrySHA256:"g",sessionID:"s",generation:2)
        XCTAssertEqual(restarted.reason,"different_generation");XCTAssertNil(restarted.consistent)
        var moved = identity;moved[0][3] = 2
        let origin = LiDARSessionConsistency.compare(reference:ref,transform:moved,mapID:"m",geometrySHA256:"g",sessionID:"s",generation:1)
        XCTAssertEqual(origin.reason,"origin_mapping_only");XCTAssertEqual(origin.origin_mapping_delta_m,2);XCTAssertNil(origin.camera_correction_m)
        XCTAssertEqual(origin.consistent,false)
    }

    /// A camera at the origin looking down -Z at a flat wall 2 m away.
    private func wallFrame(index: Int, x: Double) -> (LiDARFrame,Data,Data) {
        let width = 32,height = 24
        let calibration = LiDARCalibration(width:width,height:height,imageWidth:width,imageHeight:height,fx:30,fy:30,cx:16,cy:12)
        var pose = identity;pose[0][3] = x
        let frame = LiDARFrame(index:index,timestamp:Double(index),transform:pose,calibration:calibration,validFraction:1)
        var depth = Data();for _ in 0..<(width*height) { var bits = Float(2).bitPattern.littleEndian;withUnsafeBytes(of:&bits) { depth.append(contentsOf:$0) } }
        return (frame,depth,Data(repeating:2,count:width*height))
    }
    func testFreeSpaceSeparatesObservedFreeSpaceFromWallAndUnknown() throws {
        var settings = LiDARFreeSpaceMap.Settings();settings.pixel_stride = 1
        var space = LiDARFreeSpaceMap(settings:settings)
        for i in 0..<4 { let (f,d,c) = wallFrame(index:i,x:Double(i)*0.05);try space.add(frame:f,depth:d,confidence:c) }
        XCTAssertEqual(space.state(LiDARVoxelKey(ProbePoint(0.05,0,-2.0),size:0.1)),.occupied)
        XCTAssertEqual(space.state(LiDARVoxelKey(ProbePoint(0.05,0,-1.0),size:0.1)),.free)
        XCTAssertEqual(space.state(LiDARVoxelKey(ProbePoint(0.05,0,-3.0),size:0.1)),.unknown)
        // A query wall placed 1 m in front of the real wall lands in observed free space.
        var floor = [ProbePoint]();for x in stride(from:-0.3,through:0.3,by:0.1) { floor.append(ProbePoint(x,-1.5,-1)) }
        let wrong = floor+stride(from:-0.3,through:0.3,by:0.05).map { ProbePoint($0,0,-1.05) }
        let check = space.check(query:wrong,transform:identity)
        XCTAssertGreaterThan(check.comparable,0);XCTAssertGreaterThan(try XCTUnwrap(check.conflict_rate),0.5)
        let right = floor+stride(from:-0.3,through:0.3,by:0.05).map { ProbePoint($0,0,-2.0) }
        XCTAssertEqual(space.check(query:right,transform:identity).conflicts,0)
        let behind = floor+stride(from:-0.3,through:0.3,by:0.05).map { ProbePoint($0,0,-3.5) }
        let unseen = space.check(query:behind,transform:identity)
        XCTAssertEqual(unseen.comparable,0);XCTAssertNil(unseen.conflict_rate)
    }

    func testStartNodeWindowSeparatesRepeatedRoomsAndRecordsEveryTier() throws {
        let original = room(),repeated = original+original.map { ProbePoint($0.x+20,$0.y,$0.z) }
        let camera = ProbePoint(2.5,0,-1.5)
        let global = LiDARLocalizer.solve(map:repeated,query:original,sessionID:"global",maxSeconds:60)
        XCTAssertEqual(global.status,"ambiguous");XCTAssertNil(global.search_scope)
        let near = LiDARLocalizer.solveWindowed(map:repeated,query:original,sessionID:"near",referenceCamera:camera,
                                                center:ProbePoint(22,0,-2),centerNodeID:"room-b",radii:[6,15],maxSeconds:60)
        XCTAssertEqual(near.tiers.count,1);XCTAssertEqual(near.final.status,"candidate_requires_review",near.final.reason)
        let scope = try XCTUnwrap(near.final.search_scope)
        XCTAssertEqual(scope.center_node_id,"room-b");XCTAssertEqual(scope.candidate_radius_m,6);XCTAssertEqual(scope.tiers_tried,1)
        XCTAssertGreaterThan(scope.support_radius_m,scope.candidate_radius_m);XCTAssertNotNil(scope.bounds_xz)
        let best = try XCTUnwrap(near.final.best).transform_query_to_map
        let mapped = CampusMapGeometry.point(camera.array,through:best)
        XCTAssertLessThanOrEqual(hypot(mapped[0]-22,mapped[2]+2),6)
        XCTAssertEqual(best[0][3],20,accuracy:0.3)
        // A wrong start node: the small tier has nothing, the wide tier sees both rooms and stays ambiguous.
        let wrong = LiDARLocalizer.solveWindowed(map:repeated,query:original,sessionID:"wrong",referenceCamera:camera,
                                                 center:ProbePoint(12,0,-2),radii:[2,18],maxSeconds:60)
        XCTAssertEqual(wrong.tiers.count,2);XCTAssertEqual(wrong.tiers[0].status,"rejected")
        XCTAssertEqual(wrong.final.status,"ambiguous");XCTAssertEqual(wrong.final.search_scope?.tiers_tried,2)
    }
}
