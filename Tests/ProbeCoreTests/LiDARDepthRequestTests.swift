import XCTest
@testable import ProbeCore

final class LiDARDepthRequestTests:XCTestCase {
    func testOnlyFreshTrackedDepthSatisfiesRequest() {
        var gate = LiDARDepthRequestGate();gate.begin(now:10)
        XCTAssertEqual(gate.update(frameTimestamp:9.99,now:10.1,hasDepth:true,trackingNormal:true),.waiting)
        XCTAssertEqual(gate.update(frameTimestamp:10.1,now:10.15,hasDepth:false,trackingNormal:true),.waiting)
        XCTAssertEqual(gate.update(frameTimestamp:10.15,now:10.2,hasDepth:true,trackingNormal:false),.waiting)
        XCTAssertEqual(gate.update(frameTimestamp:10.2,now:10.25,hasDepth:true,trackingNormal:true),.ready)
        XCTAssertFalse(gate.waiting)
    }
    func testDeadlineAndCancellationDoNotAcceptLateFrames() {
        var gate = LiDARDepthRequestGate();gate.begin(now:10,timeout:2)
        XCTAssertEqual(gate.update(frameTimestamp:12,now:12,hasDepth:true,trackingNormal:true),.timedOut)
        XCTAssertEqual(gate.update(frameTimestamp:12.1,now:12.1,hasDepth:true,trackingNormal:true),.idle)
        gate.begin(now:20);gate.cancel()
        XCTAssertEqual(gate.update(frameTimestamp:20.1,now:20.1,hasDepth:true,trackingNormal:true),.idle)
    }
    func testStaleFutureOrNonfiniteFramesCannotSatisfyANewRequest() {
        var gate = LiDARDepthRequestGate();gate.begin(now:1)
        XCTAssertEqual(gate.update(frameTimestamp:1.1,now:1.6,hasDepth:true,trackingNormal:true),.waiting)
        XCTAssertEqual(gate.update(frameTimestamp:3,now:1.6,hasDepth:true,trackingNormal:true),.waiting)
        XCTAssertEqual(gate.update(frameTimestamp:.nan,now:1.6,hasDepth:true,trackingNormal:true),.waiting)
        gate.cancel();gate.begin(now:5)
        XCTAssertEqual(gate.update(frameTimestamp:4,now:5.1,hasDepth:true,trackingNormal:true),.waiting)
    }
    func testLogSnapshotIncludesQueuedRecordsWithoutEndingRecorder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = try RunRecorder(sessionID:UUID().uuidString,configuration:[:],device:[:],rootDirectory:root,additionalLogs:["magnetic-heading.jsonl"])
        recorder.append("magnetic-heading.jsonl",["sample":1]);recorder.append("magnetic-heading.jsonl",["sample":2])
        let data = try recorder.snapshotLog("magnetic-heading.jsonl")
        XCTAssertEqual(String(decoding:data,as:UTF8.self).split(separator:"\n").count,2)
        recorder.append("magnetic-heading.jsonl",["sample":3])
        XCTAssertEqual(String(decoding:try recorder.snapshotLog("magnetic-heading.jsonl"),as:UTF8.self).split(separator:"\n").count,3)
        XCTAssertThrowsError(try recorder.snapshotLog("../run.json"))
    }
}
