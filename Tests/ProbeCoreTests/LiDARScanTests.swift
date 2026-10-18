import XCTest
@testable import ProbeCore

final class LiDARScanTests: XCTestCase {
    let identity: [[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    func floats(_ values:[Float]) -> Data {
        var data = Data()
        for f in values { var v = f.bitPattern.littleEndian;withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        return data
    }
    func frame(_ index:Int = 0) -> LiDARFrame {
        LiDARFrame(index:index,timestamp:Double(index+1),transform:identity,
            calibration:LiDARCalibration(width:2,height:2,imageWidth:4,imageHeight:4,fx:4,fy:4,cx:2,cy:2),validFraction:1)
    }
    func testPaddedBufferDoesNotLeakStrideBytes() throws {
        XCTAssertEqual(try LiDARGeometry.packedRows(Data([1,2,99,99,3,4,99,99]),rowBytes:2,height:2,stride:4),Data([1,2,3,4]))
        XCTAssertThrowsError(try LiDARGeometry.packedRows(Data([1,2]),rowBytes:2,height:2,stride:4))
    }
    func testDepthProjectionAxisAndIntrinsicsScale() throws {
        let points = try LiDARGeometry.points(depth:floats([2,2,2,2]),confidence:Data([2,2,2,2]),frame:frame(),pixelStride:1)
        XCTAssertEqual(points,[ProbePoint(-1,1,-2),ProbePoint(0,1,-2),ProbePoint(-1,0,-2),ProbePoint(0,0,-2)])
        var f = frame();f.camera_to_session = [[0,0,1,10],[0,1,0,2],[-1,0,0,-3],[0,0,0,1]]
        XCTAssertEqual(try LiDARGeometry.points(depth:floats([2,2,2,2]),confidence:Data([2,2,2,2]),frame:f,pixelStride:1)[0],ProbePoint(8,3,-2))
    }
    func testInvalidAndLowConfidenceDepthExcluded() throws {
        XCTAssertTrue(try LiDARGeometry.points(depth:floats([.nan,0,5,2]),confidence:Data([2,2,2,0]),frame:frame(),pixelStride:1).isEmpty)
        XCTAssertThrowsError(try LiDARGeometry.points(depth:Data([0]),confidence:Data([2,2,2,2]),frame:frame()))
    }
    func testIndependentSessionsAndWorldMapLeakRejected() throws {
        let a = manifest(),b = manifest();XCTAssertNotEqual(a.session_id,b.session_id)
        var poisoned = a;poisoned.initial_world_map_used = true
        XCTAssertThrowsError(try poisoned.validate())
        poisoned = a;poisoned.route_alignment = "pretend_aligned"
        XCTAssertThrowsError(try poisoned.validate())
    }
    func manifest() -> LiDARScanManifest {
        LiDARScanManifest(role:.query,label:"test",buildingID:"b",regionID:"r",regionName:"room",lighting:"daylight",hardware:"synthetic",appVersion:"test")
    }
    func testDurableFramesChecksumAndIncompleteTrials() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let writer = try LiDARScanWriter(root:temp,manifest:manifest())
        for i in 0..<3 { _ = try writer.append(frame:frame(i),depth:floats([2,2,2,2]),confidence:Data([2,2,2,2]),jpeg:Data([255,216,255,217])) }
        let m = try writer.finish(reason:"test",valid:true)
        XCTAssertEqual(m.state,"complete");try m.validate()
        XCTAssertTrue(FileManager.default.fileExists(atPath:writer.directory.appendingPathComponent("files.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:writer.directory.appendingPathComponent("preview.ply").path))
        XCTAssertThrowsError(try writer.append(frame:frame(3),depth:floats([2,2,2,2]),confidence:Data([2,2,2,2]),jpeg:Data([1])))
        let interrupted = try LiDARScanWriter(root:temp,manifest:manifest())
        XCTAssertEqual(try interrupted.finish(reason:"backgrounded",valid:false).state,"interrupted")
    }
    func testOrderingAndQuotaAreEnforced() throws {
        var m = manifest();m.frames = [frame(1),frame(0)];XCTAssertThrowsError(try m.validate())
        m = manifest();m.frames = (0..<25).map { frame($0) };XCTAssertThrowsError(try m.validate())
    }
}
