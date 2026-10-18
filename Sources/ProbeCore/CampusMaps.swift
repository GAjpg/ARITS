import Foundation

/// A stable subenvironment identity, independent of its replaceable native file snapshot.
public struct CampusMapCandidate: Codable, Equatable {
    public var id = UUID().uuidString
    public var region_id: String
    public var name: String
    public var saved_utc: String
    public var lighting: CampusLighting
    public var verified = false
    public var protected = true
    public var enabled = true
    public var source_map_id: String?
    /// nil uses the legacy maps/<id> layout. A replacement publishes a new file ID atomically.
    public var file_id: String?
    public var fileID: String { file_id ?? id }
    public var world_map_sha256: String?
    public var map_to_region: [[Double]]
    public var node_coverage: [String:Int]
    /// Routing-node hints for choosing a map, not a crop of the native ARWorldMap.
    /// nil preserves legacy coverage ranking; [] explicitly assigns no priority nodes.
    public var preferred_node_ids: [String]?
    public var suggested_node_ids: [String]?
    public init(regionID:String, name:String, date:String, lighting:CampusLighting = .other,
                transform:[[Double]] = CampusMapGeometry.identity, coverage:[String:Int] = [:]) {
        region_id = regionID;self.name = name;saved_utc = date;self.lighting = lighting
        map_to_region = transform;node_coverage = coverage
    }
    public func validate(regionIDs:Set<String>) throws {
        guard UUID(uuidString:id) != nil,regionIDs.contains(region_id),!name.isEmpty,name.count <= 120,
              ISO8601DateFormatter().date(from:saved_utc) != nil,RigidMatrix.valid(map_to_region),
              source_map_id == nil || UUID(uuidString:source_map_id!) != nil,
              file_id == nil || UUID(uuidString:file_id!) != nil,
              world_map_sha256 == nil || (world_map_sha256!.count == 64 && world_map_sha256!.allSatisfy({ "0123456789abcdef".contains($0) })),
              node_coverage.count <= 3000,node_coverage.allSatisfy({ UUID(uuidString:$0.key) != nil && $0.value >= 0 }) else { throw CampusError.corrupt }
        for ids in [preferred_node_ids,suggested_node_ids].compactMap({ $0 }) {
            guard ids.count <= 3000,Set(ids).count == ids.count,ids.allSatisfy({ UUID(uuidString:$0) != nil }) else { throw CampusError.corrupt }
        }
    }
}

/// The restored source is separate from the save target. A successful first save fixes the
/// target for the rest of this capture screen; failed saves never advance it.
public struct CampusCaptureSaveTarget {
    public private(set) var replacementID:String?
    public init(replacing id:String? = nil) { replacementID = id }
    public var createsSubenvironment:Bool { replacementID == nil }
    public mutating func didSave(_ id:String) { replacementID = id }
}

public enum CampusMapGeometry {
    public static let identity:[[Double]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    public static func multiply(_ a:[[Double]],_ b:[[Double]]) -> [[Double]] {
        (0..<4).map { r in (0..<4).map { c in (0..<4).reduce(0.0) { $0+a[r][$1]*b[$1][c] } } }
    }
    public static func inverse(_ m:[[Double]]) -> [[Double]] {
        var result = identity
        for r in 0..<3 {
            for c in 0..<3 { result[r][c] = m[c][r] }
            result[r][3] = -(0..<3).reduce(0.0) { $0+m[$1][r]*m[$1][3] }
        };return result
    }
    public static func point(_ p:[Double],through m:[[Double]]) -> [Double] {
        (0..<3).map { r in m[r][3]+(0..<3).reduce(0.0) { $0+m[r][$1]*p[$1] } }
    }
    public struct Fit { public let transform:[[Double]],maximumError:Double,sharedNodes:Int }
    /// Gravity supplies vertical orientation and AR supplies metric scale. Two separated shared
    /// positions determine yaw and translation; a third position checks their consistency.
    public static func fit(source:[CampusBinding],target:[CampusBinding],minimumBaseline:Double = 1.5,maximumError:Double = 0.4) throws -> Fit {
        let lookup = Dictionary(uniqueKeysWithValues:target.map { ($0.node_id,$0.position) })
        let pairs = source.compactMap { b in lookup[b.node_id].map { (b.position,$0) } }
        guard pairs.count >= 2 else { throw CampusError.invalid("需要至少两个共同节点来连接坐标，建议相距 2 米以上。") }
        let spread = pairs.flatMap { a in pairs.map { b in hypot(a.0[0]-b.0[0],a.0[2]-b.0[2]) } }.max() ?? 0
        guard spread >= minimumBaseline else { throw CampusError.invalid("共同节点距离过近，无法可靠连接方向；请绑定更远的节点。") }
        let n = Double(pairs.count)
        let a = (0..<3).map { i in pairs.reduce(0.0) { $0+$1.0[i] }/n }
        let b = (0..<3).map { i in pairs.reduce(0.0) { $0+$1.1[i] }/n }
        var cosine = 0.0,sine = 0.0
        for (p,q) in pairs {
            let x = p[0]-a[0],z = p[2]-a[2],u = q[0]-b[0],v = q[2]-b[2]
            cosine += x*u+z*v;sine += x*v-z*u
        }
        guard hypot(cosine,sine) > 1e-8 else { throw CampusError.invalid("共同节点不能确定方向。") }
        let yaw = atan2(sine,cosine),c = cos(yaw),s = sin(yaw)
        let m = [[c,0,-s,b[0]-c*a[0]+s*a[2]],[0,1,0,b[1]-a[1]],[s,0,c,b[2]-s*a[0]-c*a[2]],[0,0,0,1]]
        let residual = pairs.map { p,q in Swift.zip(point(p,through:m),q).reduce(0.0) { $0+pow($1.0-$1.1,2) }.squareRoot() }.max() ?? .infinity
        guard residual <= maximumError else { throw CampusError.invalid(String(format:"共同节点对齐误差 %.2f 米，超过 %.2f 米；请核对是否标在同一位置。",residual,maximumError)) }
        return Fit(transform:m,maximumError:residual,sharedNodes:pairs.count)
    }
    /// Compose same-floor connections into the active map's coordinate frame. Unlinked regions
    /// are deliberately omitted and require a new localization session at their boundary.
    public static func connectedTransforms(graph:CampusGraph,activeRegionID:String) -> [String:[[Double]]] {
        guard let active = graph.region(activeRegionID) else { return [:] }
        var result = [activeRegionID:identity],queue = [activeRegionID]
        let regions = graph.regions.filter { $0.floor_id == active.floor_id && $0.map_saved }
        while !queue.isEmpty {
            let known = queue.removeFirst(),target = graph.bindings.filter { $0.region_id == known }
            for r in regions where result[r.id] == nil {
                guard let fit = try? fit(source:graph.bindings.filter { $0.region_id == r.id },target:target) else { continue }
                result[r.id] = multiply(result[known]!,fit.transform);queue.append(r.id)
            }
        };return result
    }
    public static func navigationGraph(_ graph:CampusGraph,transforms:[String:[[Double]]]) -> CampusGraph {
        var copy = graph
        for i in copy.bindings.indices {
            if let t = transforms[copy.bindings[i].region_id] { copy.bindings[i].anchor_to_map = multiply(t,copy.bindings[i].anchor_to_map) }
        };return copy
    }
    public static func locate(graph:CampusGraph,transforms:[String:[[Double]]],point:[Double],previousEdgeID:String? = nil,allowedRanges:[String:[ClosedRange<Double>]]? = nil) throws -> CampusLocatedPosition {
        let mapped = navigationGraph(graph,transforms:transforms)
        let positions = transforms.keys.sorted().compactMap { rid in try? CampusPositionLocator.locate(graph:mapped,regionID:rid,point:point,previousEdgeID:previousEdgeID,maxDistance:nil,allowedRanges:allowedRanges) }
        guard let closest = positions.min(by: { ($0.distance_m-($0.position.edge_id == previousEdgeID ? 0.2 : 0)) < ($1.distance_m-($1.position.edge_id == previousEdgeID ? 0.2 : 0)) }) else { throw CampusError.noRoute }
        return closest
    }
}

extension CampusGraph {
    public func mapCandidate(_ id:String?) -> CampusMapCandidate? { map_candidates.first { $0.id == id } }
    public func rankedMaps(regionID:String,nearNodeID:String? = nil,preferredLighting:CampusLighting? = nil) -> [CampusMapCandidate] {
        let defaultID = region(regionID)?.default_map_id
        func locality(_ map:CampusMapCandidate) -> Int {
            guard let nearNodeID else { return 0 }
            return map.preferred_node_ids.map { $0.contains(nearNodeID) ? 2 : 0 } ?? ((map.node_coverage[nearNodeID] ?? 0) >= 30 ? 1 : 0)
        }
        func lightRank(_ map:CampusMapCandidate) -> Int {
            guard let preferredLighting,preferredLighting != .other else { return 0 }
            return map.lighting == preferredLighting ? 2 : map.lighting == .other ? 1 : 0
        }
        return map_candidates.filter { $0.region_id == regionID && $0.enabled }.sorted { a,b in
            let ap = locality(a),bp = locality(b)
            // Never prefer an unrelated location merely because its lighting matches.
            if ap != bp { return ap > bp }
            let al = lightRank(a),bl = lightRank(b)
            if al != bl { return al > bl }
            if ap == 2 {
                if a.verified != b.verified { return a.verified }
                if a.saved_utc != b.saved_utc { return a.saved_utc > b.saved_utc }
            }
            if (a.id == defaultID) != (b.id == defaultID) { return a.id == defaultID }
            if a.verified != b.verified { return a.verified }
            return a.saved_utc == b.saved_utc ? a.id < b.id : a.saved_utc > b.saved_utc
        }
    }
}

/// Records only post-alignment observations in a region's reference coordinates.
/// It suggests where this scan took place; it does not certify relocalization quality.
public struct CampusSupplementCoverage {
    public private(set) var observations:[String:Int] = [:]
    public init() {}
    public mutating func observe(bindings:[CampusBinding],position:[Double],radius:Double = 5) {
        guard position.count == 3,position.allSatisfy(\.isFinite),radius.isFinite,radius > 0 else { return }
        for b in bindings {
            let p = b.position
            if hypot(p[0]-position[0],p[2]-position[2]) <= radius,abs(p[1]-position[1]) <= 3 {
                observations[b.node_id,default:0] += 1
            }
        }
    }
    public func suggestedNodeIDs(minimumObservations:Int = 4) -> [String] {
        observations.filter { $0.value >= max(1,minimumObservations) }.map(\.key).sorted()
    }
}
