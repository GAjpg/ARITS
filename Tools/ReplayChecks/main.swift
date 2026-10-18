import Foundation
import CryptoKit

// Desktop replay of the iPhone geometry localizer on raw exported scans.
// Rebuilds the solver inputs the way LiDARGeometryARController does (stride-4 depth
// points, 10 cm last-write voxels capped at 60000; maps resampled to 12 cm / 18000)
// and runs the same pure-Swift solver. It never reads labels or truth.
//
// usage: replay --map <raw scan dir | geometry.f32> --query <raw scan dir> --out result.json
//               [--frames N|all] [--dump-inputs dir] [--max-seconds S] [--free-space]
// --free-space builds report-only free-space evidence from a raw map and attaches it to each
// candidate; it never changes the solver decision.
struct Options {
    var map = "", query = "", out = "", frames: Int? = 12, dump: String?, maxSeconds = 30.0, freeSpace = false
}
func parse() throws -> Options {
    var o = Options(),args = Array(CommandLine.arguments.dropFirst())
    func value() throws -> String { guard !args.isEmpty else { throw LiDARScanError.invalid("missing value") };return args.removeFirst() }
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--map": o.map = try value()
        case "--query": o.query = try value()
        case "--out": o.out = try value()
        case "--frames": let v = try value();o.frames = v == "all" ? nil : Int(v)
        case "--dump-inputs": o.dump = try value()
        case "--max-seconds": o.maxSeconds = Double(try value()) ?? 30
        case "--free-space": o.freeSpace = true
        case let other: throw LiDARScanError.invalid("unknown argument \(other)")
        }
    }
    guard !o.map.isEmpty,!o.query.isEmpty,!o.out.isEmpty else {
        throw LiDARScanError.invalid("usage: replay --map <scan dir|geometry.f32> --query <scan dir> --out result.json [--frames N|all]")
    }
    return o
}
func sha256(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
/// The App's capture accumulation: per-frame stride-4 points, 10 cm voxels, newest point wins.
func accumulate(_ directory: URL, frameLimit: Int?) throws -> (LiDARScanManifest,[ProbePoint],[Int]) {
    let manifestData = try Data(contentsOf:directory.appendingPathComponent("scan.json"))
    let manifest = try JSONDecoder().decode(LiDARScanManifest.self,from:manifestData)
    var cloud = [LiDARVoxelKey:ProbePoint](),used = [Int]()
    for frame in manifest.frames.prefix(frameLimit ?? manifest.frames.count) {
        let folder = directory.appendingPathComponent(frame.folder)
        let depth = try Data(contentsOf:folder.appendingPathComponent("depth.f32"))
        let confidence = try Data(contentsOf:folder.appendingPathComponent("confidence.u8"))
        for point in try LiDARGeometry.points(depth:depth,confidence:confidence,frame:frame,pixelStride:4) {
            let key = LiDARVoxelKey(point,size:0.10)
            if cloud.count < 60_000 || cloud[key] != nil { cloud[key] = point }
        }
        used.append(frame.index)
    }
    return (manifest,Array(cloud.values),used)
}
do {
    let o = try parse()
    let mapURL = URL(fileURLWithPath:o.map),queryURL = URL(fileURLWithPath:o.query)
    var mapPoints: [ProbePoint],mapID: String,freeSpace: LiDARFreeSpaceMap?
    if o.freeSpace && mapURL.pathExtension != "f32" {
        let manifest = try JSONDecoder().decode(LiDARScanManifest.self,from:Data(contentsOf:mapURL.appendingPathComponent("scan.json")))
        var space = LiDARFreeSpaceMap()
        for frame in manifest.frames {
            let folder = mapURL.appendingPathComponent(frame.folder)
            try space.add(frame:frame,depth:Data(contentsOf:folder.appendingPathComponent("depth.f32")),
                          confidence:Data(contentsOf:folder.appendingPathComponent("confidence.u8")))
        }
        freeSpace = space
    }
    if mapURL.pathExtension == "f32" {
        let data = try Data(contentsOf:mapURL);mapPoints = try LiDARPointFile.decode(data,count:data.count/12)
        mapID = mapURL.deletingLastPathComponent().lastPathComponent
    } else {
        let (manifest,points,_) = try accumulate(mapURL,frameLimit:nil)
        mapPoints = LiDARSampling.voxel(points,size:0.12,limit:18_000);mapID = manifest.scan_id
    }
    let mapBytes = try LiDARPointFile.encode(mapPoints)
    let (query,queryPoints,used) = try accumulate(queryURL,frameLimit:o.frames)
    let queryBytes = try LiDARPointFile.encode(LiDARSampling.voxel(queryPoints,size:0.10,limit:60_000))
    if let dump = o.dump {
        let d = URL(fileURLWithPath:dump);try FileManager.default.createDirectory(at:d,withIntermediateDirectories:true)
        try mapBytes.write(to:d.appendingPathComponent("map.f32"));try queryBytes.write(to:d.appendingPathComponent("query.f32"))
    }
    var result = LiDARLocalizer.solve(map:mapPoints,query:queryPoints,sessionID:query.session_id,maxSeconds:o.maxSeconds)
    result.provenance = LiDARResultProvenance(map_id:mapID,geometry_sha256:sha256(mapBytes),query_scan_id:query.scan_id,
        session_id:query.session_id,used_frame_ids:used,app_version:"desktop-replay",device:"mac",recomputable:true,
        query_input_sha256:sha256(queryBytes),
        query_manifest_sha256:sha256(try Data(contentsOf:queryURL.appendingPathComponent("scan.json"))),
        preprocessing_id:"app020_stride4_voxel10_last_cap60000_map12_18000")
    if let freeSpace {
        for i in result.candidates.indices {
            result.candidates[i].free_space = freeSpace.check(query:queryPoints,transform:result.candidates[i].transform_query_to_map)
        }
        result.free_space_available = true;result.free_space_used_in_decision = false
    } else if o.freeSpace { result.free_space_available = false }
    let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    try encoder.encode(result).write(to:URL(fileURLWithPath:o.out),options:.atomic)
    let modes = result.modes?.count ?? 0
    print("\(query.label) | \(result.status) | \((result.decision_reasons ?? []).joined(separator:",")) | modes=\(modes) | \(String(format:"%.2f",result.registration_seconds))s")
} catch { fputs("\(error.localizedDescription)\n",stderr);exit(1) }
