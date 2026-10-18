import XCTest
@testable import ProbeCore
#if canImport(CoreText)
import CoreText
import CoreGraphics
#endif

final class LiDARLandmarkTests: XCTestCase {
    private let identity: [[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]

    func testTextNormalizationAndConfusableSimilarity() {
        XCTAssertEqual(LiDARText.normalize("１３０９　室"),"1309室")
        XCTAssertEqual(LiDARText.normalize(" a-12 "),"A12")
        XCTAssertEqual(LiDARText.similarity("1309","1309"),1)
        XCTAssertGreaterThan(LiDARText.similarity("1309","7309"),LiDARText.similarity("1309","4309"))
        XCTAssertEqual(LiDARText.similarity("1309","1308"),0.75,accuracy:1e-9)
        XCTAssertTrue(LiDARText.looksLikeRoomNumber("1309"));XCTAssertTrue(LiDARText.looksLikeRoomNumber("B305"))
        XCTAssertFalse(LiDARText.looksLikeRoomNumber("禁止喧哗"));XCTAssertFalse(LiDARText.looksLikeRoomNumber("12"))
    }

    func testVisionBoxMapsBackToNativePixels() {
        // Native 1920x1440 box (x, y, w, h), forward-mapped as Vision reports it for .right.
        let W = 1920.0,H = 1440.0,x = 300.0,y = 500.0,w = 120.0,h = 60.0
        let vision = [(H-(y+h))/H,1-(x+w)/W,h/H,w/W]
        let native = LiDARLandmarkGeometry.nativeBox(visionBox:vision,imageWidth:1920,imageHeight:1440)
        for (a,b) in zip(native,[x,y,w,h]) { XCTAssertEqual(a,b,accuracy:1e-6) }
    }

    /// Camera at (cx, 0, 0) looking down -Z at a wall at z = -2.
    private func sample(cameraX: Double = 0, index: Int, wall: Bool = true) -> LiDARLandmarkSample {
        let width = 64,height = 48
        let calibration = LiDARCalibration(width:width,height:height,imageWidth:width,imageHeight:height,fx:50,fy:50,cx:32,cy:24)
        var pose = identity;pose[0][3] = cameraX
        let frame = LiDARFrame(index:index,timestamp:Double(index),transform:pose,calibration:calibration,validFraction:1)
        var depth = Data()
        for _ in 0..<(width*height) { var bits = (wall ? Float(2) : Float.nan).bitPattern.littleEndian;withUnsafeBytes(of:&bits) { depth.append(contentsOf:$0) } }
        return LiDARLandmarkSample(frame:frame,depth:depth,confidence:Data(repeating:2,count:width*height),nativeBox:[28,20,8,8])
    }
    func testPlateOnAWallIsMeasuredWithNormalTowardTheCamera() throws {
        let result = LiDARLandmarkGeometry.measure([sample(index:0),sample(index:1),sample(index:2)])
        XCTAssertEqual(result.status,"measured",result.reason);XCTAssertEqual(result.observations,3)
        let c = try XCTUnwrap(result.center),n = try XCTUnwrap(result.normal)
        XCTAssertEqual(c.z,-2,accuracy:0.01);XCTAssertEqual(c.x,0,accuracy:0.05);XCTAssertEqual(c.y,0,accuracy:0.05)
        XCTAssertEqual(n.z,1,accuracy:1e-3);XCTAssertEqual(n.y,0)
        XCTAssertEqual(result.reason,"consistency_only_not_absolute_accuracy")
    }
    func testMissingWallOrDisagreeingFramesStayUnknown() {
        let missing = LiDARLandmarkGeometry.measure([sample(index:0,wall:false),sample(index:1,wall:false)])
        XCTAssertEqual(missing.status,"unknown");XCTAssertNil(missing.center)
        XCTAssertEqual(LiDARLandmarkGeometry.measure([sample(index:0)]).reason,"too_few_measured_frames")
        // Same image box seen from cameras 0.3 m apart lands on different wall points.
        let moved = LiDARLandmarkGeometry.measure([sample(cameraX:0,index:0),sample(cameraX:0.3,index:1)])
        XCTAssertEqual(moved.status,"unknown");XCTAssertEqual(moved.reason,"frames_disagree");XCTAssertNotNil(moved.spread_m)
    }

    private func map() throws -> LiDARNavigationMap {
        var editor = LiDARRouteEditor()
        try editor.addNode(name:"走廊",position:ProbePoint(0,0,0),id:"n1");try editor.addNode(name:"1309",kind:.room,position:ProbePoint(3,0,0),id:"n2")
        return editor.map(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"门牌",pointCount:200,voxel:0.12)
    }
    private func landmark(category: LiDARLandmark.Category = .room_plate, trigger: LiDARLandmark.Trigger = .manual,
                          confirmed: Bool = true, destination: LiDARLandmarkDestination = LiDARLandmarkDestination(enabled:false,node_id:nil),
                          image: String = "landmarks/a/0.jpg") -> LiDARLandmark {
        let calibration = LiDARCalibration(width:256,height:192,imageWidth:1920,imageHeight:1440,fx:1500,fy:1500,cx:960,cy:720)
        let evidence = LiDARLandmarkEvidence(timestamp:1,session_id:"s",generation:0,camera_to_session:identity,calibration:calibration,
                                             image_file:image,native_box:[300,500,120,60])
        return LiDARLandmark(category:category,trigger:trigger,
                             text:LiDARLandmarkText(raw:"１３０９",candidates:[LiDARTextCandidate(text:"1309",confidence:1)],confirmedByUser:confirmed,edited:false),
                             destination:destination,geometry:LiDARLandmarkGeometry.measure([]),evidence:[evidence])
    }
    func testLandmarkSetRules() throws {
        let m = try map()
        func check(_ l: LiDARLandmark) throws { try LiDARLandmarkSet(mapID:m.map_id,geometrySHA256:nil,landmarks:[l]).validate(against:m) }
        XCTAssertNoThrow(try check(landmark()))
        XCTAssertEqual(landmark().text.normalized,"1309")
        XCTAssertThrowsError(try check(landmark(confirmed:false)),"manual plates need confirmed text")
        XCTAssertThrowsError(try check(landmark(trigger:.auto)),"auto detections are never room plates")
        XCTAssertThrowsError(try check(landmark(category:.reference_feature,trigger:.auto,destination:LiDARLandmarkDestination(enabled:true,node_id:"n2"))))
        XCTAssertNoThrow(try check(landmark(destination:LiDARLandmarkDestination(enabled:true,node_id:"n2"))))
        XCTAssertThrowsError(try check(landmark(destination:LiDARLandmarkDestination(enabled:true,node_id:nil))))
        XCTAssertThrowsError(try check(landmark(destination:LiDARLandmarkDestination(enabled:false,node_id:"missing"))))
        XCTAssertThrowsError(try check(landmark(image:"../escape.jpg")))
        XCTAssertThrowsError(try LiDARLandmarkSet(mapID:UUID().uuidString,geometrySHA256:nil,landmarks:[]).validate(against:m))
    }
    func testLightweightExportCarriesLandmarksAndEvidence() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let source = temp.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("landmarks/a"),withIntermediateDirectories:true)
        let m = try map(),points = (0..<200).map { ProbePoint(Double($0)*0.05,0,0) }
        try LiDARNavigationArchive.write(m,to:source.appendingPathComponent("navigation.json"))
        try LiDARPointFile.encode(points).write(to:source.appendingPathComponent("geometry.f32"))
        try LiDARNavigationArchive.write(LiDARLandmarkSet(mapID:m.map_id,geometrySHA256:nil,landmarks:[landmark()]),to:source.appendingPathComponent("landmarks.json"))
        try Data([0xFF,0xD8,0xFF]).write(to:source.appendingPathComponent("landmarks/a/0.jpg"))
        let zip = temp.appendingPathComponent("light.zip");try LiDARNavigationArchive.exportZIP(source,to:zip)
        let imported = try LiDARNavigationArchive.importZIP(zip,into:temp.appendingPathComponent("imported"))
        let (loaded,_) = try LiDARNavigationArchive.load(imported)
        let set = try XCTUnwrap(LiDARLandmarkSet.load(imported,map:loaded))
        XCTAssertEqual(set.landmarks.count,1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:imported.appendingPathComponent("landmarks/a/0.jpg").path))
    }

    #if canImport(CoreText) && canImport(Vision)
    func testOCRReadsARenderedRoomNumber() throws {
        let width = 480,height = 200
        let ctx = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
                                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:width,height:height))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString,110,nil)
        let text = NSAttributedString(string:"1309",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,
                                                                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(red:0,green:0,blue:0,alpha:1)])
        ctx.textPosition = CGPoint(x:60,y:50);CTLineDraw(CTLineCreateWithAttributedString(text),ctx)
        let image = try XCTUnwrap(ctx.makeImage())
        let found = try LiDAROCR.recognize(image,orientation:.up)
        XCTAssertTrue(found.contains { LiDARText.normalize($0.text) == "1309" },"\(found.map(\.text))")
        XCTAssertTrue(found.allSatisfy { $0.vision_box.count == 4 && !$0.candidates.isEmpty })
    }
    #endif

    func testLoadChecksGeometryHashEvidenceFilesAndBoxes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        try FileManager.default.createDirectory(at:temp.appendingPathComponent("landmarks/a"),withIntermediateDirectories:true)
        let m = try map()
        var set = LiDARLandmarkSet(mapID:m.map_id,geometrySHA256:"abc",landmarks:[landmark()])
        XCTAssertEqual(set.landmarks[0].geometry.status,"unknown")
        XCTAssertEqual(LiDARLandmarkGeometryResult.unknown().reason,"not_measured")
        try LiDARNavigationArchive.write(set,to:temp.appendingPathComponent("landmarks.json"))
        XCTAssertThrowsError(try LiDARLandmarkSet.load(temp,map:m),"evidence image missing")
        try Data([0xFF,0xD8]).write(to:temp.appendingPathComponent("landmarks/a/0.jpg"))
        XCTAssertNotNil(try LiDARLandmarkSet.load(temp,map:m,geometrySHA256:"abc"))
        XCTAssertThrowsError(try LiDARLandmarkSet.load(temp,map:m,geometrySHA256:"other"))
        set.landmarks[0].evidence[0].native_box = [1800,500,300,60]   // runs past the 1920 px image edge
        XCTAssertThrowsError(try set.validate(against:m))
        set.landmarks[0].evidence[0].native_box = [300,.nan,120,60];XCTAssertThrowsError(try set.validate(against:m))
        set.landmarks[0].evidence = Array(repeating:landmark().evidence[0],count:11);XCTAssertThrowsError(try set.validate(against:m))
    }

    func testPlaneSourceIndependentPathMatchesTheDepthPath() throws {
        let depthResult = LiDARLandmarkGeometry.measure([sample(index:0),sample(index:1)])
        // Same geometry described as ray + wall plane, as a device without depth would supply it.
        let ray = LiDARPlaneSample(cameraOrigin:ProbePoint(0,0,0),rayDirection:ProbePoint(0,0,-1),
                                   planePoint:ProbePoint(0.3,0.2,-2),planeNormal:ProbePoint(0,0,-1))
        let planeResult = LiDARLandmarkGeometry.measure(planes:[ray,ray])
        XCTAssertEqual(planeResult.status,"measured")
        let a = try XCTUnwrap(depthResult.center),b = try XCTUnwrap(planeResult.center)
        XCTAssertEqual(a.z,b.z,accuracy:0.01);XCTAssertEqual(planeResult.normal?.z ?? 0,1,accuracy:1e-9)
        let floorPlane = LiDARPlaneSample(cameraOrigin:ProbePoint(0,0,0),rayDirection:ProbePoint(0,-1,-1),planePoint:ProbePoint(0,-1.5,0),planeNormal:ProbePoint(0,1,0))
        XCTAssertEqual(LiDARLandmarkGeometry.measure(planes:[floorPlane,floorPlane]).status,"unknown","a floor is not a plate wall")
    }
    func testGeometryResultConvertsToNeutralEvidence() throws {
        let result = LiDARLocalizationResult(session_id:"s",status:"ambiguous",reason:"r",
            candidates:[LiDARLocalizationCandidate(transform_query_to_map:identity,overlap:0.9,structural_overlap:0.9,rmse_m:0.05,geometry_score:0.9,quality_gate:true)],
            registration_seconds:1,map_points:100,query_points:100,structural_constraint_ratio:0.3)
        let e = LiDARLocalizationEvidence.fromGeometry(result,generation:2)
        XCTAssertEqual(e.source,.geometry);XCTAssertEqual(e.constraint,.pose_4dof);XCTAssertEqual(e.status,"ambiguous");XCTAssertEqual(e.transform,identity)
        var rejected = result;rejected.status = "rejected"
        let r = LiDARLocalizationEvidence.fromGeometry(rejected)
        XCTAssertEqual(r.constraint,.none);XCTAssertNil(r.transform)
        let decoded = try JSONDecoder().decode(LiDARLocalizationEvidence.self,from:JSONEncoder().encode(e));XCTAssertEqual(decoded,e)
    }

    func testEvidenceBoxSourceIsRecordedAndChecked() throws {
        let m = try map()
        var l = landmark();l.evidence[0].box_source = "none_full_image"
        XCTAssertNoThrow(try LiDARLandmarkSet(mapID:m.map_id,geometrySHA256:nil,landmarks:[l]).validate(against:m))
        l.evidence[0].box_source = "guessed";XCTAssertThrowsError(try LiDARLandmarkSet(mapID:m.map_id,geometrySHA256:nil,landmarks:[l]).validate(against:m))
        let old = try JSONDecoder().decode(LiDARLandmarkEvidence.self,from:JSONEncoder().encode(landmark().evidence[0]))
        XCTAssertNil(old.box_source,"files written before the field still load")
    }

    func testOnlyWallMountedMeasuredPlatesMayConstrainAPose() throws {
        var l = landmark()
        l.geometry = LiDARLandmarkGeometryResult(status:"measured",center:ProbePoint(0,0,-2),normal:ProbePoint(0,0,1),spread_m:0.01,observations:3,reason:"x")
        XCTAssertFalse(l.usableForPose,"unknown mount is not trusted")
        l.mount = .door;XCTAssertFalse(l.usableForPose,"a plate on a door moves with the door")
        l.mount = .wall;XCTAssertTrue(l.usableForPose)
        l.geometry = .unknown();XCTAssertFalse(l.usableForPose)
        XCTAssertEqual(try JSONDecoder().decode(LiDARLandmark.self,from:JSONEncoder().encode(l)).mount,.wall)
    }
}
