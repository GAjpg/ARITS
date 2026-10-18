import XCTest
@testable import ProbeCore

final class RunRecorderGeometryTests:XCTestCase {
    @MainActor func testGeometryLogsResultsAndTwoCoordinateSessionsAreExportable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = try RunRecorder(sessionID:"initial",configuration:["geometry_navigation":true],device:[:],rootDirectory:root,
                                       additionalLogs:["geometry-events.jsonl","camera-poses.jsonl"])
        let failed = expectation(description:"no IO failure");failed.isInverted = true
        recorder.onFailure = { _ in failed.fulfill() }
        for (id,generation) in [("initial",0),("restarted",1)] {
            recorder.beginARSession(id,generation:generation)
            recorder.append("geometry-events.jsonl",["event":"alignment_physically_confirmed","ar_session_id":id,"generation":generation,"attempt_id":id,"candidate_index":1])
            recorder.append("camera-poses.jsonl",["ar_session_id":id,"generation":generation,"timestamp":123.0])
        }
        recorder.writeResult(Data("{\"session_id\":\"restarted\"}".utf8),filename:"localization-query.json")
        let folder:URL = try await withCheckedThrowingContinuation { continuation in
            recorder.finish(statistics:[:]) { continuation.resume(with:$0) }
        }
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("run.json"))) as? [String:Any])
        XCTAssertEqual(metadata["state"] as? String,"finished")
        XCTAssertNil(metadata["error"])
        XCTAssertEqual(metadata["initial_session_id"] as? String,"initial")
        let sessions = try XCTUnwrap(metadata["ar_sessions"] as? [[String:Any]])
        XCTAssertEqual(sessions.compactMap { $0["ar_session_id"] as? String },["initial","restarted"])
        for file in ["geometry-events.jsonl","camera-poses.jsonl"] {
            let lines = try String(contentsOf:folder.appendingPathComponent(file)).split(separator:"\n")
            XCTAssertEqual(lines.count,2)
            let last = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(lines[1].utf8)) as? [String:Any])
            XCTAssertEqual(last["ar_session_id"] as? String,"restarted")
            XCTAssertEqual(last["generation"] as? Int,1)
            // Legacy identifier is explicitly the run's initial session.
            XCTAssertEqual(last["session_id"] as? String,"initial")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath:folder.appendingPathComponent("localization-query.json").path))
        await fulfillment(of:[failed],timeout:0.02)
        // Run logs legitimately include empty legacy streams; unlike campus
        // maps their checksum manifest permits zero-byte entries.
        let manifest = try JSONDecoder().decode(CampusFiles.Manifest.self,from:Data(contentsOf:folder.appendingPathComponent("files.json")))
        for entry in manifest.files {
            let file = folder.appendingPathComponent(entry.path)
            XCTAssertEqual(try Data(contentsOf:file).count,entry.bytes)
            XCTAssertEqual(try CampusFiles.hash(file),entry.sha256)
        }
        XCTAssertTrue(manifest.files.contains { $0.path == "localization-query.json" })
    }
    @MainActor func testPlateEvidenceIsSerializedBeforeFinishAndRejectsTraversal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let recorder = try RunRecorder(sessionID:"s",configuration:[:],device:[:],rootDirectory:root)
        let bad:Result<Void,Error> = await withCheckedContinuation { c in
            recorder.writeLandmarkFiles(["landmarks/../../escape.jpg":Data([1])]) { c.resume(returning:$0) }
        }
        if case .success = bad { XCTFail("accepted traversal") }
        let id = UUID().uuidString,path = "landmarks/\(id)/0.jpg",bytes = Data([1,2,3])
        let published = expectation(description:"evidence published")
        recorder.writeLandmarkFiles([path:bytes]) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            published.fulfill()
        }
        // Queue finish immediately, while publication is still pending.
        let folder:URL = try await withCheckedThrowingContinuation { c in recorder.finish(statistics:[:]) { c.resume(with:$0) } }
        let manifest = try JSONDecoder().decode(CampusFiles.Manifest.self,from:Data(contentsOf:folder.appendingPathComponent("files.json")))
        XCTAssertTrue(manifest.files.contains { $0.path == path && $0.bytes == bytes.count })
        XCTAssertEqual(try Data(contentsOf:folder.appendingPathComponent(path)),bytes)
        await fulfillment(of:[published],timeout:1)
    }
    func testAdditionalLogPathsCannotEscapeRun() {
        XCTAssertThrowsError(try RunRecorder(sessionID:"s",configuration:[:],device:[:],additionalLogs:["../escape.jsonl"]))
    }
}
