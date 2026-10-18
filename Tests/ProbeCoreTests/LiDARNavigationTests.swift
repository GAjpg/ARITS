import XCTest
@testable import ProbeCore

final class LiDARNavigationTests:XCTestCase {
    private let identity:[[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    private func graph() -> LiDARNavigationMap {
        let nodes = [LiDARRouteNode(name:"西口",position:ProbePoint(0,-1.5,0),id:"a"),
                     LiDARRouteNode(name:"转角",position:ProbePoint(5,-1.5,0),id:"b"),
                     LiDARRouteNode(name:"活动室",position:ProbePoint(5,-1.5,-4),id:"c"),
                     LiDARRouteNode(name:"东口",position:ProbePoint(9,-1.5,0),id:"d")]
        return LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"test",pointCount:500,
            nodes:nodes,edges:[LiDARRouteEdge("a","b"),LiDARRouteEdge("b","c"),LiDARRouteEdge("b","d")])
    }
    func testRouteJoinsEdgeAndTakesBranchInBothDirections() throws {
        let map = graph();try map.validate()
        let outward = try map.route(from:ProbePoint(2,0,0.8),to:"c")
        XCTAssertEqual(outward,[ProbePoint(2,-1.5,0),ProbePoint(5,-1.5,0),ProbePoint(5,-1.5,-4)])
        XCTAssertEqual(try map.route(from:ProbePoint(5,0,-2),to:"a"),[ProbePoint(5,-1.5,-2),ProbePoint(5,-1.5,0),ProbePoint(0,-1.5,0)])
        XCTAssertEqual(try CampusRouteGeometry(points:outward).length,7,accuracy:0.001)
    }
    func testDisconnectedAndTamperedMapsAreRejected() throws {
        var map = graph();map.edges.removeLast();XCTAssertThrowsError(try map.validate())
        map = graph();map.points_file = "../outside";XCTAssertThrowsError(try map.validate())
        map = graph();map.initial_world_map_used = true;XCTAssertThrowsError(try map.validate())
        map = graph();map.nodes[0].position.x = .nan;XCTAssertThrowsError(try map.validate())
    }
    func testRuntimePointRoundTripAndNonFiniteBytesRejected() throws {
        let points = [ProbePoint(-1.25,-0.5,4.125),ProbePoint(2,0,-3)]
        let data = try LiDARPointFile.encode(points)
        XCTAssertEqual(try LiDARPointFile.decode(data,count:2),points)
        XCTAssertThrowsError(try LiDARPointFile.decode(data,count:1))
        var bad = data;bad.replaceSubrange(0..<4,with:[0,0,192,127])
        XCTAssertThrowsError(try LiDARPointFile.decode(bad,count:2))
    }
    func testDelayedResultUsesLiveCameraAndCannotCrossSessions() throws {
        var alignment = LiDARSessionAlignment(sessionID:"fresh")
        let transform:[[Double]] = [[0,0,1,10],[0,1,0,1],[-1,0,0,20],[0,0,0,1]]
        try alignment.accept(transform,sessionID:"fresh")
        var live = identity;live[2][3] = -3
        let camera = try alignment.cameraInMap(live)
        XCTAssertEqual(camera[0][3],7,accuracy:1e-6);XCTAssertEqual(camera[2][3],20,accuracy:1e-6)
        alignment.reset(sessionID:"restarted")
        XCTAssertThrowsError(try alignment.accept(transform,sessionID:"fresh"))
        XCTAssertThrowsError(try alignment.cameraInMap(live))
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
    func testIndependentGravityAlignedQueryRecoversKnownTransform() throws {
        let map = room(),yaw = 1.13,c = cos(yaw),s = sin(yaw)
        let query = map.enumerated().filter { $0.offset%3 != 0 && $0.element.x < 4.4 }.map { index,p -> ProbePoint in
            let x = p.x-1.1,z = p.z+2.3,jitter = sin(Double(index)*1.7)*0.007
            return ProbePoint(c*x-s*z+jitter,p.y+0.28,-s*(-x)+c*z-jitter)
        }
        let result = LiDARLocalizer.solve(map:map,query:query,sessionID:"independent",maxSeconds:60)
        XCTAssertTrue(["candidate_requires_review","ambiguous"].contains(result.status),result.reason)
        let best = try XCTUnwrap(result.best)
        XCTAssertEqual(best.transform_query_to_map[0][3],1.1,accuracy:0.25)
        XCTAssertEqual(best.transform_query_to_map[1][3],-0.28,accuracy:0.12)
        XCTAssertEqual(best.transform_query_to_map[2][3],-2.3,accuracy:0.25)
        let recovered = atan2(best.transform_query_to_map[0][2],best.transform_query_to_map[0][0])
        XCTAssertLessThan(abs(atan2(sin(recovered-yaw),cos(recovered-yaw))),0.06)
        XCTAssertTrue(result.requires_physical_confirmation)
    }
    func testSinglePlaneAndCancelledSearchCannotProduceTrustedLocation() {
        let plane = (0..<30).flatMap { x in (0..<30).map { z in ProbePoint(Double(x)/10,-1.5,-Double(z)/10) } }
        XCTAssertEqual(LiDARLocalizer.solve(map:plane,query:plane,sessionID:"floor").status,"rejected")
        let cancellation = LiDARWorkCancellation();cancellation.cancel()
        let cancelled = LiDARLocalizer.solve(map:room(),query:room(),sessionID:"cancelled",cancellation:cancellation)
        XCTAssertEqual(cancelled.status,"cancelled");XCTAssertTrue(cancelled.candidates.isEmpty)
    }
    func testTwoIdenticalRoomsAreNotAcceptedAsUniqueLocation() {
        let original = room()
        let repeated = original+original.map { ProbePoint($0.x+9,$0.y,$0.z) }
        let result = LiDARLocalizer.solve(map:repeated,query:original,sessionID:"repeated",maxSeconds:60)
        XCTAssertEqual(result.status,"ambiguous",result.reason)
        let xs = result.candidates.filter(\.quality_gate).map { $0.transform_query_to_map[0][3] }
        XCTAssertGreaterThan((xs.max() ?? 0)-(xs.min() ?? 0),5)
    }
    func testLightBackupRoundTripAndDuplicateImportPreserveOriginal() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let source = temp.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        var map = graph();let points = Array(room().prefix(500));map.point_count = points.count
        try LiDARNavigationArchive.write(map,to:source.appendingPathComponent("navigation.json"))
        let pointBytes = try LiDARPointFile.encode(points)
        try pointBytes.write(to:source.appendingPathComponent("geometry.f32"))
        try Data(repeating:1,count:1024).write(to:source.appendingPathComponent("raw-depth-not-for-runtime.bin"))
        let zip = temp.appendingPathComponent("backup.zip")
        try LiDARNavigationArchive.exportZIP(source,to:zip)
        let imported = try LiDARNavigationArchive.importZIP(zip,into:temp.appendingPathComponent("imported"))
        let (restored,restoredPoints) = try LiDARNavigationArchive.load(imported)
        XCTAssertEqual(restored.map_id,map.map_id);XCTAssertEqual(restored.nodes,map.nodes)
        XCTAssertEqual(restored.edges,map.edges);XCTAssertEqual(restoredPoints.count,points.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath:imported.appendingPathComponent("raw-depth-not-for-runtime.bin").path))
        XCTAssertThrowsError(try LiDARNavigationArchive.importZIP(zip,into:temp.appendingPathComponent("imported")))
        XCTAssertEqual(try Data(contentsOf:imported.appendingPathComponent("geometry.f32")),pointBytes)
        var changed = pointBytes;changed[0] ^= 1
        try changed.write(to:imported.appendingPathComponent("geometry.f32"))
        let tampered = temp.appendingPathComponent("tampered.zip")
        try ProbeZip.create(directory:imported,destination:tampered)
        XCTAssertThrowsError(try LiDARNavigationArchive.importZIP(tampered,into:temp.appendingPathComponent("rejected")))
    }
    func testRawScanCleanupKeepsNavigableGeometryAndRoute() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        try FileManager.default.createDirectory(at:folder.appendingPathComponent("frames/0000"),withIntermediateDirectories:true)
        var map = graph();let points = Array(room().prefix(500));map.point_count = points.count
        try LiDARNavigationArchive.write(map,to:folder.appendingPathComponent("navigation.json"))
        try LiDARPointFile.encode(points).write(to:folder.appendingPathComponent("geometry.f32"))
        try Data([1,2,3]).write(to:folder.appendingPathComponent("reference.jpg"))
        try Data([1,2,3]).write(to:folder.appendingPathComponent("frames/0000/depth.f32"))
        try Data("{}".utf8).write(to:folder.appendingPathComponent("scan.json"))
        try LiDARNavigationArchive.removeRawScanData(in:folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("scan.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.appendingPathComponent("frames").path))
        let (restored,cloud) = try LiDARNavigationArchive.load(folder)
        XCTAssertEqual(restored.nodes,map.nodes);XCTAssertEqual(cloud.count,points.count)
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent("reference.jpg")),Data([1,2,3]))
        try CampusFiles.verify(folder)
        let bad = folder.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at:bad,withIntermediateDirectories:true)
        try Data("keep".utf8).write(to:bad.appendingPathComponent("scan.json"))
        XCTAssertThrowsError(try LiDARNavigationArchive.removeRawScanData(in:bad))
        XCTAssertEqual(try Data(contentsOf:bad.appendingPathComponent("scan.json")),Data("keep".utf8))
    }
}
