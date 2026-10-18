import XCTest
@testable import ProbeCore

final class ProbeCoreTests: XCTestCase {
    func testTurnsFollowARKitAxes() {
        XCTAssertEqual(ProbeGeometry.route(.right, forward: 2, turn: 3).last, ProbePoint(3, 0, -2))
        XCTAssertEqual(ProbeGeometry.route(.left, forward: 2, turn: 3).last, ProbePoint(-3, 0, -2))
        XCTAssertEqual(ProbeGeometry.route(.straight, forward: 3, turn: 2).last, ProbePoint(0, 0, -3))
    }
    func testProjectionRespectsCameraPoseAndOpticalYAxis() {
        let identity = [[1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
        XCTAssertEqual(ProbeGeometry.project(world: [0,0,-2], cameraToWorld: identity, fx: 100, fy: 100, cx: 50, cy: 50), [50,50])
        XCTAssertEqual(ProbeGeometry.project(world: [1,1,-2], cameraToWorld: identity, fx: 100, fy: 100, cx: 50, cy: 50), [100,0])
        XCTAssertNil(ProbeGeometry.project(world: [0,0,2], cameraToWorld: identity, fx: 100, fy: 100, cx: 50, cy: 50))
        var translated = identity; translated[0][3] = 1
        XCTAssertEqual(ProbeGeometry.project(world: [1,0,-2], cameraToWorld: translated, fx: 100, fy: 100, cx: 50, cy: 50), [50,50])
    }
    func testGateBoundsWorkInFlight() {
        let gate = BoundedTaskGate(capacity: 1)
        XCTAssertTrue(gate.acquire()); XCTAssertFalse(gate.acquire())
        gate.release(); XCTAssertTrue(gate.acquire()); gate.release()
    }
    func testCRCAndZIPArePortable() throws {
        XCTAssertEqual(ProbeZip.crc32(Data("123456789".utf8)), 0xcbf43926)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let run = root.appendingPathComponent("run-测试")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: run.appendingPathComponent("图像.txt"))
        let zip = root.appendingPathComponent("run.zip")
        try ProbeZip.create(directory: run, destination: zip)
        let data = try Data(contentsOf: zip)
        XCTAssertEqual(Array(data.prefix(4)), [0x50,0x4b,0x03,0x04])
        XCTAssertNotNil(data.range(of: Data("run-测试/图像.txt".utf8)))
        #if os(macOS)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-t", zip.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        #endif
    }
    func testArchiveRejectsOutputInsideInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try ProbeZip.create(directory: root, destination: root.appendingPathComponent("recursive.zip")))
    }
}
