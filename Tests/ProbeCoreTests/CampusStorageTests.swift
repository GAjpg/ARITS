import XCTest
@testable import ProbeCore

final class CampusStorageTests:XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("campus-storage-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);return url
    }
    func testHistoryCleanupPreservesPublishedVersionPreviousVersionAndBackups() throws {
        let docs = try directory();defer { try? FileManager.default.removeItem(at:docs) }
        let library = CampusLibrary(root:docs.appendingPathComponent("CampusNetworks"))
        var graph = try library.save(CampusGraph(name:"测试楼"))
        var paths = [try library.directory(graph.building_id)]
        for _ in 0..<4 { graph = try library.save(graph);paths.append(try library.directory(graph.building_id)) }
        let backup = docs.appendingPathComponent("Exports/important.zip")
        try FileManager.default.createDirectory(at:backup.deletingLastPathComponent(),withIntermediateDirectories:true);try Data([1,2,3]).write(to:backup)
        let partial = paths[0].deletingLastPathComponent().appendingPathComponent(".partial-active")
        try FileManager.default.createDirectory(at:partial,withIntermediateDirectories:true)
        XCTAssertEqual(library.historyCleanupCandidates().count,3)
        XCTAssertEqual(try library.pruneHistory(),3)
        XCTAssertEqual(try library.load(graph.building_id).revision,graph.revision)
        for p in paths.suffix(2) { XCTAssertTrue(FileManager.default.fileExists(atPath:p.path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:backup.path));XCTAssertTrue(FileManager.default.fileExists(atPath:partial.path))
        XCTAssertEqual(try library.pruneHistory(),0)
    }
    func testTrialCleanupKeepsNewestThreeAndNeverTouchesRecordingOrUnreadableTrials() throws {
        let docs = try directory();defer { try? FileManager.default.removeItem(at:docs) }
        let root = docs.appendingPathComponent("NetworkTrials")
        for i in 1...7 {
            let trial = root.appendingPathComponent("trial-\(i)");try FileManager.default.createDirectory(at:trial,withIntermediateDirectories:true)
            let metadata = ["state":i == 7 ? "recording" : "finished","started_utc":String(format:"2026-10-%02dT10:00:00Z",i)]
            try JSONSerialization.data(withJSONObject:metadata).write(to:trial.appendingPathComponent("run.json"))
        }
        let unreadable = root.appendingPathComponent("unknown");try FileManager.default.createDirectory(at:unreadable,withIntermediateDirectories:true)
        XCTAssertEqual(try CampusStorage.pruneTrials(documents:docs),3)
        for i in 4...7 { XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("trial-\(i)").path)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:unreadable.path))
    }
    func testStorageAccountingDoesNotFollowSymlinksOrDeleteUnknownData() throws {
        let docs = try directory();defer { try? FileManager.default.removeItem(at:docs) }
        let file = docs.appendingPathComponent("payload");try Data(repeating:0,count:100).write(to:file)
        try FileManager.default.createSymbolicLink(at:docs.appendingPathComponent("link"),withDestinationURL:file)
        XCTAssertEqual(CampusStorage.bytes(at:docs),100)
        let usage = CampusStorage.usage(documents:docs,library:CampusLibrary(root:docs.appendingPathComponent("CampusNetworks")),cache:nil,temporary:nil)
        XCTAssertEqual(usage.reduce(0) { $0+$1.bytes },100)
    }
}
