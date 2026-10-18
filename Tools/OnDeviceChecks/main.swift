import Foundation

// The exact same pure-Swift solver used by the iPhone, for reproducible desktop
// regression. Input is little-endian XYZ Float32, not synthetic localization.
do {
    guard CommandLine.arguments.count == 5 else { throw LiDARScanError.invalid("usage: localize map.f32 query.f32 session_id result.json") }
    func read(_ path:String) throws -> [ProbePoint] {
        let data = try Data(contentsOf:URL(fileURLWithPath:path))
        return try LiDARPointFile.decode(data,count:data.count/12)
    }
    let map = try read(CommandLine.arguments[1]),query = try read(CommandLine.arguments[2])
    let result = LiDARLocalizer.solve(map:map,query:query,sessionID:CommandLine.arguments[3],maxSeconds:30)
    let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    try encoder.encode(result).write(to:URL(fileURLWithPath:CommandLine.arguments[4]),options:.atomic)
    print("\(result.status) | \(String(format:"%.3f",result.registration_seconds))s | \(result.candidates.count) candidates | \(result.reason)")
    if let best = result.best { print("overlap=\(best.overlap), structural=\(best.structural_overlap), rmse=\(best.rmse_m), constraint=\(result.structural_constraint_ratio)") }
} catch { fputs("\(error.localizedDescription)\n",stderr);exit(1) }
