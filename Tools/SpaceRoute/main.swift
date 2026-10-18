import Foundation

// space-route: shared Swift core for the workbench preview (see Docs/空间路网接口.md).
//   space-route prepare --map <dir> [--calibration <file>] [--trajectory <file>] --out <grid.json>
//   space-route route --grid <grid.json> --from x,z --to x,z
// Output is JSON on stdout (route) or in --out (prepare); errors are JSON {"status":"error","reason":…} with exit 1.
func fail(_ reason: String) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: ["status": "error", "reason": reason])) ?? Data()
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])); exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func point(_ text: String?) -> (x: Double, z: Double)? {
    guard let parts = text?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2, parts.allSatisfy(\.isFinite) else { return nil }
    return (parts[0], parts[1])
}
let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
do {
    switch args.first {
    case "prepare":
        guard let mapPath = option("--map"), let out = option("--out") else { fail("用法：prepare --map <目录> [--calibration 文件] [--trajectory 文件] --out <grid.json>") }
        let dir = URL(fileURLWithPath: mapPath)
        let (map, points) = try LiDARNavigationArchive.load(dir)
        let hash = try? CampusFiles.hash(dir.appendingPathComponent(map.points_file))
        var calibration: LiDARPassageCalibration?
        if let c = option("--calibration") {
            calibration = try JSONDecoder().decode(LiDARPassageCalibration.self, from: Data(contentsOf: URL(fileURLWithPath: c)))
            try calibration!.validate(mapID: map.map_id)
        } else { calibration = try LiDARPassageCalibration.load(dir, mapID: map.map_id) }
        var trajectory: LiDARWalkedTrajectory?
        let tPath = option("--trajectory").map { URL(fileURLWithPath: $0) } ?? dir.appendingPathComponent(LiDARWalkedTrajectory.fileName)
        if FileManager.default.fileExists(atPath: tPath.path) {
            trajectory = try JSONDecoder().decode(LiDARWalkedTrajectory.self, from: Data(contentsOf: tPath))
            guard trajectory!.map_id == map.map_id else { fail("轨迹文件不属于这张地图") }
        }
        // --param key=value (repeatable): experiment overrides of LiDARSpaceParams, recorded in the output.
        var params = LiDARSpaceParams()
        var overrides = try JSONSerialization.jsonObject(with: encoder.encode(params)) as! [String: Any]
        for (i, a) in args.enumerated() where a == "--param" && i + 1 < args.count {
            let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, overrides[kv[0]] != nil, let v = Double(kv[1]), v.isFinite else { fail("参数无效：\(args[i + 1])") }
            overrides[kv[0]] = v
        }
        params = try JSONDecoder().decode(LiDARSpaceParams.self, from: JSONSerialization.data(withJSONObject: overrides))
        let grid = try LiDARSpaceGrid.build(points: points, params: params, trajectory: trajectory, calibration: calibration)
        try encoder.encode(LiDARSpaceGridFile(grid, mapID: map.map_id, geometrySHA256: hash)).write(to: URL(fileURLWithPath: out), options: .atomic)
        let summary: [String: Any] = ["status": "ok", "map_id": map.map_id, "width": grid.spec.width, "height": grid.spec.height,
            "effective_cells": grid.effective.filter { $0 }.count, "calibrated": grid.calibratedRect != nil, "suggested_paths": grid.paths.count]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: .sortedKeys)); FileHandle.standardOutput.write(Data([10]))
    case "route":
        guard let gridPath = option("--grid"), let from = point(option("--from")), let to = point(option("--to")) else { fail("用法：route --grid <grid.json> --from x,z --to x,z") }
        let file = try JSONDecoder().decode(LiDARSpaceGridFile.self, from: Data(contentsOf: URL(fileURLWithPath: gridPath)))
        let route = LiDARSpacePlanner.route(try file.spaceGrid(), from: from, to: to)
        FileHandle.standardOutput.write(try encoder.encode(route)); FileHandle.standardOutput.write(Data([10]))
    default: fail("命令：prepare 或 route")
    }
} catch { fail(error.localizedDescription) }
