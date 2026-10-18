import CryptoKit
import Foundation

public struct LiDARVoxelKey: Hashable {
    let x: Int, y: Int, z: Int
    public init(_ p: ProbePoint, size: Double) {
        x = Int(floor(p.x/size)); y = Int(floor(p.y/size)); z = Int(floor(p.z/size))
    }
    init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
}

public enum LiDARSampling {
    public static func voxel(_ points: [ProbePoint], size: Double = 0.12, limit: Int = 18_000) -> [ProbePoint] {
        guard size > 0, size.isFinite, limit > 0 else { return [] }
        var cells = [LiDARVoxelKey:ProbePoint]()
        for p in points where p.array.allSatisfy({ $0.isFinite && abs($0) < 1000 }) {
            let key = LiDARVoxelKey(p,size:size)
            if let old = cells[key] {
                if p.x < old.x || (p.x == old.x && (p.y < old.y || (p.y == old.y && p.z < old.z))) { cells[key] = p }
            } else { cells[key] = p }
        }
        let sorted = cells.values.sorted { a,b in
            if a.x != b.x { return a.x < b.x };if a.z != b.z { return a.z < b.z };return a.y < b.y
        }
        return sample(sorted,limit:limit)
    }
    public static func sample(_ points: [ProbePoint], limit: Int) -> [ProbePoint] {
        guard limit > 0 else { return [] }
        if points.count <= limit { return points }
        return (0..<limit).map { points[$0*points.count/limit] }
    }
    public static func floorHeight(_ points: [ProbePoint]) -> Double {
        let ys = points.map(\.y).sorted()
        guard !ys.isEmpty else { return 0 }
        // A conservative lower quantile; near-floor observations are requested
        // during capture. It initializes Y only; 3D ICP still estimates Y.
        return ys[min(ys.count-1,max(0,ys.count/40))]
    }
}

public final class LiDARWorkCancellation {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock();cancelled = true;lock.unlock() }
    public var isCancelled: Bool { lock.lock();defer { lock.unlock() };return cancelled }
}

public struct LiDARLocalizationCandidate: Codable {
    public var transform_query_to_map: [[Double]]
    public var overlap: Double
    public var structural_overlap: Double
    public var rmse_m: Double
    public var geometry_score: Double
    public var quality_gate: Bool
    /// Schema v2: the mode hypothesis this candidate belongs to; nil in v1 results.
    public var mode_id: Int?
    /// Free-space evidence for this candidate; nil when not computed (never 0 by default).
    public var free_space: LiDARFreeSpaceCheck?
}

/// Refined ICP solutions clustered by mapped query centroid and yaw. A mode is a
/// hypothesis about one place, not a verified location. Spread is the extent of the
/// tested refined solutions within `mode_delta` of the mode's best score, i.e. how far
/// the search could slide; it is not a calibrated localization error.
public struct LiDARModeHypothesis: Codable, Equatable {
    public var id: Int
    public var best_score: Double
    public var coarse_best_score: Double?
    public var candidate_count: Int
    public var yaw_deg: Double
    public var center_xz: [Double]
    /// nil when fewer than two tested solutions lie within mode_delta (unknown, not zero).
    public var spread_along_axis_m: Double?
    public var axis_xz: [Double]?
    public var yaw_span_deg: Double?
    public var refined: Bool
    public var quality_gate: Bool
}

/// Filled by the caller (App or replay tool). Unknown values stay nil.
public struct LiDARResultProvenance: Codable, Equatable {
    public var map_id: String?
    public var geometry_sha256: String?
    public var query_scan_id: String?
    public var session_id: String?
    public var generation: Int?
    public var attempt_id: String?
    public var used_frame_ids: [Int]?
    public var app_version: String?
    public var device: String?
    /// True only when the exact solver input and the map hash are both preserved.
    public var recomputable: Bool?
    public var query_input_file: String?
    public var query_input_sha256: String?
    public var query_manifest_sha256: String?
    public var preprocessing_id: String?
    public var snapshot_id: String?
    public init(map_id: String? = nil, geometry_sha256: String? = nil, query_scan_id: String? = nil, session_id: String? = nil,
                generation: Int? = nil, attempt_id: String? = nil, used_frame_ids: [Int]? = nil, app_version: String? = nil,
                device: String? = nil, recomputable: Bool? = nil, query_input_file: String? = nil, query_input_sha256: String? = nil,
                query_manifest_sha256: String? = nil, preprocessing_id: String? = nil, snapshot_id: String? = nil) {
        self.map_id = map_id; self.geometry_sha256 = geometry_sha256; self.query_scan_id = query_scan_id
        self.session_id = session_id; self.generation = generation; self.attempt_id = attempt_id
        self.used_frame_ids = used_frame_ids; self.app_version = app_version; self.device = device; self.recomputable = recomputable
        self.query_input_file = query_input_file; self.query_input_sha256 = query_input_sha256
        self.query_manifest_sha256 = query_manifest_sha256; self.preprocessing_id = preprocessing_id; self.snapshot_id = snapshot_id
    }
}

public struct LiDARLocalizationResult: Codable {
    public var algorithm = "gravity_correlative_modes_icp_v2"
    public var session_id: String
    public var status: String
    public var reason: String
    public var candidates: [LiDARLocalizationCandidate]
    public var registration_seconds: Double
    public var map_points: Int, query_points: Int
    public var structural_constraint_ratio: Double
    public var requires_physical_confirmation = true
    public var initial_world_map_used = false
    // Schema v2 fields. All optional so v1 JSON still decodes; nil means "not computed".
    public var schema_version: Int?
    public var search_complete: Bool?
    public var incomplete_reasons: [String]?
    /// Machine-readable codes: below_gate, weak_structure, multiple_modes, opposite_yaw_mode,
    /// same_yaw_rival, along_axis_spread, search_incomplete, insufficient_points, map_too_large, stopped.
    public var decision_reasons: [String]?
    public var coarse_components: Int?
    public var coarse_components_refined: Int?
    public var modes: [LiDARModeHypothesis]?
    public var parameters: [String: Double]?
    public var parameters_hash: String?
    public var stage_seconds: [String: Double]?
    public var provenance: LiDARResultProvenance?
    /// Whether free-space evidence was computed, and whether it influenced the decision.
    public var free_space_available: Bool?
    public var free_space_used_in_decision: Bool?
    /// Present when the search was restricted; every candidate and diagnostic is scoped to it.
    public var search_scope: LiDARSearchScope?
    /// [centre, half width] in degrees when the yaw search was restricted by the compass.
    public var yaw_prior_deg: [Double]?
    /// Plate search: one entry per planned window, "<source>:<node or landmark>:<status>:<complete|incomplete|not_searched>".
    public var plate_windows: [String]?
    public var best: LiDARLocalizationCandidate? { candidates.first }
}

/// Experimental heuristics, recorded in every result. They are not validated defaults.
public struct LiDARLocalizerParameters: Codable, Equatable {
    public var map_voxel_m = 0.12, map_limit = 18_000
    public var query_voxel_m = 0.12, query_limit = 3_000
    public var coarse_step_m = 0.7, coarse_yaw_deg = 15.0, coarse_floor = 0.18
    /// Cells scoring >= component_rho * best coarse score form coarse components.
    public var component_rho = 0.75
    /// An unrefined component at >= competitive_rho * best coarse score makes the search incomplete.
    public var competitive_rho = 0.90
    /// Every component's best cell is seeded first (up to max_components), then the best
    /// remaining cells above coarse_floor, kept seed_separation apart, up to max_seeds.
    public var max_components = 8, max_seeds = 40
    public var seed_separation_m = 0.8, seed_separation_deg = 20.0
    public var mode_link_m = 1.2, mode_link_deg = 20.0, mode_delta = 0.03
    public var spread_limit_m = 0.5, competitive_margin = 0.10, opposite_yaw_deg = 150.0
    public var gate_overlap = 0.50, gate_structural = 0.45, gate_rmse_m = 0.13, gate_ratio = 0.012, hit_m = 0.18
    public init() {}
    public var dictionary: [String: Double] {
        ["map_voxel_m":map_voxel_m,"map_limit":Double(map_limit),"query_voxel_m":query_voxel_m,"query_limit":Double(query_limit),
         "coarse_step_m":coarse_step_m,"coarse_yaw_deg":coarse_yaw_deg,"coarse_floor":coarse_floor,
         "component_rho":component_rho,"competitive_rho":competitive_rho,"max_components":Double(max_components),
         "max_seeds":Double(max_seeds),
         "seed_separation_m":seed_separation_m,"seed_separation_deg":seed_separation_deg,
         "mode_link_m":mode_link_m,"mode_link_deg":mode_link_deg,"mode_delta":mode_delta,
         "spread_limit_m":spread_limit_m,"competitive_margin":competitive_margin,"opposite_yaw_deg":opposite_yaw_deg,
         "gate_overlap":gate_overlap,"gate_structural":gate_structural,"gate_rmse_m":gate_rmse_m,"gate_ratio":gate_ratio,"hit_m":hit_m]
    }
    public var hash: String {
        let text = dictionary.keys.sorted().map { "\($0)=\(String(format:"%.6g",dictionary[$0]!))" }.joined(separator:";")
        return SHA256.hash(data:Data(text.utf8)).map { String(format:"%02x",$0) }.joined()
    }
}

/// Self-contained CPU baseline for iOS and macOS, with no Python, network or
/// ARWorldMap dependency. Gravity from ARKit reduces registration to yaw + XYZ.
/// Scores describe geometric fit, never a probability of correct localization.
public enum LiDARLocalizer {
    private struct Pose {
        var yaw: Double, x: Double, y: Double, z: Double, score: Double = 0
        var matrix: [[Double]] {
            let c = cos(yaw),s = sin(yaw)
            return [[c,0,s,x],[0,1,0,y],[-s,0,c,z],[0,0,0,1]]
        }
        func apply(_ p: ProbePoint) -> ProbePoint {
            let c = cos(yaw),s = sin(yaw)
            return ProbePoint(c*p.x+s*p.z+x,p.y+y,-s*p.x+c*p.z+z)
        }
    }
    private struct Field {
        let step = 0.20
        var values = [Int64:Double]()
        static func key(_ x: Int,_ z: Int) -> Int64 { (Int64(x)<<32) ^ Int64(UInt32(truncatingIfNeeded:z)) }
        init(_ points: [ProbePoint]) {
            let cells = Set(points.map { Self.key(Int(floor($0.x/step)),Int(floor($0.z/step))) })
            for key in cells {
                let x = Int(Int32(truncatingIfNeeded:key>>32)),z = Int(Int32(truncatingIfNeeded:key))
                for dx in -3...3 { for dz in -3...3 {
                    let score = max(0,1-hypot(Double(dx),Double(dz))/3.8)
                    let k = Self.key(x+dx,z+dz)
                    if score > (values[k] ?? 0) { values[k] = score }
                } }
            }
        }
        func score(_ rotated: [ProbePoint], x: Double, z: Double) -> Double {
            var total = 0.0
            for p in rotated {
                total += values[Self.key(Int(floor((p.x+x)/step)),Int(floor((p.z+z)/step)))] ?? 0
            }
            return total/Double(max(1,rotated.count))
        }
    }
    /// The tree owns flat arrays; recursive search has a bounded depth.
    private final class Tree {
        struct Node { var p: ProbePoint; var axis: Int; var left: Int; var right: Int }
        var nodes = [Node]()
        var root = -1
        init(_ points: [ProbePoint]) { nodes.reserveCapacity(points.count);root = build(points,depth:0) }
        func coordinate(_ p: ProbePoint,_ axis: Int) -> Double { axis == 0 ? p.x : axis == 1 ? p.y : p.z }
        func build(_ points: [ProbePoint],depth: Int) -> Int {
            guard !points.isEmpty else { return -1 }
            let axis = depth%3,sorted = points.sorted { coordinate($0,axis) < coordinate($1,axis) },mid = sorted.count/2
            let index = nodes.count;nodes.append(Node(p:sorted[mid],axis:axis,left:-1,right:-1))
            let left = build(Array(sorted[..<mid]),depth:depth+1)
            let right = build(Array(sorted[(mid+1)...]),depth:depth+1)
            nodes[index].left = left;nodes[index].right = right;return index
        }
        func nearest(_ p: ProbePoint, maxDistance: Double) -> (ProbePoint,Double)? {
            var best = maxDistance*maxDistance,index = -1
            func visit(_ n: Int) {
                guard n >= 0 else { return }
                let node = nodes[n],dx = p.x-node.p.x,dy = p.y-node.p.y,dz = p.z-node.p.z
                let distance = dx*dx+dy*dy+dz*dz
                if distance < best { best = distance;index = n }
                let d = coordinate(p,node.axis)-coordinate(node.p,node.axis)
                visit(d < 0 ? node.left : node.right)
                if d*d < best { visit(d < 0 ? node.right : node.left) }
            }
            visit(root)
            return index < 0 ? nil : (nodes[index].p,best)
        }
        func nearby(_ p: ProbePoint,radius: Double,limit: Int = 32) -> [ProbePoint] {
            var found = [ProbePoint]();let r2 = radius*radius
            func visit(_ n: Int) {
                guard n >= 0, found.count < limit else { return }
                let node = nodes[n],dx = p.x-node.p.x,dy = p.y-node.p.y,dz = p.z-node.p.z
                if dx*dx+dy*dy+dz*dz < r2 { found.append(node.p) }
                let d = coordinate(p,node.axis)-coordinate(node.p,node.axis)
                visit(d < 0 ? node.left : node.right)
                if d*d < r2 { visit(d < 0 ? node.right : node.left) }
            }
            visit(root);return found
        }
    }
    private struct Solution { var pose: Pose; var component: Int; var coarse: Double; var candidate: LiDARLocalizationCandidate; var mapped: ProbePoint }
    private static func yawDelta(_ a: Double,_ b: Double) -> Double { abs(atan2(sin(a-b),cos(a-b))) }
    private static func structureRatio(_ points: [ProbePoint]) -> Double {
        guard points.count >= 60 else { return 0 }
        let tree = Tree(points)
        var xx = 0.0,xz = 0.0,zz = 0.0,count = 0.0
        for p in LiDARSampling.sample(points,limit:140) {
            let nearby = tree.nearby(p,radius:0.45,limit:32)
            guard nearby.count >= 5 else { continue }
            let n = Double(nearby.count),mx = nearby.reduce(0) { $0+$1.x }/n,mz = nearby.reduce(0) { $0+$1.z }/n
            let a = nearby.reduce(0) { $0+pow($1.x-mx,2) },b = nearby.reduce(0) { $0+($1.x-mx)*($1.z-mz) },d = nearby.reduce(0) { $0+pow($1.z-mz,2) }
            let spread = hypot(a-d,2*b),large = (a+d+spread)/2,small = (a+d-spread)/2
            guard large > 0.002,small < large*0.35 else { continue }
            let theta = 0.5*atan2(2*b,a-d),nx = -sin(theta),nz = cos(theta)
            xx += nx*nx;xz += nx*nz;zz += nz*nz;count += 1
        }
        guard count >= 8 else { return 0 }
        let spread = hypot(xx-zz,2*xz)
        return max(0,(xx+zz-spread)/max(1e-9,xx+zz+spread))
    }
    public static func solve(map rawMap: [ProbePoint], query rawQuery: [ProbePoint], sessionID: String,
                             maxSeconds: Double = 15, cancellation: LiDARWorkCancellation = LiDARWorkCancellation(),
                             parameters k: LiDARLocalizerParameters = LiDARLocalizerParameters(),
                             window: LiDARSearchWindow? = nil, yawPrior: (center: Double, halfWidth: Double)? = nil) -> LiDARLocalizationResult {
        let start = ProcessInfo.processInfo.systemUptime
        var stageStart = start,stages = [String:Double]()
        func lap(_ name: String) { let now = ProcessInfo.processInfo.systemUptime;stages[name] = now-stageStart;stageStart = now }
        let map = LiDARSampling.voxel(rawMap,size:k.map_voxel_m,limit:k.map_limit)
        let query = LiDARSampling.voxel(rawQuery,size:k.query_voxel_m,limit:k.query_limit)
        var ratio = 0.0,componentCount: Int?,refinedCount: Int?,modes: [LiDARModeHypothesis]?,complete: Bool? = nil,incomplete = [String]()
        var scope = window.map { w in LiDARSearchScope(kind:"position_window",center_node_id:w.centerNodeID,center_xz:[w.center.x,w.center.z],
            candidate_radius_m:w.radius,support_radius_m:w.supportRadius,bounds_xz:nil,reference_camera_xz:[w.referenceCamera.x,w.referenceCamera.z],
            source:w.source,tier:w.tier,tiers_tried:w.tier+1) }
        func stopped() -> Bool { cancellation.isCancelled || ProcessInfo.processInfo.systemUptime-start > maxSeconds }
        func result(_ status: String,_ reason: String,_ candidates: [LiDARLocalizationCandidate] = [],codes: [String]) -> LiDARLocalizationResult {
            var r = LiDARLocalizationResult(session_id:sessionID,status:status,reason:reason,candidates:candidates,
                registration_seconds:ProcessInfo.processInfo.systemUptime-start,map_points:map.count,query_points:query.count,structural_constraint_ratio:ratio)
            r.schema_version = 2;r.search_complete = complete;r.incomplete_reasons = incomplete.isEmpty ? nil : incomplete
            r.decision_reasons = codes;r.coarse_components = componentCount;r.coarse_components_refined = refinedCount;r.modes = modes
            r.parameters = k.dictionary;r.parameters_hash = k.hash;r.stage_seconds = stages
            r.search_scope = scope
            r.yaw_prior_deg = yawPrior.map { [$0.center, $0.halfWidth] }
            return r
        }
        func halted(_ message: String) -> LiDARLocalizationResult {
            complete = false;incomplete.append(cancellation.isCancelled ? "cancelled" : "timeout")
            return result(cancellation.isCancelled ? "cancelled" : "timeout",message,codes:["stopped"])
        }
        guard map.count >= 150,query.count >= 120 else { return result("rejected","有效点云不足，请扫描近处墙角、门框和地面",codes:["insufficient_points"]) }
        let mf = LiDARSampling.floorHeight(map),qf = LiDARSampling.floorHeight(query)
        let ms = map.filter { $0.y > mf+0.30 && $0.y < mf+2.6 }
        let qs = query.filter { $0.y > qf+0.30 && $0.y < qf+2.6 }
        guard ms.count >= 80,qs.count >= 60 else { return result("rejected","缺少地面以上的结构，请观察墙角和门框",codes:["insufficient_points"]) }
        ratio = structureRatio(qs)
        let field = Field(ms),samples = LiDARSampling.sample(qs,limit:160)
        let center = ProbePoint(samples.reduce(0) { $0+$1.x }/Double(samples.count),0,samples.reduce(0) { $0+$1.z }/Double(samples.count))
        let centroid = ProbePoint(qs.reduce(0) { $0+$1.x }/Double(qs.count),qs.reduce(0) { $0+$1.y }/Double(qs.count),qs.reduce(0) { $0+$1.z }/Double(qs.count))
        var minX = ms.map(\.x).min()!-0.8,maxX = ms.map(\.x).max()!+0.8
        var minZ = ms.map(\.z).min()!-0.8,maxZ = ms.map(\.z).max()!+0.8
        // The coarse grid enumerates map positions of the query sample center. With a window,
        // only centers that can put the reference camera inside the window are searched.
        let referenceReach = window.map { w in hypot(w.referenceCamera.x-center.x,w.referenceCamera.z-center.z) } ?? 0
        if let w = window {
            let reach = w.radius+referenceReach+k.coarse_step_m
            minX = max(minX,w.center.x-reach);maxX = min(maxX,w.center.x+reach)
            minZ = max(minZ,w.center.z-reach);maxZ = min(maxZ,w.center.z+reach)
            scope?.bounds_xz = [minX,maxX,minZ,maxZ]
            guard minX < maxX,minZ < maxZ else { return result("rejected","起点附近没有已采集的结构，请确认起点或扩大范围",codes:["no_support_in_window"]) }
        }
        // A window already bounds the search; only an unbounded search is limited (solveGlobal tiles larger maps).
        guard window != nil || (maxX-minX <= 45 && maxZ-minZ <= 45) else { return result("rejected","地图大于约45米，请选择起点或使用分块全图搜索",codes:["map_too_large"]) }
        func inWindow(_ pose: Pose) -> Bool {
            guard let w = window else { return true }
            let c = pose.apply(w.referenceCamera);return hypot(c.x-w.center.x,c.z-w.center.z) <= w.radius
        }
        lap("prepare")

        // 1. Full coarse score field over (yaw, x, z). Kept as a dense grid so modes are
        //    found by connectivity instead of a fixed-size candidate pool.
        let nx = Int(((maxX-minX)/k.coarse_step_m).rounded(.down))+1,nz = Int(((maxZ-minZ)/k.coarse_step_m).rounded(.down))+1
        let ny = max(1,Int((360/k.coarse_yaw_deg).rounded()))
        var grid = [Float](repeating:0,count:ny*nx*nz)
        func index(_ yi: Int,_ xi: Int,_ zi: Int) -> Int { (yi*nx+xi)*nz+zi }
        func cellPose(_ i: Int) -> Pose {
            let yi = i/(nx*nz),xi = (i/nz)%nx,zi = i%nz
            let yaw = Double(yi)*2*Double.pi/Double(ny),c = cos(yaw),s = sin(yaw)
            let x = minX+Double(xi)*k.coarse_step_m,z = minZ+Double(zi)*k.coarse_step_m
            return Pose(yaw:yaw,x:x-c*center.x-s*center.z,y:mf-qf,z:z+s*center.x-c*center.z,score:Double(grid[i]))
        }
        func outsidePrior(_ yaw: Double) -> Bool {
            guard let p = yawPrior else { return false }
            return abs(LiDARMagnetic.wrap(yaw*180/Double.pi-p.center)) > p.halfWidth+k.coarse_yaw_deg/2
        }
        for yi in 0..<ny {
            if stopped() { return halted("搜索已停止，请缩小地图或换观察方向") }
            let yaw = Double(yi)*2*Double.pi/Double(ny),c = cos(yaw),s = sin(yaw)
            if outsidePrior(yaw) { continue }
            let rotated = samples.map { ProbePoint(c*($0.x-center.x)+s*($0.z-center.z),0,-s*($0.x-center.x)+c*($0.z-center.z)) }
            for xi in 0..<nx { for zi in 0..<nz {
                if window != nil && !inWindow(cellPose(index(yi,xi,zi))) { continue }
                grid[index(yi,xi,zi)] = Float(field.score(rotated,x:minX+Double(xi)*k.coarse_step_m,z:minZ+Double(zi)*k.coarse_step_m))
            } }
        }
        lap("coarse")
        let coarseBest = Double(grid.max() ?? 0)
        guard coarseBest > k.coarse_floor else {
            complete = true;componentCount = 0;refinedCount = 0;modes = []
            return result("rejected","几何对应不足，请换方向重试",codes:["below_gate"])
        }

        // 2. Connected components of the thresholded field (yaw wraps around).
        let threshold = Float(max(k.coarse_floor,k.component_rho*coarseBest))
        var label = [Int32](repeating:-1,count:grid.count)
        var components = [[Int]]()
        for i in grid.indices where grid[i] >= threshold && label[i] < 0 {
            let id = Int32(components.count);var members = [i],queue = [i];label[i] = id
            while let cell = queue.popLast() {
                let yi = cell/(nx*nz),xi = (cell/nz)%nx,zi = cell%nz
                for dy in -1...1 { for dx in -1...1 { for dz in -1...1 {
                    let y2 = (yi+dy+ny)%ny,x2 = xi+dx,z2 = zi+dz
                    guard x2 >= 0,x2 < nx,z2 >= 0,z2 < nz else { continue }
                    let j = index(y2,x2,z2)
                    if label[j] < 0 && grid[j] >= threshold { label[j] = id;members.append(j);queue.append(j) }
                } } }
            }
            components.append(members.sorted { grid[$0] > grid[$1] })
        }
        components.sort { grid[$0[0]] > grid[$1[0]] }
        componentCount = components.count
        lap("components")

        // 3. Separated seeds inside each refined component, local hill climb, then ICP.
        func mapPosition(_ i: Int) -> (Double,Double,Double) {
            let yi = i/(nx*nz),xi = (i/nz)%nx,zi = i%nz
            return (Double(yi)*360/Double(ny),minX+Double(xi)*k.coarse_step_m,minZ+Double(zi)*k.coarse_step_m)
        }
        func localRefine(_ seed: Pose) -> Pose {
            var best = seed
            for (step,angle,span) in [(0.35,5.0,3),(0.16,2.0,2)] {
                let base = best
                for offset in -span...span {
                    let yaw = base.yaw+Double(offset)*angle*Double.pi/180,c = cos(yaw),s = sin(yaw)
                    let rotated = samples.map { ProbePoint(c*$0.x+s*$0.z,0,-s*$0.x+c*$0.z) }
                    for dx in -2...2 { for dz in -2...2 {
                        let x = base.x+Double(dx)*step,z = base.z+Double(dz)*step
                        let score = field.score(rotated,x:x,z:z)
                        if score > best.score { best = Pose(yaw:yaw,x:x,y:base.y,z:z,score:score) }
                    } }
                }
            }
            return best
        }
        let tree = Tree(map),fit = LiDARSampling.sample(query,limit:1_000)
        func evaluate(_ pose: Pose) -> LiDARLocalizationCandidate {
            var hits = 0,structuralHits = 0,structuralCount = 0,squared = 0.0
            for point in query {
                let structural = point.y > qf+0.30 && point.y < qf+2.6
                if structural { structuralCount += 1 }
                if let (_,d2) = tree.nearest(pose.apply(point),maxDistance:k.hit_m) {
                    hits += 1;squared += d2;if structural { structuralHits += 1 }
                }
            }
            let overlap = Double(hits)/Double(query.count),structural = Double(structuralHits)/Double(max(1,structuralCount))
            let rmse = hits > 0 ? sqrt(squared/Double(hits)) : 1
            let quality = overlap >= k.gate_overlap && structural >= k.gate_structural && rmse <= k.gate_rmse_m && ratio >= k.gate_ratio
            return LiDARLocalizationCandidate(transform_query_to_map:pose.matrix,overlap:overlap,structural_overlap:structural,
                rmse_m:rmse,geometry_score:overlap*0.45+structural*0.55-rmse*0.5,quality_gate:quality)
        }
        // Seeds: each component's best cell first, then a separated sweep of the whole field,
        // so a giant low-saddle component cannot starve the search.
        var seeds = [Int]()
        func separated(_ cell: Int) -> Bool {
            let (yaw,x,z) = mapPosition(cell)
            return seeds.allSatisfy { other in
                let (yaw2,x2,z2) = mapPosition(other)
                return hypot(x-x2,z-z2) > k.seed_separation_m || abs(atan2(sin((yaw-yaw2)*Double.pi/180),cos((yaw-yaw2)*Double.pi/180)))*180/Double.pi > k.seed_separation_deg
            }
        }
        for members in components.prefix(k.max_components) where seeds.count < k.max_seeds { seeds.append(members[0]) }
        let refined = seeds.count
        let sweep = grid.indices.filter { Double(grid[$0]) > k.coarse_floor }.sorted { grid[$0] > grid[$1] }
        for cell in sweep {
            guard seeds.count < k.max_seeds else { break }
            if separated(cell) { seeds.append(cell) }
        }
        var solutions = [Solution]()
        for cell in seeds {
            if stopped() { refinedCount = refined;return halted("精配准已停止，请重新定位") }
            let pose = refine(localRefine(cellPose(cell)),points:fit,tree:tree,stop:stopped)
            guard inWindow(pose) else { continue }
            let cid = Int(label[cell])
            let solution = Solution(pose:pose,component:cid,coarse:Double(grid[cell]),candidate:evaluate(pose),mapped:pose.apply(centroid))
            if let same = solutions.firstIndex(where: { hypot($0.mapped.x-solution.mapped.x,$0.mapped.z-solution.mapped.z) < 0.05 && yawDelta($0.pose.yaw,pose.yaw) < 0.01 }) {
                if solution.candidate.geometry_score > solutions[same].candidate.geometry_score { solutions[same] = solution }
            } else { solutions.append(solution) }
        }
        refinedCount = refined
        if stopped() { return halted("计算超时，未采用部分结果") }
        let competitiveUnrefined = components.dropFirst(refined).contains { Double(grid[$0[0]]) >= k.competitive_rho*coarseBest }
        if competitiveUnrefined { incomplete.append("unrefined_competitive_component") }
        complete = incomplete.isEmpty
        lap("refine_icp")

        // 4. Mode hypotheses: single-linkage over mapped query centroid and yaw.
        var parent = Array(solutions.indices)
        func find(_ i: Int) -> Int { var i = i;while parent[i] != i { parent[i] = parent[parent[i]];i = parent[i] };return i }
        for i in solutions.indices { for j in solutions.indices where j > i {
            let a = solutions[i],b = solutions[j]
            if hypot(a.mapped.x-b.mapped.x,a.mapped.z-b.mapped.z) < k.mode_link_m && yawDelta(a.pose.yaw,b.pose.yaw)*180/Double.pi < k.mode_link_deg {
                parent[find(i)] = find(j)
            }
        } }
        var groups = [Int:[Int]]()
        for i in solutions.indices { groups[find(i),default:[]].append(i) }
        let ordered = groups.values.map { $0.sorted { solutions[$0].candidate.geometry_score > solutions[$1].candidate.geometry_score } }
            .sorted { a,b in
                let x = solutions[a[0]].candidate,y = solutions[b[0]].candidate
                return x.quality_gate != y.quality_gate ? x.quality_gate : x.geometry_score > y.geometry_score
            }
        var modeOf = [Int:Int](),built = [LiDARModeHypothesis]()
        for (id,members) in ordered.enumerated() {
            for m in members { modeOf[m] = id }
            let top = solutions[members[0]]
            let close = members.filter { solutions[$0].candidate.geometry_score >= top.candidate.geometry_score-k.mode_delta }
            var spread: Double?,axis: [Double]?,yawSpan: Double?
            if close.count >= 2 {
                let xs = close.map { solutions[$0].mapped.x },zs = close.map { solutions[$0].mapped.z },n = Double(close.count)
                let mx = xs.reduce(0,+)/n,mz = zs.reduce(0,+)/n
                let a = xs.reduce(0) { $0+pow($1-mx,2) },b = zip(xs,zs).reduce(0) { $0+($1.0-mx)*($1.1-mz) },d = zs.reduce(0) { $0+pow($1-mz,2) }
                let theta = 0.5*atan2(2*b,a-d),ux = cos(theta),uz = sin(theta)
                let projections = zip(xs,zs).map { ($0-mx)*ux+($1-mz)*uz }
                spread = (projections.max() ?? 0)-(projections.min() ?? 0);axis = [ux,uz]
                yawSpan = close.map { yawDelta(solutions[$0].pose.yaw,top.pose.yaw)*180/Double.pi }.max()
            }
            built.append(LiDARModeHypothesis(id:id,best_score:top.candidate.geometry_score,coarse_best_score:members.map { solutions[$0].coarse }.max(),
                candidate_count:members.count,yaw_deg:atan2(sin(top.pose.yaw),cos(top.pose.yaw))*180/Double.pi,
                center_xz:[top.mapped.x,top.mapped.z],spread_along_axis_m:spread,axis_xz:axis,yaw_span_deg:yawSpan,refined:true,
                quality_gate:members.contains { solutions[$0].candidate.quality_gate }))
        }
        modes = built

        // 5. Up to five candidates: the best of each mode first, so alternatives stay visible.
        func tagged(_ i: Int) -> LiDARLocalizationCandidate { var c = solutions[i].candidate;c.mode_id = modeOf[i];return c }
        var picked = ordered.prefix(5).map { $0[0] }
        let rest = solutions.indices.filter { !picked.contains($0) }.sorted { a,b in
            let x = solutions[a].candidate,y = solutions[b].candidate
            return x.quality_gate != y.quality_gate ? x.quality_gate : x.geometry_score > y.geometry_score
        }
        picked += rest.prefix(max(0,5-picked.count))
        var candidates = picked.map(tagged)
        candidates.sort { a,b in a.quality_gate != b.quality_gate ? a.quality_gate : a.geometry_score > b.geometry_score }
        lap("evaluate")

        guard let best = candidates.first,best.quality_gate,let bestMode = best.mode_id else {
            var codes = ["below_gate"];if ratio < k.gate_ratio { codes.append("weak_structure") }
            if !complete! { codes.append("search_incomplete") }
            return result("rejected",ratio < k.gate_ratio ? "沿走廊方向约束不足，请多观察转角、门框或端墙" : "几何对应不足，请换方向重试",candidates,codes:codes)
        }
        var codes = [String]()
        let rivals = built.filter { $0.id != bestMode && $0.quality_gate && $0.best_score >= best.geometry_score-k.competitive_margin }
        if !rivals.isEmpty { codes.append("multiple_modes") }
        let bestYaw = built[bestMode].yaw_deg
        func yawGap(_ m: LiDARModeHypothesis) -> Double { abs(atan2(sin((m.yaw_deg-bestYaw)*Double.pi/180),cos((m.yaw_deg-bestYaw)*Double.pi/180)))*180/Double.pi }
        if rivals.contains(where: { yawGap($0) >= k.opposite_yaw_deg }) { codes.append("opposite_yaw_mode") }
        // Same heading, different place: sliding along a corridor or repeated structure.
        if rivals.contains(where: { yawGap($0) <= k.mode_link_deg }) { codes.append("same_yaw_rival") }
        let slide = built[bestMode].spread_along_axis_m
        if let slide,slide >= k.spread_limit_m { codes.append("along_axis_spread") }
        if !complete! { codes.append("search_incomplete") }
        guard !codes.isEmpty else {
            return result("candidate_requires_review","几何候选已生成；重叠率不是定位正确概率，请现场核对路线",candidates,codes:[])
        }
        var notes = [String]()
        if codes.contains("multiple_modes") {
            var kinds = [String]()
            if codes.contains("same_yaw_rival") { kinds.append("同一朝向的不同位置（可能沿走廊前后滑动或结构重复）") }
            if codes.contains("opposite_yaw_mode") { kinds.append("方向相反的候选") }
            notes.append(kinds.isEmpty ? "存在多个相似位置" : "存在多个相似位置，包括"+kinds.joined(separator:"和"))
        }
        if let slide,codes.contains("along_axis_spread") { notes.append(String(format:"沿走廊约 %.1f 米范围内无法确定前后位置，请看向端墙、门牌或转角",slide)) }
        if codes.contains("search_incomplete") { notes.append("搜索未完整完成") }
        return result("ambiguous",notes.joined(separator:"；")+"；不能确认唯一位置",candidates,codes:codes)
    }
    private static func refine(_ initial: Pose,points: [ProbePoint],tree: Tree,stop: () -> Bool) -> Pose {
        var pose = initial
        for iteration in 0..<35 {
            if stop() { break }
            let radius = iteration < 8 ? 0.60 : iteration < 20 ? 0.35 : 0.22
            var pairs = [(ProbePoint,ProbePoint,Double)]()
            for p in points {
                let a = pose.apply(p)
                if let (b,d2) = tree.nearest(a,maxDistance:radius) { pairs.append((a,b,d2)) }
            }
            guard pairs.count >= 40 else { break }
            pairs.sort { $0.2 < $1.2 };pairs = Array(pairs.prefix(max(40,pairs.count*4/5)))
            let n = Double(pairs.count)
            let a = pairs.reduce(ProbePoint(0,0,0)) { ProbePoint($0.x+$1.0.x/n,$0.y+$1.0.y/n,$0.z+$1.0.z/n) }
            let b = pairs.reduce(ProbePoint(0,0,0)) { ProbePoint($0.x+$1.1.x/n,$0.y+$1.1.y/n,$0.z+$1.1.z/n) }
            var dot = 0.0,cross = 0.0
            for (p,q,_) in pairs {
                dot += (p.x-a.x)*(q.x-b.x)+(p.z-a.z)*(q.z-b.z)
                cross += (p.z-a.z)*(q.x-b.x)-(p.x-a.x)*(q.z-b.z)
            }
            let yaw = atan2(cross,dot),c = cos(yaw),s = sin(yaw)
            let tx = b.x-c*a.x-s*a.z,tz = b.z+s*a.x-c*a.z,ty = b.y-a.y
            pose = Pose(yaw:pose.yaw+yaw,x:c*pose.x+s*pose.z+tx,y:pose.y+ty,z:-s*pose.x+c*pose.z+tz,score:pose.score)
            if abs(yaw) < 0.00005 && hypot(tx,tz) < 0.0002 && abs(ty) < 0.0002 { break }
        }
        return pose
    }
}

// MARK: - Same-session consistency (diagnostic only)

/// A candidate the user explicitly confirmed. Manual confirmation is a reference, not ground truth.
public struct LiDARConfirmedAlignment: Codable, Equatable {
    public var map_id: String
    public var geometry_sha256: String?
    public var session_id: String
    public var generation: Int
    public var attempt_id: String?
    public var candidate_index: Int?
    /// map-from-session transform of the confirmed candidate.
    public var transform: [[Double]]
    public init(map_id: String, geometry_sha256: String?, session_id: String, generation: Int,
                attempt_id: String?, candidate_index: Int?, transform: [[Double]]) {
        self.map_id = map_id; self.geometry_sha256 = geometry_sha256; self.session_id = session_id
        self.generation = generation; self.attempt_id = attempt_id; self.candidate_index = candidate_index; self.transform = transform
    }
}

public struct LiDARConsistencyReport: Codable, Equatable {
    public var available: Bool
    /// ok, no_reference, different_map, different_geometry, different_session, different_generation,
    /// invalid_transform, origin_mapping_only (no camera pose given).
    public var reason: String
    public var yaw_delta_deg: Double?
    /// How far the current camera would move in the map if the new transform replaced the reference.
    public var camera_correction_m: Double?
    /// Fallback without a camera pose: distance between the two session-origin mappings.
    /// Depends on where the session origin is; not a phone correction distance.
    public var origin_mapping_delta_m: Double?
    /// Diagnostic only. nil when unavailable. Never a probability or an automatic decision.
    public var consistent: Bool?
    public var yaw_threshold_deg: Double
    public var distance_threshold_m: Double
}

public enum LiDARSessionConsistency {
    public static func yawDegrees(_ m: [[Double]]) -> Double { atan2(m[0][2],m[0][0])*180/Double.pi }
    public static func compare(reference: LiDARConfirmedAlignment?, transform: [[Double]], mapID: String, geometrySHA256: String?,
                               sessionID: String, generation: Int, cameraInSession: [[Double]]? = nil,
                               yawThresholdDeg: Double = 15, distanceThresholdM: Double = 1) -> LiDARConsistencyReport {
        func unavailable(_ reason: String) -> LiDARConsistencyReport {
            LiDARConsistencyReport(available:false,reason:reason,yaw_delta_deg:nil,camera_correction_m:nil,origin_mapping_delta_m:nil,
                                   consistent:nil,yaw_threshold_deg:yawThresholdDeg,distance_threshold_m:distanceThresholdM)
        }
        guard let reference else { return unavailable("no_reference") }
        guard reference.map_id == mapID else { return unavailable("different_map") }
        guard reference.geometry_sha256 == geometrySHA256 else { return unavailable("different_geometry") }
        guard reference.session_id == sessionID else { return unavailable("different_session") }
        guard reference.generation == generation else { return unavailable("different_generation") }
        guard RigidMatrix.valid(reference.transform),RigidMatrix.valid(transform) else { return unavailable("invalid_transform") }
        if let cameraInSession,!RigidMatrix.valid(cameraInSession) { return unavailable("invalid_transform") }
        let delta = yawDegrees(transform)-yawDegrees(reference.transform)
        let yaw = abs(atan2(sin(delta*Double.pi/180),cos(delta*Double.pi/180)))*180/Double.pi
        if let cameraInSession {
            let a = CampusMapGeometry.multiply(reference.transform,cameraInSession),b = CampusMapGeometry.multiply(transform,cameraInSession)
            let d = sqrt((0..<3).reduce(0.0) { $0+pow(a[$1][3]-b[$1][3],2) })
            return LiDARConsistencyReport(available:true,reason:"ok",yaw_delta_deg:yaw,camera_correction_m:d,origin_mapping_delta_m:nil,
                consistent:yaw <= yawThresholdDeg && d <= distanceThresholdM,yaw_threshold_deg:yawThresholdDeg,distance_threshold_m:distanceThresholdM)
        }
        let d = sqrt((0..<3).reduce(0.0) { $0+pow(reference.transform[$1][3]-transform[$1][3],2) })
        return LiDARConsistencyReport(available:true,reason:"origin_mapping_only",yaw_delta_deg:yaw,camera_correction_m:nil,origin_mapping_delta_m:d,
            consistent:yaw <= yawThresholdDeg && d <= distanceThresholdM,yaw_threshold_deg:yawThresholdDeg,distance_threshold_m:distanceThresholdM)
    }
}

// MARK: - Free-space evidence (experimental, report only)

public struct LiDARFreeSpaceCheck: Codable, Equatable {
    /// Query points in the structural height band.
    public var total: Int
    /// Points whose map voxel is observed (free or occupied); unknown and conflicting voxels are not comparable.
    public var comparable: Int
    /// Points landing in reliably free map space with no occupied or conflicting voxel within one voxel.
    public var conflicts: Int
    public var conflict_rate: Double?
    public var coverage: Double
}

/// Sparse 3D ray counts from map keyframes. Each keyframe contributes at most one hit and one
/// pass per voxel. Endpoint voxels record hits; voxels before max(0.15 m, 3 %) of the endpoint
/// record passes; the buffer in between records nothing. Invalid, low-confidence or
/// out-of-range depth produces no free-space evidence.
public struct LiDARFreeSpaceMap {
    public enum State { case unknown, free, occupied, conflict }
    public struct Settings: Equatable {
        public var voxel_m = 0.10, pixel_stride = 8, min_depth_m = 0.3, max_depth_m = 4.0
        public var endpoint_margin_m = 0.15, endpoint_margin_fraction = 0.03
        public var occupied_min_hits = 2, free_min_passes = 3, free_max_hit_ratio = 0.1, occupied_min_hit_ratio = 0.5
        public init() {}
    }
    public let settings: Settings
    private var hits = [LiDARVoxelKey:UInt16](),passes = [LiDARVoxelKey:UInt16]()
    public private(set) var frames = 0
    public init(settings: Settings = Settings()) { self.settings = settings }
    public var voxelCount: Int { Set(hits.keys).union(passes.keys).count }

    public mutating func add(frame: LiDARFrame, depth: Data, confidence: Data) throws {
        try frame.validate()
        let c = frame.calibration,t = frame.camera_to_session,v = settings.voxel_m
        guard depth.count == c.width*c.height*4,confidence.count == c.width*c.height else { throw LiDARScanError.invalid("深度或置信度数据不完整") }
        let origin = ProbePoint(t[0][3],t[1][3],t[2][3])
        var frameHits = Set<LiDARVoxelKey>(),framePasses = Set<LiDARVoxelKey>()
        depth.withUnsafeBytes { raw in
            for row in stride(from:0,to:c.height,by:settings.pixel_stride) {
                for column in stride(from:0,to:c.width,by:settings.pixel_stride) {
                    let i = row*c.width+column
                    let d = Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))))
                    guard confidence[i] >= 1,confidence[i] <= 2,d.isFinite,d >= settings.min_depth_m,d <= settings.max_depth_m else { continue }
                    let end = c.point(u:column,v:row,depth:d,cameraToSession:t)
                    frameHits.insert(LiDARVoxelKey(end,size:v))
                    let length = sqrt(pow(end.x-origin.x,2)+pow(end.y-origin.y,2)+pow(end.z-origin.z,2))
                    let free = length-max(settings.endpoint_margin_m,settings.endpoint_margin_fraction*length)
                    guard free > 0,length > 0 else { continue }
                    let ux = (end.x-origin.x)/length,uy = (end.y-origin.y)/length,uz = (end.z-origin.z)/length
                    var s = v/2
                    while s < free {
                        framePasses.insert(LiDARVoxelKey(ProbePoint(origin.x+ux*s,origin.y+uy*s,origin.z+uz*s),size:v))
                        s += v/2
                    }
                }
            }
        }
        for key in frameHits { hits[key,default:0] &+= 1 }
        for key in framePasses.subtracting(frameHits) { passes[key,default:0] &+= 1 }
        frames += 1
    }
    public func state(_ key: LiDARVoxelKey) -> State {
        let h = Int(hits[key] ?? 0),p = Int(passes[key] ?? 0),total = h+p
        guard total > 0 else { return .unknown }
        let ratio = Double(h)/Double(total)
        if h >= settings.occupied_min_hits && ratio >= settings.occupied_min_hit_ratio { return .occupied }
        if p >= settings.free_min_passes && ratio < settings.free_max_hit_ratio { return .free }
        if h > 0 && p > 0 { return .conflict }
        return .unknown
    }
    /// Query points are transformed into the map; only the structural band (0.3–2.6 m above the
    /// query floor) is checked, as in the solver.
    public func check(query: [ProbePoint], transform: [[Double]]) -> LiDARFreeSpaceCheck {
        let floor = LiDARSampling.floorHeight(query)
        let band = query.filter { $0.y > floor+0.30 && $0.y < floor+2.6 }
        var comparable = 0,conflicts = 0
        for p in band {
            let q = CampusMapGeometry.point(p.array,through:transform)
            let key = LiDARVoxelKey(ProbePoint(q[0],q[1],q[2]),size:settings.voxel_m)
            switch state(key) {
            case .occupied: comparable += 1
            case .free:
                comparable += 1
                var near = false
                for dx in -1...1 { for dy in -1...1 { for dz in -1...1 where !near {
                    let s = state(LiDARVoxelKey(x:key.x+dx,y:key.y+dy,z:key.z+dz))
                    if s == .occupied || s == .conflict { near = true }
                } } }
                if !near { conflicts += 1 }
            case .unknown,.conflict: break
            }
        }
        return LiDARFreeSpaceCheck(total:band.count,comparable:comparable,conflicts:conflicts,
            conflict_rate:comparable > 0 ? Double(conflicts)/Double(comparable) : nil,
            coverage:band.isEmpty ? 0 : Double(comparable)/Double(band.count))
    }
}

// MARK: - Capture policy (stage 1). Experimental initial values, not validated defaults.

/// Decides whether a candidate frame becomes a keyframe. Motion is measured against the last
/// *accepted* keyframe. A frame needs a pacing reason (first, moved, rotated) and a content
/// reason (novel surface or better quality), or a manual request. Manual requests never
/// bypass tracking or depth checks.
public struct LiDARKeyframePolicy {
    public struct Settings: Equatable {
        public var move_m = 0.35, rotate_deg = 12.0, min_interval_s = 0.25
        public var novel_fraction = 0.15, min_novel_voxels = 150
        public var improvable_fraction = 0.10, min_improvable_voxels = 150
        public var min_valid_depth = 0.05
        public var quality_interval_s = 1.0
        public init() {}
    }
    public struct Input {
        public var timestamp: Double, cameraToSession: [[Double]], trackingNormal: Bool
        public var validDepthFraction: Double
        /// From LiDARBlockBudget.preview for this frame's observations.
        public var preview: LiDARBudgetPreview
        public var manual: Bool
        public init(timestamp: Double, cameraToSession: [[Double]], trackingNormal: Bool, validDepthFraction: Double,
                    preview: LiDARBudgetPreview, manual: Bool = false) {
            self.timestamp = timestamp; self.cameraToSession = cameraToSession; self.trackingNormal = trackingNormal
            self.validDepthFraction = validDepthFraction; self.preview = preview; self.manual = manual
        }
    }
    public struct Decision: Equatable {
        public var accept: Bool
        /// Pacing and content reasons when accepted: first, moved, rotated, novel_surface, quality_gain, manual.
        public var reasons: [String]
        /// tracking, low_depth, too_soon, no_motion, nothing_new.
        public var skip_reason: String?
        public var moved_m: Double?, rotated_deg: Double?
        public var novel_fraction: Double
    }
    public let settings: Settings
    public private(set) var lastAccepted: (timestamp: Double, pose: [[Double]])?
    public private(set) var acceptedCount = 0
    public init(settings: Settings = Settings()) { self.settings = settings }
    public func decide(_ input: Input) -> Decision {
        let p = input.preview,fraction = p.total > 0 ? Double(p.novel)/Double(p.total) : 0
        func skip(_ reason: String,_ moved: Double? = nil,_ rotated: Double? = nil) -> Decision {
            Decision(accept:false,reasons:[],skip_reason:reason,moved_m:moved,rotated_deg:rotated,novel_fraction:fraction)
        }
        guard input.trackingNormal,RigidMatrix.valid(input.cameraToSession) else { return skip("tracking") }
        guard input.validDepthFraction >= settings.min_valid_depth,p.total > 0 else { return skip("low_depth") }
        let novel = p.novel >= settings.min_novel_voxels && fraction >= settings.novel_fraction
        let better = p.improvable >= settings.min_improvable_voxels && Double(p.improvable)/Double(p.total) >= settings.improvable_fraction
        guard let last = lastAccepted else {
            return Decision(accept:true,reasons:["first"]+(input.manual ? ["manual"] : []),skip_reason:nil,moved_m:nil,rotated_deg:nil,novel_fraction:fraction)
        }
        guard input.timestamp-last.timestamp >= settings.min_interval_s else { return skip("too_soon") }
        let a = last.pose,b = input.cameraToSession
        let moved = sqrt((0..<3).reduce(0.0) { $0+pow(a[$1][3]-b[$1][3],2) })
        // Angle between optical axes (-Z columns), so pitch counts as well as yaw.
        let dot = (0..<3).reduce(0.0) { $0+a[$1][2]*b[$1][2] }
        let rotated = acos(max(-1,min(1,dot)))*180/Double.pi
        if input.manual { return Decision(accept:true,reasons:["manual"],skip_reason:nil,moved_m:moved,rotated_deg:rotated,novel_fraction:fraction) }
        var pacing = [String]()
        if moved >= settings.move_m { pacing.append("moved") }
        if rotated >= settings.rotate_deg { pacing.append("rotated") }
        // A clearly better view of stored surfaces is accepted without motion, but no more
        // than once per quality_interval_s so a still camera cannot flood the frame budget.
        if pacing.isEmpty {
            if better && input.timestamp-last.timestamp >= settings.quality_interval_s {
                return Decision(accept:true,reasons:["quality_gain"],skip_reason:nil,moved_m:moved,rotated_deg:rotated,novel_fraction:fraction)
            }
            return skip("no_motion",moved,rotated)
        }
        let content = (novel ? ["novel_surface"] : [])+(better ? ["quality_gain"] : [])
        guard !content.isEmpty else { return skip("nothing_new",moved,rotated) }
        return Decision(accept:true,reasons:pacing+content,skip_reason:nil,moved_m:moved,rotated_deg:rotated,novel_fraction:fraction)
    }
    /// Call after the frame was actually stored.
    public mutating func didAccept(timestamp: Double, cameraToSession: [[Double]]) {
        lastAccepted = (timestamp,cameraToSession);acceptedCount += 1
    }
}

public struct LiDARBudgetPreview: Equatable {
    /// Observations landing in voxels not yet stored.
    public var novel: Int
    /// Observations whose quality beats the stored representative.
    public var improvable: Int
    public var total: Int
    /// New voxels that a full block or the global cap would refuse; not counted as novel,
    /// so revisiting a saturated area does not keep producing keyframes.
    public var blocked: Int = 0
}

public struct LiDARBudgetCommit: Equatable {
    public var batch: Int
    public var added = 0, replaced = 0, refreshed = 0
    /// New voxels refused because their 2 m block reached its quota, or the whole map its cap.
    public var refused_block = 0, refused_global = 0
    /// Final representatives added or replaced by this batch, for incremental UI updates.
    public var updated_points: [ProbePoint] = []
}

/// One 2 m x 2 m (XZ) block. Status describes budget use and diagnostics, never completeness.
public struct LiDARBlockStat: Codable, Equatable {
    public var bx: Int, bz: Int
    public var voxels: Int, floor_voxels: Int, structure_voxels: Int
    public var refused: Int
    /// filling, full, refusing, suspect.
    public var status: String
}

public struct LiDARBudgetSnapshot: Codable, Equatable {
    public var version = 1
    public var block_m: Double, voxel_m: Double
    public var voxels: Int, global_cap: Int
    public var floor_y: Double?
    public var refused_block: Int, refused_global: Int
    public var batches: Int
    public var blocks: [LiDARBlockStat]
}

/// Voxel store for mapping with per-block quotas and quality-aware replacement.
/// Not thread-safe: use from one queue. Every commit is a batch that can be rolled back,
/// so "save the part before the anomaly" has an explicit boundary.
public final class LiDARBlockBudget {
    public struct Settings: Equatable {
        public var voxel_m = 0.10, block_m = 2.0, global_cap = 60_000
        /// Per-block quotas, split so the floor cannot use up a block's budget.
        public var floor_quota = 500, structure_quota = 1_500
        /// Depth preferred for representatives; quality falls off outside it.
        public var preferred_depth_m = 1.0...3.0
        public var replace_margin = 0.25
        public init() {}
        public init(globalCap: Int) { global_cap = globalCap }
    }
    private struct Record { var point: ProbePoint; var quality: Double; var observations: Int; var batch: Int; var floor: Bool }
    private enum Change { case added(LiDARVoxelKey); case replaced(LiDARVoxelKey,Record) }
    public let settings: Settings
    private var voxels = [LiDARVoxelKey:Record]()
    private var blockCounts = [BlockKey:(floor: Int,structure: Int)]()
    private var blockRefused = [BlockKey:Int]()
    private var suspect = Set<BlockKey>()
    private var log = [(batch: Int,changes: [Change])]()
    private var refusedBlock = 0,refusedGlobal = 0
    public private(set) var batch = 0
    public private(set) var floorY: Double?
    private struct BlockKey: Hashable { let x: Int, z: Int }
    public init(settings: Settings = Settings()) { self.settings = settings }
    public var count: Int { voxels.count }
    public var points: [ProbePoint] { voxels.values.map(\.point) }
    private func blockKey(_ p: ProbePoint) -> BlockKey { BlockKey(x:Int(floor(p.x/settings.block_m)),z:Int(floor(p.z/settings.block_m))) }
    private func quality(_ o: LiDARDepthObservation) -> Double {
        let r = settings.preferred_depth_m,miss = o.depth < r.lowerBound ? r.lowerBound-o.depth : o.depth > r.upperBound ? o.depth-r.upperBound : 0
        return Double(o.confidence)-miss
    }
    private func isFloor(_ p: ProbePoint) -> Bool { floorY.map { p.y < $0+0.30 } ?? false }
    public func preview(_ observations: [LiDARDepthObservation]) -> LiDARBudgetPreview {
        var novel = Set<LiDARVoxelKey>(),blocked = Set<LiDARVoxelKey>(),improvable = 0
        for o in observations {
            let key = LiDARVoxelKey(o.point,size:settings.voxel_m)
            if let r = voxels[key] { if quality(o) > r.quality+settings.replace_margin { improvable += 1 };continue }
            let counts = blockCounts[blockKey(o.point)] ?? (0,0)
            let full = isFloor(o.point) ? counts.floor >= settings.floor_quota : counts.structure >= settings.structure_quota
            if full || voxels.count >= settings.global_cap { blocked.insert(key) } else { novel.insert(key) }
        }
        return LiDARBudgetPreview(novel:novel.count,improvable:improvable,total:observations.count,blocked:blocked.count)
    }
    @discardableResult
    public func commit(_ observations: [LiDARDepthObservation]) -> LiDARBudgetCommit {
        batch += 1
        // Bootstrap the floor estimate from the first large batch, before quotas apply.
        if floorY == nil && observations.count >= 200 {
            floorY = LiDARSampling.floorHeight(LiDARSampling.sample(observations.map(\.point),limit:4_000))
        }
        var result = LiDARBudgetCommit(batch:batch),changes = [Change](),touched = Set<LiDARVoxelKey>()
        for o in observations {
            let key = LiDARVoxelKey(o.point,size:settings.voxel_m),q = quality(o)
            if var r = voxels[key] {
                guard touched.insert(key).inserted else { continue }
                if q > r.quality+settings.replace_margin {
                    changes.append(.replaced(key,r));r.point = o.point;r.quality = q;r.observations += 1;r.batch = batch;voxels[key] = r;result.replaced += 1
                    result.updated_points.append(o.point)
                } else { r.observations += 1;voxels[key] = r;result.refreshed += 1 }
                continue
            }
            let b = blockKey(o.point),floor = isFloor(o.point),counts = blockCounts[b] ?? (0,0)
            if voxels.count >= settings.global_cap { result.refused_global += 1;continue }
            if floor ? counts.floor >= settings.floor_quota : counts.structure >= settings.structure_quota {
                result.refused_block += 1;blockRefused[b,default:0] += 1;continue
            }
            voxels[key] = Record(point:o.point,quality:q,observations:1,batch:batch,floor:floor);touched.insert(key)
            blockCounts[b] = floor ? (counts.floor+1,counts.structure) : (counts.floor,counts.structure+1)
            changes.append(.added(key));result.added += 1;result.updated_points.append(o.point)
        }
        refusedBlock += result.refused_block;refusedGlobal += result.refused_global
        log.append((batch,changes))
        if batch%10 == 0 { updateFloor() }
        return result
    }
    private func updateFloor() {
        guard voxels.count >= 200 else { return }
        floorY = LiDARSampling.floorHeight(LiDARSampling.sample(points,limit:4_000))
    }
    /// Reverts every batch after `toBatch` (0 reverts everything). Observation counts of
    /// refreshed voxels are not reverted; they carry no geometry.
    public func rollback(toBatch target: Int) {
        while let last = log.last,last.batch > target {
            for change in last.changes.reversed() {
                switch change {
                case .added(let key):
                    if let r = voxels.removeValue(forKey:key) {
                        let b = blockKey(r.point),c = blockCounts[b] ?? (0,0)
                        blockCounts[b] = r.floor ? (max(0,c.floor-1),c.structure) : (c.floor,max(0,c.structure-1))
                    }
                case .replaced(let key,let old): voxels[key] = old
                }
            }
            log.removeLast()
        }
        batch = min(batch,target)
    }
    /// Loads an existing map as batch 0 before a supplement session. Seeds count toward block
    /// quotas and set the floor, so new geometry is judged (revisit check, novelty) against the
    /// old map. Rollback never goes below batch 0, so seeds cannot be removed. Seed quality is
    /// low on purpose: a better new observation of the same voxel may replace it.
    public func seed(_ points: [ProbePoint], quality: Double = 0.5) throws {
        guard voxels.isEmpty, batch == 0, log.isEmpty else { throw LiDARScanError.invalid("只能在空的预算上载入原图") }
        let valid = points.filter { $0.array.allSatisfy { $0.isFinite && abs($0) < 1000 } }
        guard valid.count <= settings.global_cap else { throw LiDARScanError.invalid("原图点数超过本次上限") }
        if valid.count >= 200 { floorY = LiDARSampling.floorHeight(LiDARSampling.sample(valid,limit:4_000)) }
        for p in valid {
            let key = LiDARVoxelKey(p,size:settings.voxel_m)
            guard voxels[key] == nil else { continue }
            let b = blockKey(p),floor = isFloor(p),c = blockCounts[b] ?? (0,0)
            voxels[key] = Record(point:p,quality:quality,observations:1,batch:0,floor:floor)
            blockCounts[b] = floor ? (c.floor+1,c.structure) : (c.floor,c.structure+1)
        }
    }
    public var seededCount: Int { voxels.values.filter { $0.batch == 0 }.count }
    /// Points committed by this session (excludes a seeded map).
    public var addedPoints: [ProbePoint] { voxels.values.filter { $0.batch > 0 }.map(\.point) }
    public func markSuspect(_ p: ProbePoint) { suspect.insert(blockKey(p)) }
    /// Warning only: whether a straight walk from `a` to `b` passes through stored structure
    /// (wall-height voxels 0.5–1.8 m above the floor). Unscanned space counts as open, so a
    /// false result is not proof that the way is clear.
    public func crossesStructure(from a: ProbePoint, to b: ProbePoint) -> Bool {
        guard let f = floorY else { return false }
        let d = hypot(b.x-a.x,b.z-a.z),steps = max(1,Int(d/(settings.voxel_m/2)))
        var run = 0
        for i in 0...steps {
            let t = Double(i)/Double(steps),x = a.x+(b.x-a.x)*t,z = a.z+(b.z-a.z)*t
            var hit = false
            for y in stride(from:f+0.5,through:f+1.8,by:settings.voxel_m) where voxels[LiDARVoxelKey(ProbePoint(x,y,z),size:settings.voxel_m)] != nil { hit = true;break }
            run = hit ? run+1 : 0
            if run >= 2 { return true }
        }
        return false
    }
    public func snapshot() -> LiDARBudgetSnapshot {
        let keys = Set(blockCounts.keys).union(blockRefused.keys)
        let blocks = keys.map { k -> LiDARBlockStat in
            let c = blockCounts[k] ?? (0,0),refused = blockRefused[k] ?? 0
            let full = c.floor >= settings.floor_quota || c.structure >= settings.structure_quota
            let status = suspect.contains(k) ? "suspect" : refused > 0 ? "refusing" : full ? "full" : "filling"
            return LiDARBlockStat(bx:k.x,bz:k.z,voxels:c.floor+c.structure,floor_voxels:c.floor,structure_voxels:c.structure,refused:refused,status:status)
        }.sorted { ($0.bx,$0.bz) < ($1.bx,$1.bz) }
        return LiDARBudgetSnapshot(block_m:settings.block_m,voxel_m:settings.voxel_m,voxels:voxels.count,global_cap:settings.global_cap,
            floor_y:floorY,refused_block:refusedBlock,refused_global:refusedGlobal,batches:batch,blocks:blocks)
    }
    /// Runtime map points: a fair share per block, so the saved map keeps the coverage
    /// that capture paid for instead of thinning sparse blocks first.
    public func runtimePoints(limit: Int) -> [ProbePoint] {
        guard voxels.count > limit else { return LiDARSampling.voxel(points,size:settings.voxel_m,limit:limit) }
        var byBlock = [BlockKey:[ProbePoint]]()
        for r in voxels.values { byBlock[blockKey(r.point),default:[]].append(r.point) }
        var remaining = limit,pending = byBlock.keys.sorted { (byBlock[$0]!.count,$0.x,$0.z) < (byBlock[$1]!.count,$1.x,$1.z) }
        var result = [ProbePoint]()
        while !pending.isEmpty,remaining > 0 {
            let share = remaining/pending.count
            guard share > 0 else {
                // More blocks than points left: one point each from the largest remaining blocks.
                for key in pending.reversed().prefix(remaining) { result.append(byBlock[key]![0]) }
                break
            }
            let key = pending.removeFirst()
            let pts = LiDARSampling.voxel(byBlock[key]!,size:settings.voxel_m,limit:share)
            result += pts;remaining -= pts.count
        }
        return Array(result.prefix(limit))
    }

    /// Diagnostic only: compares observations in already full blocks against stored surfaces.
    /// Small residuals do not prove the absence of drift (sliding along a corridor leaves
    /// them small); too little overlap is reported as unknown.
    public func revisitCheck(_ observations: [LiDARDepthObservation], settings r: LiDARRevisitSettings = LiDARRevisitSettings()) -> LiDARRevisitReport {
        let full = Set(blockCounts.filter { $0.value.floor >= settings.floor_quota || $0.value.structure >= settings.structure_quota }.keys)
        let candidates = observations.filter { full.contains(blockKey($0.point)) && !isFloor($0.point) }
        let sample = candidates.count <= r.sample ? candidates : (0..<r.sample).map { candidates[$0*candidates.count/r.sample] }
        var distances = [Double]()
        let reach = Int(ceil(r.search_m/settings.voxel_m))
        for o in sample {
            let k = LiDARVoxelKey(o.point,size:settings.voxel_m)
            var best = Double.infinity
            for dx in -reach...reach { for dy in -reach...reach { for dz in -reach...reach {
                guard let rec = voxels[LiDARVoxelKey(x:k.x+dx,y:k.y+dy,z:k.z+dz)] else { continue }
                let d = sqrt(pow(rec.point.x-o.point.x,2)+pow(rec.point.y-o.point.y,2)+pow(rec.point.z-o.point.z,2))
                if d < best { best = d }
            } } }
            if best <= r.search_m { distances.append(best) }
        }
        let coverage = sample.isEmpty ? 0 : Double(distances.count)/Double(sample.count)
        guard distances.count >= r.min_comparable,coverage >= r.min_coverage else {
            return LiDARRevisitReport(status:"unknown",checked:sample.count,comparable:distances.count,coverage:coverage,median_m:nil,p90_m:nil,
                reason:sample.isEmpty ? "no_full_block_in_view" : "insufficient_overlap")
        }
        distances.sort()
        let median = distances[distances.count/2],p90 = distances[min(distances.count-1,distances.count*9/10)]
        let suspicious = median >= r.suspect_median_m && p90 >= r.suspect_p90_m
        return LiDARRevisitReport(status:suspicious ? "suspect" : "ok",checked:sample.count,comparable:distances.count,coverage:coverage,
            median_m:median,p90_m:p90,reason:suspicious ? "offset_from_stored_surface" : "residual_low_not_proof_of_alignment")
    }
}

public struct LiDARRevisitSettings: Equatable {
    public var sample = 400, search_m = 0.35, min_comparable = 60, min_coverage = 0.30
    public var suspect_median_m = 0.12, suspect_p90_m = 0.20
    public init() {}
}

public struct LiDARRevisitReport: Codable, Equatable {
    /// unknown, ok (residual low, which is not proof of alignment), suspect.
    public var status: String
    public var checked: Int, comparable: Int
    public var coverage: Double
    public var median_m: Double?, p90_m: Double?
    public var reason: String
    /// Distance to the nearest stored voxel representative (not point-to-plane), at most search_m.
    public var metric = "point_to_nearest_voxel_representative"
    /// Direction support of the matched surfaces; not computed yet, so always nil (unknown).
    public var normal_support: Double? = nil
}

/// Raises a flag only after `required` consecutive suspect reports; unknown reports neither
/// raise nor clear it.
public struct LiDARRevisitMonitor: Equatable {
    public var required = 3
    public private(set) var consecutive = 0
    public private(set) var flagged = false
    public init(required: Int = 3) { self.required = required }
    public mutating func observe(_ report: LiDARRevisitReport) -> Bool {
        switch report.status {
        case "suspect": consecutive += 1;if consecutive >= required { flagged = true }
        case "ok": consecutive = 0
        default: break
        }
        return flagged
    }
    public mutating func acknowledge() { flagged = false;consecutive = 0 }
}

// MARK: - Position-window search (stage 1D)

/// Restricts where the *reference camera* (the phone at query time, in query-session
/// coordinates) may land in the map. Map support is cropped separately with a halo, so end
/// walls just outside the window still constrain the fit.
public struct LiDARSearchWindow: Equatable {
    public var center: ProbePoint
    public var radius: Double
    public var supportRadius: Double
    public var referenceCamera: ProbePoint
    public var centerNodeID: String?
    public var source: String
    public var tier: Int
    public init(center: ProbePoint, radius: Double, supportRadius: Double, referenceCamera: ProbePoint,
                centerNodeID: String? = nil, source: String = "user_selected_node", tier: Int = 0) {
        self.center = center; self.radius = radius; self.supportRadius = supportRadius; self.referenceCamera = referenceCamera
        self.centerNodeID = centerNodeID; self.source = source; self.tier = tier
    }
}

/// A unique result inside a scope means unique within that scope only, never map-wide.
public struct LiDARSearchScope: Codable, Equatable {
    public var kind: String
    public var center_node_id: String?
    public var center_xz: [Double]
    public var candidate_radius_m: Double
    public var support_radius_m: Double
    /// Coarse-grid bounds actually searched [minX, maxX, minZ, maxZ].
    public var bounds_xz: [Double]?
    public var reference_camera_xz: [Double]?
    public var source: String
    public var tier: Int
    public var tiers_tried: Int
}

public struct LiDARWindowedResult: Codable {
    /// Every tier tried, in order; none is discarded.
    public var tiers: [LiDARLocalizationResult]
    public var final: LiDARLocalizationResult { tiers.last! }
}

extension LiDARLocalizer {
    /// Tries growing windows around a start node. Stops at the first tier that returns a
    /// single candidate for review; otherwise keeps the last tier, ambiguity included.
    /// Wider tiers can add rivals as well as remove them, so no tier is picked by score.
    public static func solveWindowed(map: [ProbePoint], query: [ProbePoint], sessionID: String, referenceCamera: ProbePoint,
                                     center: ProbePoint, centerNodeID: String? = nil, radii: [Double] = [10,15,25],
                                     halo: Double? = nil, maxSeconds: Double = 15,
                                     cancellation: LiDARWorkCancellation = LiDARWorkCancellation(),
                                     parameters: LiDARLocalizerParameters = LiDARLocalizerParameters(),
                                     yawPrior: (center: Double, halfWidth: Double)? = nil) -> LiDARWindowedResult {
        let start = ProcessInfo.processInfo.systemUptime
        // Halo covers how far the query reaches from the reference camera, plus a margin.
        let extent = query.map { hypot($0.x-referenceCamera.x,$0.z-referenceCamera.z) }.max() ?? 0
        let support = halo ?? min(8,max(3,extent+2))
        var tiers = [LiDARLocalizationResult]()
        for (i,r) in radii.enumerated() where r > 0 && r.isFinite {
            let remaining = maxSeconds-(ProcessInfo.processInfo.systemUptime-start)
            guard remaining > 0.5 || tiers.isEmpty else { break }
            let reach = r+support
            let cropped = map.filter { hypot($0.x-center.x,$0.z-center.z) <= reach }
            let window = LiDARSearchWindow(center:center,radius:r,supportRadius:reach,referenceCamera:referenceCamera,centerNodeID:centerNodeID,tier:i)
            var result = solve(map:cropped,query:query,sessionID:sessionID,maxSeconds:max(0.5,remaining),cancellation:cancellation,
                               parameters:parameters,window:window,yawPrior:yawPrior)
            result.search_scope?.tiers_tried = i+1
            tiers.append(result)
            if result.status == "candidate_requires_review" || result.status == "cancelled" || result.status == "timeout" { break }
        }
        if tiers.isEmpty {
            tiers.append(solve(map:[],query:query,sessionID:sessionID,maxSeconds:0.1,cancellation:cancellation,parameters:parameters))
        }
        return LiDARWindowedResult(tiers:tiers)
    }
}

// MARK: - Landmark text (stage 2a)

/// Text normalization and tolerant comparison for room plates. Scores rank candidate
/// matches; they are not probabilities and never confirm a plate on their own.
public enum LiDARText {
    /// Full-width to half-width, drop whitespace and separators, uppercase Latin letters.
    public static func normalize(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            var s = scalar
            if (0xFF01...0xFF5E).contains(s.value),let half = Unicode.Scalar(s.value-0xFEE0) { s = half }
            if s.value == 0x3000 || CharacterSet.whitespacesAndNewlines.contains(s) { continue }
            if "-_·.:：、".unicodeScalars.contains(s) { continue }
            out.unicodeScalars.append(s)
        }
        return out.uppercased()
    }
    /// Characters OCR commonly confuses on door plates.
    static let confusable: [Character:Set<Character>] = [
        "1":["7","I","L"],"7":["1"],"I":["1","L"],"L":["1","I"],
        "0":["O","D"],"O":["0","D"],"D":["0","O"],
        "8":["B","3"],"B":["8"],"3":["8"],"5":["S"],"S":["5"],"2":["Z"],"Z":["2"],"6":["G"],"G":["6"]
    ]
    /// 1 for identical normalized text, lower for more edits; confusable substitutions cost 0.5.
    public static func similarity(_ a: String,_ b: String) -> Double {
        let x = Array(normalize(a)),y = Array(normalize(b))
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        var row = (0...y.count).map(Double.init)
        for i in 1...max(1,x.count) where !x.isEmpty {
            var previous = row[0];row[0] = Double(i)
            for j in 1...max(1,y.count) where !y.isEmpty {
                let substitution = x[i-1] == y[j-1] ? 0 : (confusable[x[i-1]]?.contains(y[j-1]) ?? false) ? 0.5 : 1
                let value = min(row[j]+1,row[j-1]+1,previous+substitution)
                previous = row[j];row[j] = value
            }
        }
        return max(0,1-row[y.count]/Double(max(x.count,y.count)))
    }
    /// Room-number-like text: digits, optionally with a building letter or a dash.
    public static func looksLikeRoomNumber(_ text: String) -> Bool {
        let t = normalize(text)
        return t.range(of:#"^[A-Z]?\d{3,4}[A-Z]?$"#,options:.regularExpression) != nil
    }
}

public struct LiDARTextObservation: Codable, Equatable {
    public var text: String
    public var confidence: Double
    /// Top candidates as [text, confidence].
    public var candidates: [LiDARTextCandidate]
    /// Vision-normalized box in the *oriented* image, origin bottom-left: [x, y, w, h].
    public var vision_box: [Double]
}
public struct LiDARTextCandidate: Codable, Equatable {
    public var text: String
    public var confidence: Double
    public init(text: String, confidence: Double) { self.text = text; self.confidence = confidence }
}

#if canImport(Vision) && canImport(CoreGraphics)
import Vision
import CoreGraphics


/// On-device text recognition. Call off the main thread. Accurate level, Simplified Chinese
/// and English, no language correction (room numbers must not be "corrected").
public enum LiDAROCR {
    public static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation = .right,
                                 minimumTextHeight: Float = 0) throws -> [LiDARTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans","en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight
        try VNImageRequestHandler(cgImage:image,orientation:orientation,options:[:]).perform([request])
        return (request.results ?? []).compactMap { o in
            let top = o.topCandidates(3)
            guard let best = top.first else { return nil }
            let b = o.boundingBox
            return LiDARTextObservation(text:best.string,confidence:Double(best.confidence),
                candidates:top.map { LiDARTextCandidate(text:$0.string,confidence:Double($0.confidence)) },
                vision_box:[Double(b.minX),Double(b.minY),Double(b.width),Double(b.height)])
        }
    }
}
#endif

// MARK: - Platform-neutral localization evidence (reserved interface)

/// One piece of evidence about where the session is in the map, independent of the sensor
/// that produced it. Recorded only; no decision path reads it yet, so it adds no runtime cost
/// to the iPhone solver. A device without LiDAR can produce landmark/compass/radio evidence
/// in the same shape.
public struct LiDARLocalizationEvidence: Codable, Equatable {
    public enum Source: String, Codable { case geometry, landmark, compass, radio, manual }
    /// pose_4dof: a full map-from-session transform; yaw_range: heading only;
    /// region: a map area (center + radius); none: evidence was unavailable.
    public enum Constraint: String, Codable { case pose_4dof, yaw_range, region, none }
    public var source: Source
    public var constraint: Constraint
    /// map-from-session transform for pose_4dof.
    public var transform: [[Double]]?
    public var yaw_deg: Double?, yaw_tolerance_deg: Double?
    public var region_center_xz: [Double]?, region_radius_m: Double?
    /// ok, ambiguous, rejected, unknown. Never a probability.
    public var status: String
    public var reasons: [String]
    public var scope: LiDARSearchScope?
    public var session_id: String
    public var generation: Int?
    public var timestamp: Double?
    public init(source: Source, constraint: Constraint, status: String, reasons: [String] = [], session_id: String,
                generation: Int? = nil, timestamp: Double? = nil) {
        self.source = source; self.constraint = constraint; self.status = status; self.reasons = reasons
        self.session_id = session_id; self.generation = generation; self.timestamp = timestamp
    }
    /// Geometry evidence from a solver result: the best candidate's transform with the
    /// solver's status and reasons. Rejected results carry no transform.
    public static func fromGeometry(_ r: LiDARLocalizationResult, generation: Int? = nil, timestamp: Double? = nil) -> LiDARLocalizationEvidence {
        let status = r.status == "candidate_requires_review" ? "ok" : r.status == "ambiguous" ? "ambiguous" : r.status == "rejected" ? "rejected" : "unknown"
        var e = LiDARLocalizationEvidence(source:.geometry,constraint:status == "rejected" || status == "unknown" ? .none : .pose_4dof,
                                          status:status,reasons:r.decision_reasons ?? [],session_id:r.session_id,generation:generation,timestamp:timestamp)
        if e.constraint == .pose_4dof { e.transform = r.best?.transform_query_to_map }
        e.scope = r.search_scope
        return e
    }
}

// MARK: - Revisit gate (capture quarantine state machine)

/// Decides, per keyframe, whether its geometry may join the map. Replaces sticky ad-hoc flags:
/// - a single `suspect` isolates only that frame; capture continues normally afterwards;
/// - `unknown` (for example no full block in view, i.e. a new area) never locks capture;
/// - only `required` consecutive suspects (the monitor rule) make isolation sticky, and the
///   gate then reports the budget batch from just before the suspect streak, so "save the part
///   before the anomaly" can roll back to a real boundary;
/// - while flagged or in a user-chosen diagnostic segment, no geometry is committed.
public struct LiDARRevisitGate: Equatable {
    public enum Mode: String, Codable { case normal, flagged, diagnostic_segment }
    public struct Step: Equatable {
        public var commitGeometry: Bool
        /// committed, isolated_single_suspect, flagged, diagnostic_segment.
        public var reason: String
        /// The first suspect of a streak: snapshot the route editor now, so a later flag can restore it.
        public var captureBaseline: Bool
        /// Set once, on the frame that raised the flag: show the review dialog.
        public var newlyFlagged: Bool
        /// When flagged: roll the budget back to this batch (the state before the streak began).
        public var rollbackToBatch: Int?
    }
    public private(set) var mode: Mode = .normal
    public private(set) var monitor: LiDARRevisitMonitor
    /// Budget batch before the first suspect of the current streak; nil when no streak.
    public private(set) var streakStartBatch: Int?
    public init(required: Int = 3) { monitor = LiDARRevisitMonitor(required:required) }
    /// Node marking and plate capture should wait while this is true.
    public var blocksEditing: Bool { mode != .normal }
    /// `report` is nil when no revisit check ran for this frame; `batchBeforeCommit` is the
    /// budget's batch before committing this frame.
    public mutating func step(_ report: LiDARRevisitReport?, batchBeforeCommit: Int) -> Step {
        switch mode {
        case .diagnostic_segment:
            return Step(commitGeometry:false,reason:"diagnostic_segment",captureBaseline:false,newlyFlagged:false,rollbackToBatch:nil)
        case .flagged:
            return Step(commitGeometry:false,reason:"flagged",captureBaseline:false,newlyFlagged:false,rollbackToBatch:streakStartBatch)
        case .normal: break
        }
        guard let report else { return Step(commitGeometry:true,reason:"committed",captureBaseline:false,newlyFlagged:false,rollbackToBatch:nil) }
        switch report.status {
        case "suspect":
            let first = streakStartBatch == nil
            if first { streakStartBatch = batchBeforeCommit }
            if monitor.observe(report) {
                mode = .flagged
                return Step(commitGeometry:false,reason:"flagged",captureBaseline:first,newlyFlagged:true,rollbackToBatch:streakStartBatch)
            }
            return Step(commitGeometry:false,reason:"isolated_single_suspect",captureBaseline:first,newlyFlagged:false,rollbackToBatch:nil)
        case "ok":
            _ = monitor.observe(report);streakStartBatch = nil
            return Step(commitGeometry:true,reason:"committed",captureBaseline:false,newlyFlagged:false,rollbackToBatch:nil)
        default:
            // unknown neither raises nor clears the streak, and never blocks new areas.
            _ = monitor.observe(report)
            return Step(commitGeometry:true,reason:"committed",captureBaseline:false,newlyFlagged:false,rollbackToBatch:nil)
        }
    }
    /// User chose "mark the anomaly and continue (diagnostic only)".
    public mutating func continueAsDiagnostic() { mode = .diagnostic_segment;monitor.acknowledge() }
    /// After the map was saved or capture restarted.
    public mutating func reset() { mode = .normal;monitor.acknowledge();streakStartBatch = nil }
}

// MARK: - Compass evidence (screens opposite-yaw rivals only; never promotes a candidate)

/// One CLHeading reading paired with the ARKit camera pose of the same moment.
public struct LiDARMagneticSample: Codable, Equatable {
    public var timestamp: Double
    public var magnetic_heading_deg: Double
    public var heading_accuracy_deg: Double
    /// Row-major camera pose in the session (mapping session = map coordinates).
    public var camera_to_session: [[Double]]
    public init(timestamp: Double, heading: Double, accuracy: Double, cameraToSession: [[Double]]) {
        self.timestamp = timestamp; magnetic_heading_deg = heading; heading_accuracy_deg = accuracy; camera_to_session = cameraToSession
    }
}

/// Reference axis: the camera optical axis, and only with the phone upright. On the recorded runs
/// (6 sessions, 648 paired readings) heading minus that axis' azimuth stayed within median 2–5°,
/// p90 7–13° per session; the device-top axis is nearly vertical when upright and scattered
/// (p90 up to 165°), and other postures scattered too (p90 up to 61°). Those count as unknown.
public enum LiDARMagnetic {
    public static let method = "camera_axis_upright_v1"
    public static let maxAccuracyDeg = 25.0
    public static func wrap(_ a: Double) -> Double { let r = (a + 180).truncatingRemainder(dividingBy: 360); return (r < 0 ? r + 360 : r) - 180 }
    /// Compass-style azimuth (clockwise seen from above, 0 = session −Z) of the camera optical axis;
    /// nil unless the device top points up and the axis is within about 50° of horizontal.
    public static func cameraAzimuth(_ t: [[Double]]) -> Double? {
        guard t.count >= 3, t.allSatisfy({ $0.count >= 4 }) else { return nil }
        let fx = -t[0][2], fy = -t[1][2], fz = -t[2][2], topY = -t[1][0]
        guard [fx, fy, fz, topY].allSatisfy(\.isFinite), topY > 0.5, abs(fy) < 0.77, hypot(fx, fz) > 1e-6 else { return nil }
        return atan2(fx, -fz) * 180 / .pi
    }
    public struct Offset: Codable, Equatable {
        public var mean_deg: Double
        /// Median and p90 of |deviation| from the circular mean.
        public var spread_deg: Double, p90_deg: Double
        public var count: Int
    }
    /// Circular statistics; a plain median breaks at ±180°.
    public static func offset(_ values: [Double]) -> Offset? {
        let v = values.filter(\.isFinite)
        guard !v.isEmpty else { return nil }
        let s = v.reduce(0) { $0 + sin($1 * .pi / 180) }, c = v.reduce(0) { $0 + cos($1 * .pi / 180) }
        guard hypot(s, c) > 1e-9 else { return nil }
        let mean = atan2(s, c) * 180 / .pi
        let dev = v.map { abs(wrap($0 - mean)) }.sorted()
        return Offset(mean_deg: mean, spread_deg: dev[dev.count / 2], p90_deg: dev[min(dev.count - 1, Int(Double(dev.count) * 0.9))], count: v.count)
    }
    /// heading − camera azimuth for usable samples, optionally after moving the pose by `transform`.
    public static func offsets(_ samples: [LiDARMagneticSample], transform: [[Double]]? = nil) -> [(position: ProbePoint, offset: Double)] {
        samples.compactMap { s in
            guard s.heading_accuracy_deg >= 0, s.heading_accuracy_deg <= maxAccuracyDeg, s.magnetic_heading_deg.isFinite else { return nil }
            let pose = transform.map { CampusMapGeometry.multiply($0, s.camera_to_session) } ?? s.camera_to_session
            guard let az = cameraAzimuth(pose) else { return nil }
            return (ProbePoint(pose[0][3], pose[1][3], pose[2][3]), wrap(s.magnetic_heading_deg - az))
        }
    }
    /// Map-side offsets kept per horizontal cell, so steel, lifts or cabinets stay local.
    public struct Reference: Codable, Equatable {
        public static let fileName = "magnetic-reference.json"
        public struct Cell: Codable, Equatable { public var x: Double, z: Double; public var offset: Offset }
        public var schema_version = 1
        public var method = LiDARMagnetic.method
        public var cell_m: Double
        public var cells: [Cell]
        /// Pooled offset of cells within `radius` of a map position; nil when nothing reliable is near.
        public func merged(with other: Reference) -> Reference { var r = self; r.cells += other.cells; return r }
        /// Whole-map offset, only when the cells agree with each other (spread of cell means ≤ maxSpread).
        /// Used where no cell is near; reported as "global" so it is never mistaken for local evidence.
        public func global(maxSpread: Double = 10, minCells: Int = 2) -> Offset? {
            // Every cell counts once and every cell must agree: no sample-count weighting.
            guard cells.count >= minCells, let pooled = LiDARMagnetic.offset(cells.map(\.offset.mean_deg)) else { return nil }
            let worst = cells.map { abs(LiDARMagnetic.wrap($0.offset.mean_deg - pooled.mean_deg)) }.max() ?? 0
            guard worst <= maxSpread else { return nil }
            return Offset(mean_deg: pooled.mean_deg, spread_deg: max(worst, cells.map(\.offset.spread_deg).max() ?? 0),
                          p90_deg: max(worst, cells.map(\.offset.p90_deg).max() ?? 0), count: cells.reduce(0) { $0 + $1.offset.count })
        }
        public func local(at p: ProbePoint, radius: Double = 5, structure: LiDARStructureGrid? = nil) -> Offset? {
            // With a structure grid, a cell behind stored wall-height structure is not pooled.
            let near = cells.filter { hypot($0.x - p.x, $0.z - p.z) <= radius && !(structure?.crosses(from: p, to: ProbePoint($0.x, p.y, $0.z)) ?? false) }
            // One vote per cell: a cell with many readings must not drown a disagreeing neighbour.
            guard !near.isEmpty, let pooled = LiDARMagnetic.offset(near.map(\.offset.mean_deg)) else { return nil }
            let between = near.map { abs(LiDARMagnetic.wrap($0.offset.mean_deg - pooled.mean_deg)) }.max() ?? 0
            guard between <= 15 else { return nil }
            let within = near.map(\.offset.spread_deg).max() ?? 0
            return Offset(mean_deg: pooled.mean_deg, spread_deg: max(within, between), p90_deg: max(near.map(\.offset.p90_deg).max() ?? 0, between),
                          count: near.reduce(0) { $0 + $1.offset.count })
        }
    }
    /// Cells need at least `minSamples` readings and a spread of at most `maxSpreadDeg`.
    public static func reference(_ samples: [LiDARMagneticSample], cell: Double = 3, minSamples: Int = 5, maxSpreadDeg: Double = 15) -> Reference {
        var buckets = [String: (x: Double, z: Double, n: Int, values: [Double])]()
        for o in offsets(samples) {
            let key = "\(Int(floor(o.position.x / cell))),\(Int(floor(o.position.z / cell)))"
            var b = buckets[key] ?? (0, 0, 0, []); b.x += o.position.x; b.z += o.position.z; b.n += 1; b.values.append(o.offset); buckets[key] = b
        }
        let cells = buckets.sorted { $0.key < $1.key }.compactMap { _, b -> Reference.Cell? in
            guard b.n >= minSamples, let off = offset(b.values), off.spread_deg <= maxSpreadDeg else { return nil }
            return .init(x: b.x / Double(b.n), z: b.z / Double(b.n), offset: off)
        }
        return Reference(cell_m: cell, cells: cells)
    }
    public struct Check: Codable, Equatable {
        /// consistent | conflict | uncertain | unavailable
        public var status: String
        public var delta_deg: Double?
        public var query: Offset?, map: Offset?
        public var reason: String?
        /// "local" (cells near the candidate) or "global" (whole-map fallback).
        public var reference_scope: String?
    }
    /// Recorded runs: user-confirmed candidates were at most 22–24° off; 180° flips 158–178°,
    /// a 90° wrong pick about 75°. Conflict starts at 60°, so fine yaw is never judged here.
    public static func check(_ query: [LiDARMagneticSample], transform: [[Double]], reference: Reference?,
                             minQuery: Int = 8, consistentDeg: Double = 45, conflictDeg: Double = 60,
                             structure: LiDARStructureGrid? = nil) -> Check {
        guard let reference, reference.method == method, reference.schema_version == 1 else { return .init(status: "unavailable", reason: "no_map_reference") }
        let moved = offsets(query, transform: transform)
        guard moved.count >= minQuery, let q = offset(moved.map(\.offset)), q.spread_deg <= 15 else {
            let notUpright = query.filter { cameraAzimuth($0.camera_to_session) == nil }.count
            let reason = moved.count >= minQuery ? "query_spread" : query.count >= minQuery && notUpright * 2 >= query.count ? "phone_not_upright" : "too_few_query_samples"
            return .init(status: "unavailable", query: offset(moved.map(\.offset)), reason: reason)
        }
        let centre = moved[moved.count / 2].position
        var scope = "local"
        guard let m = reference.local(at: centre, structure: structure) ?? { scope = "global"; return reference.global() }() else {
            return .init(status: "unavailable", query: q, reason: "no_reference_near_candidate")
        }
        let delta = wrap(q.mean_deg - m.mean_deg)
        let status = abs(delta) <= consistentDeg ? "consistent" : abs(delta) >= conflictDeg ? "conflict" : "uncertain"
        return .init(status: status, delta_deg: delta, query: q, map: m, reason: nil, reference_scope: scope)
    }
    public struct Screen: Codable, Equatable {
        public var method = LiDARMagnetic.method
        /// False when the result had no opposite-yaw ambiguity or the evidence could not decide.
        public var applied: Bool
        public var checks: [Check]
        /// Candidate indices the compass argues against; they stay in the result for review.
        public var suppressed: [Int]
        public var remaining: Int
        public var reason: String
    }
    /// Only for ambiguous results (several plausible poses), and only when at least one candidate agrees:
    /// if every candidate conflicts or the evidence is thin, nothing is suppressed.
    public static func screen(candidateTransforms: [[[Double]]], decisionReasons: [String],
                              query: [LiDARMagneticSample], reference: Reference?, structure: LiDARStructureGrid? = nil) -> Screen {
        let checks = candidateTransforms.map { check(query, transform: $0, reference: reference, structure: structure) }
        guard !Set(decisionReasons).isDisjoint(with: ["opposite_yaw_mode", "multiple_modes", "same_yaw_rival", "along_axis_spread", "multiple_plate_windows", "multiple_windows"]) else {
            return Screen(applied: false, checks: checks, suppressed: [], remaining: checks.count, reason: "no_ambiguity")
        }
        let agree = checks.indices.filter { checks[$0].status == "consistent" }
        let against = checks.indices.filter { checks[$0].status == "conflict" }
        guard !agree.isEmpty, !against.isEmpty else {
            return Screen(applied: false, checks: checks, suppressed: [], remaining: checks.count, reason: agree.isEmpty ? "no_candidate_consistent" : "no_candidate_conflicts")
        }
        return Screen(applied: true, checks: checks, suppressed: against, remaining: checks.count - against.count, reason: "opposite_yaw_conflicts_suppressed")
    }
}

// MARK: - Point-cloud overlay check (visual aid for reviewing a candidate or a supplement scan)

/// Compares a stored map point, moved into the live camera, with the live LiDAR depth at its pixel.
/// Depths are along the optical axis in metres. A map point well in front of the measured surface
/// sits in space the sensor sees through: that contradicts the alignment. One behind it is only
/// hidden. Agreement here shows the surfaces line up; it is not a measured localization error.
public enum LiDAROverlayCheck {
    public enum Status: String, Codable { case aligned, contradicted, occluded, unknown }
    public static func tolerance(measured: Double, base: Double = 0.10) -> Double { max(base, 0.03 * measured) }
    /// `confidence` is ARKit's 0/1/2; low confidence or missing depth gives unknown.
    public static func classify(expectedDepth e: Double, measuredDepth m: Double?, confidence: Int?, base: Double = 0.10) -> Status {
        guard e.isFinite, e > 0.2, let m, m.isFinite, (0.2...5).contains(m), (confidence ?? 0) >= 1 else { return .unknown }
        let tol = tolerance(measured: m, base: base)
        if abs(e - m) <= tol { return .aligned }
        return e < m - tol ? .contradicted : .occluded
    }
    public struct Summary: Codable, Equatable {
        public var aligned = 0, contradicted = 0, occluded = 0, unknown = 0
        /// aligned / (aligned + contradicted); nil until enough points are comparable.
        public var alignedFraction: Double? {
            let n = aligned + contradicted
            return n >= 50 ? Double(aligned) / Double(n) : nil
        }
        public init() {}
        public mutating func add(_ s: Status) {
            switch s { case .aligned: aligned += 1; case .contradicted: contradicted += 1; case .occluded: occluded += 1; case .unknown: unknown += 1 }
        }
    }
}


extension LiDARMagnetic {
    /// Paired readings from a magnetic-heading.jsonl log (App schema 2): valid heading, valid
    /// camera pairing, optionally one AR session. Poses stay in that session's coordinates.
    public static func samples(jsonl data: Data, sessionID: String? = nil) -> [LiDARMagneticSample] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["measurement_valid"] as? Bool == true, o["camera_pairing_valid"] as? Bool == true,
                  sessionID == nil || o["ar_session_id"] as? String == sessionID,
                  let h = o["magnetic_heading_deg"] as? Double, let a = o["heading_accuracy_deg"] as? Double,
                  let t = o["camera_to_session"] as? [[Double]], RigidMatrix.valid(t) else { return nil }
            return LiDARMagneticSample(timestamp: o["timestamp"] as? Double ?? 0, heading: h, accuracy: a, cameraToSession: t)
        }
    }
    /// Moves samples of another session into map coordinates (supplement scans).
    public static func moved(_ samples: [LiDARMagneticSample], by mapFromSession: [[Double]]) -> [LiDARMagneticSample] {
        samples.map { var s = $0; s.camera_to_session = CampusMapGeometry.multiply(mapFromSession, $0.camera_to_session); return s }
    }
}

/// Wall-height occupancy of a map (10 cm voxels, 0.5–1.8 m above the floor) for "is there stored
/// structure between these two places" questions. Unscanned space counts as open.
public struct LiDARStructureGrid {
    public let floorY: Double, voxel: Double
    private let occupied: Set<LiDARVoxelKey>
    public init(points: [ProbePoint], voxel: Double = 0.10) {
        let floor = LiDARSampling.floorHeight(LiDARSampling.sample(points, limit: 4_000))
        floorY = floor; self.voxel = voxel
        occupied = Set(points.filter { $0.y >= floor + 0.5 && $0.y <= floor + 1.8 }.map { LiDARVoxelKey($0, size: voxel) })
    }
    public func crosses(from a: ProbePoint, to b: ProbePoint) -> Bool {
        let d = hypot(b.x - a.x, b.z - a.z), steps = max(1, Int(d / (voxel / 2)))
        var run = 0
        for i in 0...steps {
            let t = Double(i) / Double(steps), x = a.x + (b.x - a.x) * t, z = a.z + (b.z - a.z) * t
            var hit = false
            for y in stride(from: floorY + 0.5, through: floorY + 1.8, by: voxel) where occupied.contains(LiDARVoxelKey(ProbePoint(x, y, z), size: voxel)) { hit = true; break }
            run = hit ? run + 1 : 0
            if run >= 2 { return true }
        }
        return false
    }
}

// MARK: - Plate-guided relocalization

/// A confirmed plate text names a room, not a door: every entrance and measured plate of that
/// room becomes a search window, and the windows are compared rather than stopping at the first.
public enum LiDARPlateSearch {
    public struct Center: Codable, Equatable {
        public var position: ProbePoint
        public var landmark_id: String?, node_id: String?
        /// "entrance" (route node) or "plate" (measured plate centre)
        public var source: String
    }
    /// Exact normalized text only; tolerant matching would confuse neighbouring room numbers.
    public static func centers(text: String, landmarks: [LiDARLandmark], map: LiDARNavigationMap, mergeRadius: Double = 1.0) -> [Center] {
        let key = LiDARText.normalize(text)
        guard !key.isEmpty else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        var out = [Center]()
        func add(_ c: Center) { if !out.contains(where: { hypot($0.position.x - c.position.x, $0.position.z - c.position.z) < mergeRadius }) { out.append(c) } }
        for l in landmarks where l.category == .room_plate && LiDARText.normalize(l.text.raw) == key {
            if let id = l.destination.node_id, let n = byID[id] { add(Center(position: n.position, landmark_id: l.id, node_id: id, source: "entrance")) }
            if l.geometry.status == "measured", let c = l.geometry.center { add(Center(position: c, landmark_id: l.id, node_id: nil, source: "plate")) }
        }
        // Room nodes by name only when no plate is bound to them: a plate's entrance carries its
        // display name, which must never act as a recognition alias.
        let plateBound = Set(landmarks.compactMap { $0.destination.node_id })
        for n in map.nodes where n.resolvedKind == .room && !plateBound.contains(n.id) && LiDARText.normalize(n.name) == key {
            add(Center(position: n.position, landmark_id: nil, node_id: n.id, source: "entrance"))
        }
        return out
    }
    static func yaw(_ t: [[Double]]) -> Double { atan2(t[0][2], t[0][0]) * 180 / .pi }
    /// 4-DoF query→map transform from one wall plate seen in both: yaw turns the query wall normal
    /// onto the map normal, translation maps the centres. nil unless both are measured.
    public static func poseFromPlate(query q: LiDARLandmarkGeometryResult, map m: LiDARLandmarkGeometryResult) -> [[Double]]? {
        guard q.status == "measured", m.status == "measured", let qc = q.center, let qn = q.normal, let mc = m.center, let mn = m.normal,
              hypot(qn.x, qn.z) > 0.5, hypot(mn.x, mn.z) > 0.5 else { return nil }
        let theta = atan2(qn.z * mn.x - qn.x * mn.z, qn.x * mn.x + qn.z * mn.z), c = cos(theta), s = sin(theta)
        let rx = c * qc.x + s * qc.z, rz = -s * qc.x + c * qc.z
        return [[c, 0, s, mc.x - rx], [0, 1, 0, mc.y - qc.y], [-s, 0, c, mc.z - rz], [0, 0, 0, 1]]
    }
    /// How far a candidate puts the query plate from the plate-derived pose, and their yaw gap.
    public static func agreement(candidate: [[Double]], plate: [[Double]], at p: ProbePoint) -> (distance_m: Double, yaw_deg: Double) {
        let a = CampusMapGeometry.point([p.x, p.y, p.z], through: candidate), b = CampusMapGeometry.point([p.x, p.y, p.z], through: plate)
        return (hypot(a[0] - b[0], a[2] - b[2]), abs(LiDARMagnetic.wrap(yaw(candidate) - yaw(plate))))
    }
    /// Windowed search around every centre; passing candidates from overlapping windows that land
    /// on the same pose (camera within 0.5 m, yaw within 10°) count once. One distinct passing
    /// candidate → review; several → ambiguous with every one kept. A plate pose, when given,
    /// only reorders and annotates: it never promotes a candidate on its own.
    public static func solve(map: [ProbePoint], query: [ProbePoint], sessionID: String, referenceCamera: ProbePoint,
                             centers: [Center], radii: [Double] = [6, 10], maxSeconds: Double = 12,
                             cancellation: LiDARWorkCancellation = LiDARWorkCancellation(),
                             platePose: [[Double]]? = nil, platePoint: ProbePoint? = nil,
                             yawPrior: (center: Double, halfWidth: Double)? = nil,
                             scopeKind: String = "plate_entrance_windows") -> LiDARLocalizationResult {
        let start = ProcessInfo.processInfo.systemUptime, tiled = scopeKind == "tiled_global"
        var tiers = [LiDARLocalizationResult](), windows = [String]()
        for (i, c) in centers.enumerated() {
            let label = c.source + ":" + (c.node_id ?? c.landmark_id ?? "?")
            let left = maxSeconds - (ProcessInfo.processInfo.systemUptime - start)
            guard left > 0.3 || tiers.isEmpty, !cancellation.isCancelled else { windows.append(label + ":none:not_searched"); continue }
            let budget = max(0.5, left / Double(centers.count - i))
            if let last = LiDARLocalizer.solveWindowed(map: map, query: query, sessionID: sessionID, referenceCamera: referenceCamera,
                    center: c.position, centerNodeID: c.node_id, radii: radii, maxSeconds: budget, cancellation: cancellation, yawPrior: yawPrior).tiers.last {
                tiers.append(last)
                let done = last.search_complete == true && !["timeout", "cancelled"].contains(last.status)
                windows.append(label + ":" + last.status + ":" + (done ? "complete" : "incomplete"))
            } else { windows.append(label + ":none:not_searched") }
        }
        // A single answer needs every planned window searched to completion.
        let complete = windows.allSatisfy { $0.hasSuffix(":complete") }
        guard var base = tiers.max(by: { ($0.candidates.first?.geometry_score ?? -1) < ($1.candidates.first?.geometry_score ?? -1) }) else {
            return LiDARLocalizer.solve(map: [], query: query, sessionID: sessionID, maxSeconds: 0.1)
        }
        func camera(_ t: [[Double]]) -> [Double] { CampusMapGeometry.point([referenceCamera.x, referenceCamera.y, referenceCamera.z], through: t) }
        var distinct = [LiDARLocalizationCandidate]()
        for cand in tiers.flatMap({ $0.candidates.filter(\.quality_gate) }).sorted(by: { $0.geometry_score > $1.geometry_score }) {
            let p = camera(cand.transform_query_to_map)
            let same = distinct.contains { d in
                let q = camera(d.transform_query_to_map)
                return hypot(p[0] - q[0], p[2] - q[2]) < 0.5 && abs(LiDARMagnetic.wrap(yaw(d.transform_query_to_map) - yaw(cand.transform_query_to_map))) < 10
            }
            if !same { distinct.append(cand) }
        }
        var reasons = Set(tiers.flatMap { $0.decision_reasons ?? [] })
        if !distinct.isEmpty {
            if let platePose, let platePoint {
                let agrees = distinct.indices.filter { let a = agreement(candidate: distinct[$0].transform_query_to_map, plate: platePose, at: platePoint); return a.distance_m < 0.75 && a.yaw_deg < 15 }
                if agrees.count == 1 && distinct.count > 1 { distinct.insert(distinct.remove(at: agrees[0]), at: 0); reasons.insert("plate_pose_supports_one") }
                else if agrees.isEmpty { reasons.insert("plate_pose_disagrees") }
            }
            base.candidates = distinct
            if distinct.count == 1 && complete && !tiers.contains(where: { $0.status == "ambiguous" }) {
                base.status = "candidate_requires_review"
                base.reason = tiled ? "全图分块搜索找到唯一几何候选，需现场核对" : "门牌对应的入口附近找到唯一几何候选，需现场核对"
            } else if !complete {
                base.status = "ambiguous"; reasons.insert(tiled ? "windows_incomplete" : "plate_windows_incomplete")
                base.reason = tiled ? "大图未在时限内搜索完全部区域，结果不能视为唯一，请核对、选起点或重试" : "部分入口附近尚未搜索完，结果不能视为唯一，请核对或重试"
            } else {
                base.status = "ambiguous"; reasons.insert(tiled ? "multiple_windows" : "multiple_plate_windows")
                base.reason = tiled ? "全图多个区域都有几何候选，请逐个核对" : "门牌对应的多个入口附近都有几何候选，请逐个核对"
            }
        }
        base.plate_windows = windows; base.search_complete = complete
        base.incomplete_reasons = complete ? nil : [tiled ? "windows_incomplete" : "plate_windows_incomplete"]
        base.decision_reasons = reasons.sorted()
        base.search_scope?.kind = scopeKind; base.search_scope?.tiers_tried = tiers.count
        base.registration_seconds = ProcessInfo.processInfo.systemUptime - start
        return base
    }
}


extension LiDARMagnetic {
    /// Yaw of the query→map transform implied by the compass (degrees, the solver's yaw):
    /// map offset = query offset + yaw. Uses cells near `near` when given, else the whole-map
    /// offset when the map agrees with itself. nil when either side is unreliable.
    /// The half width is 15° plus the measured spreads of both sides (at most 35°): the restricted
    /// search, and any unique answer in it, holds only within that window.
    public static func yawPrior(query: [LiDARMagneticSample], reference: Reference?, near: ProbePoint? = nil,
                                structure: LiDARStructureGrid? = nil) -> (center: Double, halfWidth: Double, scope: String)? {
        guard let reference, reference.method == method else { return nil }
        let q = offsets(query)
        guard q.count >= 8, let qo = offset(q.map(\.offset)), qo.spread_deg <= 15 else { return nil }
        func width(_ m: Offset) -> Double { min(35, 15 + qo.spread_deg + m.spread_deg) }
        if let near, let m = reference.local(at: near, radius: 8, structure: structure) { return (wrap(m.mean_deg - qo.mean_deg), width(m), "local") }
        guard let g = reference.global() else { return nil }
        return (wrap(g.mean_deg - qo.mean_deg), width(g), "global")
    }
}

// MARK: - Wall-foot and corner lines (display and alignment check)

/// Straight wall runs found in a point cloud's floor plan. A run is fitted to many points, so its
/// position is far steadier than any single point; it is still a fit, not a surveyed line.
public struct LiDARStructureLine: Codable, Equatable {
    /// "wall_foot": where a wall meets the floor; "corner": vertical line where two walls meet.
    public var kind: String
    public var a: ProbePoint, b: ProbePoint
    /// Points supporting the fit, and their RMS distance to the line (metres).
    public var support: Int
    public var rms_m: Double
    public var length: Double { sqrt(pow(b.x-a.x,2)+pow(b.y-a.y,2)+pow(b.z-a.z,2)) }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15; var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

public enum LiDARStructureLines {
    public struct Settings: Equatable {
        public var cell_m = 0.10, min_height_m = 0.6, band = 0.3...2.2
        public var inlier_m = 0.08, min_length_m = 1.0, min_cells = 12, max_gap_m = 0.5, max_lines = 120
        public init() {}
    }
    private struct Key: Hashable { let x: Int, z: Int }
    public static func extract(_ points: [ProbePoint], floorY: Double? = nil, settings k: Settings = Settings()) -> [LiDARStructureLine] {
        guard points.count >= 100 else { return [] }
        let floorLevel = floorY ?? LiDARSampling.floorHeight(LiDARSampling.sample(points, limit: 4_000))
        // Floor-plan cells with points spanning enough height are wall cells.
        var columns = [Key: (lo: Double, hi: Double, pts: [ProbePoint])]()
        for p in points where p.y >= floorLevel + k.band.lowerBound && p.y <= floorLevel + k.band.upperBound {
            let key = Key(x: Int(floor(p.x / k.cell_m)), z: Int(floor(p.z / k.cell_m)))
            var c = columns[key] ?? (p.y, p.y, []); c.lo = min(c.lo, p.y); c.hi = max(c.hi, p.y); c.pts.append(p); columns[key] = c
        }
        var remaining = Set(columns.filter { $0.value.hi - $0.value.lo >= k.min_height_m }.keys)
        func centre(_ key: Key) -> (Double, Double) { ((Double(key.x) + 0.5) * k.cell_m, (Double(key.z) + 0.5) * k.cell_m) }
        var walls = [LiDARStructureLine]()
        // Fixed seed: the same cloud always gives the same lines, so redrawing does not flicker.
        var rng = SplitMix(seed: UInt64(points.count))
        // Greedy RANSAC: take the best-supported line among random cell pairs, refine with PCA, cut at gaps.
        while remaining.count >= k.min_cells, walls.count < k.max_lines {
            let cells = Array(remaining)
            var best: (inliers: [Key], nx: Double, nz: Double, d: Double)?
            for _ in 0..<min(300, cells.count * 2) {
                let p = centre(cells.randomElement(using: &rng)!), q = centre(cells.randomElement(using: &rng)!)
                let dx = q.0 - p.0, dz = q.1 - p.1, len = hypot(dx, dz)
                guard len >= 0.5 else { continue }
                let nx = -dz / len, nz = dx / len, d = nx * p.0 + nz * p.1
                let inliers = cells.filter { let c = centre($0); return abs(nx * c.0 + nz * c.1 - d) <= k.inlier_m }
                if inliers.count > (best?.inliers.count ?? 0) { best = (inliers, nx, nz, d) }
            }
            guard let found = best, found.inliers.count >= k.min_cells else { break }
            // PCA on the actual points of the inlier cells.
            let pts = found.inliers.flatMap { columns[$0]!.pts }
            let mx = pts.reduce(0) { $0 + $1.x } / Double(pts.count), mz = pts.reduce(0) { $0 + $1.z } / Double(pts.count)
            var sxx = 0.0, sxz = 0.0, szz = 0.0
            for p in pts { sxx += (p.x - mx) * (p.x - mx); sxz += (p.x - mx) * (p.z - mz); szz += (p.z - mz) * (p.z - mz) }
            let angle = 0.5 * atan2(2 * sxz, sxx - szz), ux = cos(angle), uz = sin(angle)
            // Split along the direction where consecutive points leave a gap.
            let along = pts.map { (t: ($0.x - mx) * ux + ($0.z - mz) * uz, off: -($0.x - mx) * uz + ($0.z - mz) * ux) }.sorted { $0.t < $1.t }
            var start = 0
            func emit(_ lo: Int, _ hi: Int) {
                let seg = along[lo...hi], t0 = seg.first!.t, t1 = seg.last!.t
                guard t1 - t0 >= k.min_length_m, seg.count >= k.min_cells * 3 else { return }
                let rms = sqrt(seg.reduce(0) { $0 + $1.off * $1.off } / Double(seg.count))
                walls.append(LiDARStructureLine(kind: "wall_foot", a: ProbePoint(mx + ux * t0, floorLevel, mz + uz * t0),
                                                b: ProbePoint(mx + ux * t1, floorLevel, mz + uz * t1), support: seg.count, rms_m: rms))
            }
            for i in 1..<along.count where along[i].t - along[i - 1].t > k.max_gap_m { emit(start, i - 1); start = i }
            emit(start, along.count - 1)
            remaining.subtract(found.inliers)
        }
        // Corners: wall ends that meet at 60–120°.
        var corners = [LiDARStructureLine]()
        for i in walls.indices { for j in walls.indices where j > i {
            let w = walls[i], v = walls[j]
            let ux = (w.b.x - w.a.x) / w.length, uz = (w.b.z - w.a.z) / w.length, vx = (v.b.x - v.a.x) / v.length, vz = (v.b.z - v.a.z) / v.length
            let cross = ux * vz - uz * vx, dot = ux * vx + uz * vz
            let deg = abs(atan2(cross, dot)) * 180 / .pi
            guard deg >= 60, deg <= 120, abs(cross) > 1e-6 else { continue }
            let t = ((v.a.x - w.a.x) * vz - (v.a.z - w.a.z) * vx) / cross
            let x = w.a.x + ux * t, z = w.a.z + uz * t
            func near(_ l: LiDARStructureLine) -> Bool { min(hypot(l.a.x - x, l.a.z - z), hypot(l.b.x - x, l.b.z - z)) <= 0.4 }
            guard near(w), near(v) else { continue }
            corners.append(LiDARStructureLine(kind: "corner", a: ProbePoint(x, floorLevel, z), b: ProbePoint(x, floorLevel + 2.2, z),
                                              support: min(w.support, v.support), rms_m: max(w.rms_m, v.rms_m)))
        } }
        return walls + corners
    }
    public struct Comparison: Codable, Equatable {
        public var matched: Int, compared: Int
        /// Median perpendicular offset (m) and angle (deg) of matched wall-foot lines.
        public var median_offset_m: Double?, median_angle_deg: Double?
    }
    /// Matches each live wall-foot line to the nearest map line of similar direction (≤ 10°, ≤ 0.5 m).
    /// Both sets must be in the same coordinates. Few matches mean "not comparable", not "aligned".
    public static func compare(map: [LiDARStructureLine], live: [LiDARStructureLine], maxOffset: Double = 0.5, maxAngle: Double = 10) -> Comparison {
        let m = map.filter { $0.kind == "wall_foot" }, l = live.filter { $0.kind == "wall_foot" && $0.length >= 1 }
        var offsets = [Double](), angles = [Double]()
        for line in l {
            let mid = ProbePoint((line.a.x + line.b.x) / 2, 0, (line.a.z + line.b.z) / 2), lx = (line.b.x - line.a.x) / line.length, lz = (line.b.z - line.a.z) / line.length
            var best: (Double, Double)?
            for c in m {
                let cx = (c.b.x - c.a.x) / c.length, cz = (c.b.z - c.a.z) / c.length
                let ang = acos(min(1, abs(lx * cx + lz * cz))) * 180 / .pi
                guard ang <= maxAngle else { continue }
                let t = (mid.x - c.a.x) * cx + (mid.z - c.a.z) * cz
                guard t >= -0.5, t <= c.length + 0.5 else { continue }
                let off = abs(-(mid.x - c.a.x) * cz + (mid.z - c.a.z) * cx)
                if off <= maxOffset, off < (best?.0 ?? .infinity) { best = (off, ang) }
            }
            if let best { offsets.append(best.0); angles.append(best.1) }
        }
        func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
        return Comparison(matched: offsets.count, compared: l.count, median_offset_m: median(offsets), median_angle_deg: median(angles))
    }
}

extension LiDARStructureLine {
    /// The line moved by a row-major rigid transform.
    public func moved(_ t: [[Double]]) -> LiDARStructureLine {
        let p = CampusMapGeometry.point([a.x, a.y, a.z], through: t), q = CampusMapGeometry.point([b.x, b.y, b.z], through: t)
        var r = self; r.a = ProbePoint(p[0], p[1], p[2]); r.b = ProbePoint(q[0], q[1], q[2]); return r
    }
}

/// Fast provisional correction from the first refresh frames' wall-foot lines, used before the full
/// re-localization returns. Only when both sides of a corridor show regular parallel wall feet:
/// - corridor: lateral shift and yaw that put the live walls onto the map's corridor walls;
/// - corner: additionally the along-corridor shift that puts a live wall corner onto the map
///   corner at the route's next turn (larger range).
/// Live lines must be in map coordinates under the current alignment. Ambiguous, one-sided or
/// out-of-range cases return nil with a reason; the result is a map→map correction.
public enum LiDARQuickCorrection {
    public struct Limits: Equatable {
        public var lateral_m = 1.5, yaw_deg = 10.0, corner_along_m = 3.0, corner_lateral_m = 1.5
        public var radius_m = 6.0, turn_ahead_m = 10.0
        /// "Regular wall feet" on each side: at least this much line, offsets agreeing within side_sd_m.
        public var side_min_m = 1.0, side_sd_m = 0.12
        public init() {}
    }
    public struct Result: Codable, Equatable {
        public var kind: String          // "corridor" | "corner"
        public var lateral_m: Double, along_m: Double, yaw_deg: Double
        public var corridor_width_m: Double
        /// Corridor direction in the map (degrees, atan2(z, x)).
        public var axis_deg: Double
        /// Map→map correction; the new alignment is correction × current.
        public var correction: [[Double]]
    }
    private struct Wall { let mid: (x: Double, z: Double); let angle: Double; let length: Double }
    private static func axial(_ a: Double) -> Double { var r = a.truncatingRemainder(dividingBy: .pi); if r < 0 { r += .pi }; return r }
    /// Signed smallest difference between two axial angles (radians, in (-π/2, π/2]).
    private static func axialDelta(_ a: Double, _ b: Double) -> Double { var d = remainder(a - b, .pi); if d <= -.pi / 2 { d += .pi }; return d }
    private static func walls(_ lines: [LiDARStructureLine], near p: ProbePoint, radius: Double, minLength: Double) -> [Wall] {
        lines.compactMap { l in
            guard l.kind == "wall_foot", l.length >= minLength else { return nil }
            let m = ((l.a.x + l.b.x) / 2, (l.a.z + l.b.z) / 2)
            guard hypot(m.0 - p.x, m.1 - p.z) <= radius else { return nil }
            return Wall(mid: m, angle: axial(atan2(l.b.z - l.a.z, l.b.x - l.a.x)), length: hypot(l.b.x - l.a.x, l.b.z - l.a.z))
        }
    }
    /// First route vertex within `ahead` metres (along the route from the closest point) that turns ≥ 45°.
    static func nextTurn(_ route: [ProbePoint], from p: ProbePoint, ahead: Double) -> ProbePoint? {
        guard route.count >= 3 else { return nil }
        var best = 0, bestD = Double.infinity
        for (i, q) in route.enumerated() { let d = hypot(q.x - p.x, q.z - p.z); if d < bestD { bestD = d; best = i } }
        var walked = 0.0
        for i in max(1, best)..<(route.count - 1) {
            walked += hypot(route[i].x - route[i - 1].x, route[i].z - route[i - 1].z) * (i == best ? 0 : 1)
            if walked > ahead { return nil }
            let a = atan2(route[i].z - route[i - 1].z, route[i].x - route[i - 1].x), b = atan2(route[i + 1].z - route[i].z, route[i + 1].x - route[i].x)
            if abs(remainder(b - a, 2 * .pi)) >= .pi / 4 { return route[i] }
        }
        return nil
    }
    public static func estimate(map: [LiDARStructureLine], live: [LiDARStructureLine], position p: ProbePoint, route: [ProbePoint],
                                limits k: Limits = Limits()) -> (result: Result?, reason: String) {
        let lw = walls(live, near: p, radius: k.radius_m, minLength: 0.8)
        guard lw.count >= 2 else { return (nil, "too_few_live_walls") }
        // Dominant corridor direction: the angle with the most wall length within 10°.
        let tol = 10 * Double.pi / 180
        guard let seed = lw.max(by: { a, b in
            lw.filter { abs(axialDelta($0.angle, a.angle)) <= tol }.reduce(0) { $0 + $1.length } <
            lw.filter { abs(axialDelta($0.angle, b.angle)) <= tol }.reduce(0) { $0 + $1.length } }) else { return (nil, "too_few_live_walls") }
        let parallel = lw.filter { abs(axialDelta($0.angle, seed.angle)) <= tol }
        let total = parallel.reduce(0) { $0 + $1.length }
        let theta = seed.angle + parallel.reduce(0) { $0 + axialDelta($1.angle, seed.angle) * $1.length } / total
        let d = (x: cos(theta), z: sin(theta)), n = (x: -sin(theta), z: cos(theta))
        // Signed distance from the person to the wall's own line (normal oriented like n): unaffected
        // by a rotation about the person, so shift and yaw stay separate.
        func s(_ w: Wall) -> Double {
            let a = theta + axialDelta(w.angle, theta)
            return (w.mid.x - p.x) * -sin(a) + (w.mid.z - p.z) * cos(a)
        }
        // Both sides need regular wall feet (side_min_m of line each, offsets agreeing within side_sd_m).
        func side(_ ws: [Wall]) -> Double? {
            let len = ws.reduce(0) { $0 + $1.length }
            guard len >= k.side_min_m else { return nil }
            let mean = ws.reduce(0) { $0 + s($1) * $1.length } / len
            let sd = sqrt(ws.reduce(0) { $0 + pow(s($1) - mean, 2) * $1.length } / len)
            return sd <= k.side_sd_m ? mean : nil
        }
        guard let sl = side(parallel.filter { s($0) > 0.3 }), let sr = side(parallel.filter { s($0) < -0.3 }) else { return (nil, "no_regular_walls_both_sides") }
        let width = sl - sr
        guard (0.8...8).contains(width) else { return (nil, "implausible_corridor_width") }
        // Map corridor walls nearby, parallel within the yaw limit, covering the person's stretch.
        let yawTol = k.yaw_deg * Double.pi / 180
        let mw = walls(map, near: p, radius: k.radius_m + 4, minLength: 0.5).filter { abs(axialDelta($0.angle, theta)) <= yawTol }
        func along(_ w: Wall) -> Double { (w.mid.x - p.x) * d.x + (w.mid.z - p.z) * d.z }
        let beside = mw.filter { abs(along($0)) <= $0.length / 2 + 2 }
        let window = k.lateral_m + 0.3
        let left = beside.filter { abs(s($0) - sl) <= window }, right = beside.filter { abs(s($0) - sr) <= window }
        var options = [(shift: Double, yaw: Double)]()
        for a in left { for b in right {
            let da = s(a) - sl, db = s(b) - sr
            guard abs(da - db) <= 0.3, abs((s(a) - s(b)) - width) <= 0.3 else { continue }
            let yaw = (axialDelta(a.angle, theta) * a.length + axialDelta(b.angle, theta) * b.length) / (a.length + b.length)
            options.append(((da + db) / 2, yaw))
        } }
        guard let best = options.min(by: { abs($0.shift) < abs($1.shift) }) else { return (nil, "no_matching_map_corridor") }
        if options.contains(where: { abs($0.shift - best.shift) > 0.4 }) { return (nil, "ambiguous_map_corridor") }
        guard abs(best.shift) <= k.lateral_m, abs(best.yaw) <= yawTol else { return (nil, "beyond_corridor_limits") }
        func correction(_ shift: (x: Double, z: Double), _ delta: Double) -> [[Double]] {
            let c = cos(delta), sn = sin(delta)
            return [[c, 0, -sn, p.x - c * p.x + sn * p.z + shift.x], [0, 1, 0, 0], [sn, 0, c, p.z - sn * p.x - c * p.z + shift.z], [0, 0, 0, 1]]
        }
        var result = Result(kind: "corridor", lateral_m: best.shift, along_m: 0, yaw_deg: best.yaw * 180 / .pi, corridor_width_m: width,
                            axis_deg: (theta + best.yaw) * 180 / .pi, correction: correction((n.x * best.shift, n.z * best.shift), best.yaw))
        // Corner: a live wall corner near the route's next turn, matched uniquely to a map corner.
        guard let turn = nextTurn(route, from: p, ahead: k.turn_ahead_m) else { return (result, "corridor") }
        let moved = live.filter { $0.kind == "corner" }.map { $0.moved(result.correction) }
            .map { (x: $0.a.x, z: $0.a.z) }.filter { hypot($0.x - p.x, $0.z - p.z) <= k.radius_m && hypot($0.x - turn.x, $0.z - turn.z) <= 4 }
        let mapCorners = map.filter { $0.kind == "corner" }.map { (x: $0.a.x, z: $0.a.z) }.filter { hypot($0.x - turn.x, $0.z - turn.z) <= 4 + k.corner_along_m }
        var pick: (along: Double, lateral: Double)?
        for c in moved {
            let ranked = mapCorners.map { m -> (along: Double, lateral: Double, dist: Double) in
                let dx = m.x - c.x, dz = m.z - c.z
                return (dx * d.x + dz * d.z, dx * n.x + dz * n.z, hypot(dx, dz))
            }.filter { abs($0.along) <= k.corner_along_m && abs($0.lateral) <= 0.3 }.sorted { $0.dist < $1.dist }
            guard let first = ranked.first else { continue }
            if ranked.count > 1 && ranked[1].dist - first.dist < 0.8 { continue }
            if pick == nil || abs(first.along) < abs(pick!.along) { pick = (first.along, first.lateral) }
        }
        guard let corner = pick else { return (result, "corridor") }
        let lateral = best.shift + corner.lateral
        guard abs(lateral) <= k.corner_lateral_m else { return (result, "corridor") }
        result.kind = "corner"; result.along_m = corner.along; result.lateral_m = lateral
        result.correction = correction((n.x * lateral + d.x * corner.along, n.z * lateral + d.z * corner.along), best.yaw)
        return (result, "corner")
    }
}


extension LiDARLocalizer {
    /// Global search without a start node. Maps up to 45 m across use the single dense search;
    /// larger maps are searched in overlapping windows (radius 15 m, every 20 m where the map has
    /// structure), merged and deduplicated; a single answer needs every window complete.
    public static func solveGlobal(map: [ProbePoint], query: [ProbePoint], sessionID: String, referenceCamera: ProbePoint,
                                   maxSeconds: Double = 20, cancellation: LiDARWorkCancellation = LiDARWorkCancellation(),
                                   yawPrior: (center: Double, halfWidth: Double)? = nil, near: ProbePoint? = nil) -> LiDARLocalizationResult {
        let centers = tileCenters(map)
        guard centers.count > 1 else { return solve(map: map, query: query, sessionID: sessionID, maxSeconds: maxSeconds, cancellation: cancellation, yawPrior: yawPrior) }
        // Search near the last known place first so a timeout still covers the likely area.
        let ordered = near.map { n in centers.sorted { hypot($0.x - n.x, $0.z - n.z) < hypot($1.x - n.x, $1.z - n.z) } } ?? centers
        let windows = ordered.enumerated().map { LiDARPlateSearch.Center(position: $1, landmark_id: nil, node_id: "tile\($0)", source: "tile") }
        return LiDARPlateSearch.solve(map: map, query: query, sessionID: sessionID, referenceCamera: referenceCamera, centers: windows,
                                      radii: [15], maxSeconds: maxSeconds, cancellation: cancellation, yawPrior: yawPrior, scopeKind: "tiled_global")
    }
    /// Window centres on a `step` grid. A centre is kept when any map point falls in its own grid
    /// square (|dx|, |dz| ≤ step/2), so every place with map structure is within step/√2 of a kept
    /// centre — inside the 15 m candidate radius when step = 20. Nothing is dropped by a distance cut.
    public static func tileCenters(_ map: [ProbePoint], step: Double = 20, singleExtent: Double = 45) -> [ProbePoint] {
        guard let minX = map.map(\.x).min(), let maxX = map.map(\.x).max(), let minZ = map.map(\.z).min(), let maxZ = map.map(\.z).max() else { return [] }
        guard maxX - minX > singleExtent || maxZ - minZ > singleExtent else { return [ProbePoint((minX + maxX) / 2, 0, (minZ + maxZ) / 2)] }
        var keys = Set<[Int]>()
        for p in map { keys.insert([Int(((p.x - minX) / step).rounded()), Int(((p.z - minZ) / step).rounded())]) }
        return keys.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) }.map { ProbePoint(minX + Double($0[0]) * step, 0, minZ + Double($0[1]) * step) }
    }
}

// MARK: - Navigation refresh

/// Fit of nearby map points to the live depth under the current and the candidate alignment,
/// counted only on points comparable under both (so moving bad points out of view cannot "improve" it).
public struct LiDARAgreementPair: Codable, Equatable {
    public var common: Int
    public var comparable_before: Int, comparable_after: Int
    public var aligned_before: Int, aligned_after: Int
    public var before: Double? { common > 0 ? Double(aligned_before) / Double(common) : nil }
    public var after: Double? { common > 0 ? Double(aligned_after) / Double(common) : nil }
    public init(common: Int, comparableBefore: Int, comparableAfter: Int, alignedBefore: Int, alignedAfter: Int) {
        self.common = common; comparable_before = comparableBefore; comparable_after = comparableAfter; aligned_before = alignedBefore; aligned_after = alignedAfter
    }
}
/// keep: the pose stands. micro: apply silently (smoothed, undoable). large: ask or apply per the
/// person's setting. lost: the result is not usable but the route ahead is blocked — prompt only,
/// keep the current route. ignore: log only.
public struct LiDARRefreshDecision: Codable, Equatable {
    public var action: String
    public var reason: String
    public var correction_m: Double?, correction_deg: Double?
    public var aligned_before: Double?, aligned_after: Double?
    public var common_points: Int?
    public var blocked: Bool
}
public enum LiDARRefreshPolicy {
    public static let keepDistance = 0.10, keepAngle = 1.0, microDistance = 0.5, microAngle = 3.0, microBudget = 1.5
    public static let minGain = 0.05, minCommon = 50, minEvidenceRatio = 0.8
    static let ambiguity: Set<String> = ["multiple_modes", "opposite_yaw_mode", "same_yaw_rival", "along_axis_spread", "multiple_windows", "multiple_plate_windows", "windows_incomplete", "plate_windows_incomplete"]
    /// `microSoFar`: metres already applied by silent micro-adjustments since the last full confirmation.
    public static func decide(_ result: LiDARLocalizationResult, current: [[Double]], camera: ProbePoint, compass: LiDARMagnetic.Check?,
                              agreement: LiDARAgreementPair?, blocked: Bool, microSoFar: Double = 0) -> LiDARRefreshDecision {
        func out(_ a: String, _ r: String, _ d: Double? = nil, _ y: Double? = nil) -> LiDARRefreshDecision {
            LiDARRefreshDecision(action: a, reason: r, correction_m: d, correction_deg: y, aligned_before: agreement?.before, aligned_after: agreement?.after,
                                 common_points: agreement?.common, blocked: blocked)
        }
        let codes = Set(result.decision_reasons ?? [])
        guard result.status == "candidate_requires_review", result.search_complete == true, codes.isDisjoint(with: ambiguity),
              let best = result.candidates.first, best.quality_gate else { return out(blocked ? "lost" : "ignore", "not_unique_or_incomplete") }
        if compass?.status == "conflict" { return out(blocked ? "lost" : "ignore", "compass_conflict") }
        let a = CampusMapGeometry.point([camera.x, camera.y, camera.z], through: current), b = CampusMapGeometry.point([camera.x, camera.y, camera.z], through: best.transform_query_to_map)
        let d = hypot(a[0] - b[0], a[2] - b[2])
        let yaw = abs(LiDARMagnetic.wrap((atan2(best.transform_query_to_map[0][2], best.transform_query_to_map[0][0]) - atan2(current[0][2], current[0][0])) * 180 / .pi))
        if d < keepDistance && yaw < keepAngle { return out("keep", "current_confirmed", d, yaw) }
        // Evidence: enough common points, the comparable set not shrinking, and the fit not worse.
        var better = false, notWorse = false
        if let g = agreement, g.common >= minCommon, Double(g.comparable_after) >= minEvidenceRatio * Double(g.comparable_before),
           let before = g.before, let after = g.after {
            better = after >= before + minGain; notWorse = after >= before
        }
        if d <= microDistance && yaw <= microAngle && microSoFar + d <= microBudget {
            return better ? out("micro", "better_agreement", d, yaw) : out("ignore", "no_better_agreement", d, yaw)
        }
        guard notWorse || blocked else { return out("ignore", "no_better_agreement", d, yaw) }
        return out("large", blocked ? "route_blocked" : "better_or_equal_agreement", d, yaw)
    }
}
