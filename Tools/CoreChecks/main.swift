import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    print("PASS: \(message)")
}

check(ProbeGeometry.route(.right, forward: 2, turn: 3).last == ProbePoint(3,0,-2), "ARKit 坐标右转")
check(ProbeGeometry.route(.left, forward: 2, turn: 3).last == ProbePoint(-3,0,-2), "ARKit 坐标左转")
let identity = [[1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
check(ProbeGeometry.project(world: [1,1,-2], cameraToWorld: identity, fx: 100, fy: 100, cx: 50, cy: 50) == [100,0], "图像光学轴投影")
check(ProbeGeometry.project(world: [0,0,2], cameraToWorld: identity, fx: 100, fy: 100, cx: 50, cy: 50) == nil, "相机后方点拒绝")
var translated = identity; translated[0][3] = 1
check(ProbeGeometry.project(world: [1,0,-2], cameraToWorld: translated, fx: 100, fy: 100, cx: 50, cy: 50) == [50,50], "相机平移变换方向")
let yawed = [[0.0,0,1,0],[0,1,0,0],[-1,0,0,0],[0,0,0,1]]
check(ProbeGeometry.project(world: [-2,1,-1], cameraToWorld: yawed, fx: 100, fy: 100, cx: 50, cy: 50) == [100,0], "旋转后的相机逆变换")
let gate = BoundedTaskGate(capacity: 1)
check(gate.acquire() && !gate.acquire() && gate.rejectedCount == 1, "队列容量与丢弃计数")
gate.release(); check(gate.acquire(), "任务完成后可继续采样"); gate.release()
check(ProbeZip.crc32(Data("123456789".utf8)) == 0xcbf43926, "ZIP CRC32 标准向量")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("ARProbe-check-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let run = root.appendingPathComponent("run-测试")
try FileManager.default.createDirectory(at: run.appendingPathComponent("frames"), withIntermediateDirectories: true)
try Data("test data".utf8).write(to: run.appendingPathComponent("frames/图像.txt"))
try Data(repeating: 42, count: 1_000_000).write(to: run.appendingPathComponent("large.bin"))
let zip = root.appendingPathComponent("run.zip")
try ProbeZip.create(directory: run, destination: zip)
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
process.arguments = ["-t", zip.path]; process.standardOutput = Pipe(); process.standardError = Pipe()
try process.run(); process.waitUntilExit()
check(process.terminationStatus == 0, "ZIP 中文文件名与大文件可被系统解压")
var rejectedInside = false
do { try ProbeZip.create(directory: run, destination: run.appendingPathComponent("bad.zip")) }
catch { rejectedInside = true }
check(rejectedInside, "拒绝递归归档路径")
var stats = IntervalStatistics(); stats.add(seconds: 1.0/60); stats.add(seconds: 0.12)
check(stats.summary["samples"] == 2 && stats.summary["long_frames_over_100ms"] == 1, "性能长帧统计")
stats.add(seconds: 1.2)
check(stats.summary["long_frames_over_100ms"] == 2 && stats.summary["p95_ms"] == 1200, "超过一秒的停顿不会被忽略")
print("核心检查完成；这些结果不能替代 iOS 编译或真机 AR 验证。")
