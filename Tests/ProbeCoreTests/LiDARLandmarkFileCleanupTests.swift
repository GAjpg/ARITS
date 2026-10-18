import XCTest
@testable import ProbeCore

final class LiDARLandmarkFileCleanupTests:XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    private func write(_ path:URL,_ bytes:Int) throws {
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(repeating:7,count:bytes).write(to:path)
    }
    func testKeepsReferencedEvidenceAndRemovesOnlyOrphanUUIDDirectories() throws {
        let root = try temporary();defer { try? FileManager.default.removeItem(at:root) }
        let keep = UUID().uuidString,orphan = UUID().uuidString
        let live = root.appendingPathComponent("landmarks/\(keep)/0.jpg")
        let discarded = root.appendingPathComponent("landmarks/\(orphan)")
        let unrelated = root.appendingPathComponent("landmarks/notes/readme.txt")
        try write(live,31);try write(discarded.appendingPathComponent("0.jpg"),20)
        try write(discarded.appendingPathComponent("nested/0.f32"),100);try write(unrelated,9)
        let summary = try LiDARLandmarkFileCleanup.prune(in:root,keepingIDs:[keep.lowercased()])
        XCTAssertEqual(summary.removedIDs,[orphan]);XCTAssertEqual(summary.removedBytes,120)
        XCTAssertEqual(try Data(contentsOf:live),Data(repeating:7,count:31))
        XCTAssertTrue(FileManager.default.fileExists(atPath:unrelated.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:discarded.path))
        XCTAssertEqual(try LiDARLandmarkFileCleanup.prune(in:root,keepingIDs:[keep]).removedBytes,0)
    }
    func testRejectsLinkedEvidenceRootWithoutTouchingItsTarget() throws {
        let root = try temporary(),outside = try temporary()
        defer { try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside) }
        let target = outside.appendingPathComponent("\(UUID().uuidString)/0.jpg");try write(target,27)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("landmarks"),withDestinationURL:outside)
        XCTAssertThrowsError(try LiDARLandmarkFileCleanup.prune(in:root,keepingIDs:[]))
        XCTAssertEqual(try Data(contentsOf:target).count,27)
    }
    func testUnsafeOrphanAbortsBeforeRemovingOtherEvidence() throws {
        let root = try temporary(),outside = try temporary()
        defer { try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside) }
        let safe = root.appendingPathComponent("landmarks/\(UUID().uuidString)/0.jpg")
        let unsafe = root.appendingPathComponent("landmarks/\(UUID().uuidString)/linked.jpg")
        let target = outside.appendingPathComponent("private.jpg")
        try write(safe,11);try write(target,19)
        try FileManager.default.createDirectory(at:unsafe.deletingLastPathComponent(),withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:unsafe,withDestinationURL:target)
        XCTAssertThrowsError(try LiDARLandmarkFileCleanup.prune(in:root,keepingIDs:[]))
        XCTAssertEqual(try Data(contentsOf:safe).count,11);XCTAssertEqual(try Data(contentsOf:target).count,19)
    }
}
