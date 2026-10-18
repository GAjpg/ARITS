import XCTest
import simd
@testable import ProbeCore

final class WorldMapTrialTests: XCTestCase {
    func testPortableRoutesRoundTripWithoutAppleArchive() throws {
        for kind in RouteKind.allCases {
            let route = PortableRoute(id: UUID().uuidString, name: "走廊", kind: kind, forward: 2.7, turn: 1.6)
            try route.validate()
            let data = try JSONEncoder().encode(route)
            let decoded = try JSONDecoder().decode(PortableRoute.self, from: data)
            XCTAssertEqual(decoded, route); try decoded.validate()
            XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("ARWorldMap"))
        }
    }
    func testBrokenConnectionsAndChangedCoordinatesAreRejected() {
        var route = PortableRoute(id: UUID().uuidString, name: "走廊", kind: .right, forward: 2, turn: 2)
        route.edges[0].to = "missing"; XCTAssertThrowsError(try route.validate())
        route.edges[0].to = "N1"; route.nodes[1].position.z = -20
        XCTAssertThrowsError(try route.validate())
    }
    func testNormalTrackingAloneCannotRestoreSavedRoute() {
        var gate = WorldMapRestoreGate(startTime: 100)
        for i in 1...30 {
            XCTAssertFalse(gate.observe(now: 100 + Double(i)/30, trackingNormal: true, anchorObserved: false, anchorPresent: true))
        }
        XCTAssertEqual(gate.state, .waiting)
        for i in 31...60 {
            XCTAssertFalse(gate.observe(now: 100 + Double(i)/30, trackingNormal: true, anchorObserved: true, anchorPresent: false))
        }
        XCTAssertEqual(gate.state, .waiting)
    }
    func testContinuousHealthyFramesRequiredAndTrackingLossResetsProgress() {
        var gate = WorldMapRestoreGate(startTime: 100)
        for i in 1...11 { XCTAssertFalse(gate.observe(now: 101 + Double(i)/30, trackingNormal: true, anchorObserved: true, anchorPresent: true)) }
        XCTAssertFalse(gate.observe(now: 102, trackingNormal: false, anchorObserved: true, anchorPresent: true))
        XCTAssertEqual(gate.healthyFrames, 0)
        for i in 0..<60 { XCTAssertFalse(gate.observe(now: 102.1 + Double(i)/30, trackingNormal: true, anchorObserved: true, anchorPresent: true)) }
        XCTAssertTrue(gate.observe(now: 104.11, trackingNormal: true, anchorObserved: true, anchorPresent: true))
        XCTAssertEqual(gate.state, .restored); XCTAssertEqual(gate.restoreSeconds!, 4.11, accuracy: 1e-8)
    }
    func testLongRelocalizationWaitAndQueuedCallbacksCannotReplaceStableFrameTime() {
        var gate = WorldMapRestoreGate(startTime:100)
        // A minute of waiting cannot turn twelve frames into two seconds of stability.
        for i in 0..<12 {
            XCTAssertFalse(gate.observe(now:150+Double(i)*0.01,trackingNormal:true,anchorObserved:true,anchorPresent:true,sampleTime:500+Double(i)/60,position:[0,0,0]))
        }
        XCTAssertLessThan(gate.healthySeconds,0.2)
        XCTAssertEqual(gate.state,.waiting)
    }
    func testPoseCorrectionRestartsStabilityWithoutAcceptingOrAbandoningMap() {
        var gate = WorldMapRestoreGate(startTime:100)
        for i in 0..<59 {
            XCTAssertFalse(gate.observe(now:101+Double(i)/30,trackingNormal:true,anchorObserved:true,anchorPresent:true,sampleTime:501+Double(i)/30,position:[0,0,0]))
        }
        XCTAssertFalse(gate.observe(now:103,trackingNormal:true,anchorObserved:true,anchorPresent:true,sampleTime:503,position:[6.9,0,0]))
        XCTAssertEqual(gate.healthySeconds,0);XCTAssertEqual(gate.state,.waiting)
        for i in 1..<60 {
            XCTAssertFalse(gate.observe(now:103+Double(i)/30,trackingNormal:true,anchorObserved:true,anchorPresent:true,sampleTime:503+Double(i)/30,position:[6.9,0,0]))
        }
        XCTAssertTrue(gate.observe(now:105.01,trackingNormal:true,anchorObserved:true,anchorPresent:true,sampleTime:505.01,position:[6.9,0,0]))
    }
    func testFrameGapAndBadCoordinatesCannotCountAsStableRecovery() {
        var gate = WorldMapRestoreGate(startTime:100)
        for i in 0..<20 { XCTAssertFalse(gate.observe(now:101+Double(i)/30,trackingNormal:true,anchorObserved:true,anchorPresent:true,position:[0,0,0])) }
        XCTAssertFalse(gate.observe(now:103,trackingNormal:true,anchorObserved:true,anchorPresent:true,position:[0,0,0]))
        XCTAssertEqual(gate.healthySeconds,0)
        XCTAssertFalse(gate.observe(now:103.1,trackingNormal:true,anchorObserved:true,anchorPresent:true,position:[.nan,0,0]))
        XCTAssertEqual(gate.healthyFrames,0)
    }
    func testTimeoutAndFailureDoNotBecomeFalseSuccessLater() {
        var gate = WorldMapRestoreGate(startTime: 100)
        XCTAssertFalse(gate.observe(now: 160, trackingNormal: true, anchorObserved: true, anchorPresent: true))
        XCTAssertEqual(gate.state, .timedOut)
        for i in 1...30 { XCTAssertFalse(gate.observe(now: 160 + Double(i), trackingNormal: true, anchorObserved: true, anchorPresent: true)) }
        var cancelled = WorldMapRestoreGate(startTime: 100); cancelled.fail()
        XCTAssertFalse(cancelled.observe(now: 101, trackingNormal: true, anchorObserved: true, anchorPresent: true))
        XCTAssertEqual(cancelled.state, .failed)
    }
    func testRigidMatrixValidationAndRowConversionPreserveTranslation() {
        let rows = [[0.0,0,1,5],[0,1,0,-1],[-1,0,0,3],[0,0,0,1]]
        XCTAssertTrue(RigidMatrix.valid(rows))
        XCTAssertEqual(matrixRows(matrixFromRows(rows)), rows)
        var mirrored = rows; mirrored[1][1] = -1; XCTAssertFalse(RigidMatrix.valid(mirrored))
        var scaled = rows; scaled[0][2] = 2; XCTAssertFalse(RigidMatrix.valid(scaled))
        XCTAssertFalse(RigidMatrix.valid([[1,0],[0,1]]))
    }
    func testEmbeddedMapManifestIsIncludedInRunManifest() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let input = temp.appendingPathComponent("input-world-map")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try Data("source manifest".utf8).write(to: input.appendingPathComponent("files.json"))
        try ProbeIO.makeManifest(at: temp)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: temp.appendingPathComponent("files.json"))) as! [String: Any]
        let entries = object["files"] as! [[String: Any]]
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0]["path"] as? String, "input-world-map/files.json")
    }
}
