import Foundation

// A diagnostic view of ARKit's coarse point cloud, never a localization model.
public struct CampusFeaturePointCloud: Codable, Equatable {
    public enum Source:String,Codable { case savedMap = "saved_world_map",sessionPreview = "unsaved_session_snapshot",candidateOverlay = "candidate_overlay" }
    public static let maximumPoints = 50_000
    public var schema_version = 1
    public var coordinate_system = "region_world_m_y_up"
    public var region_id:String
    public var captured_utc:String
    public var source:Source
    public var world_map_sha256:String?
    public var source_point_count:Int
    public var points:[ProbePoint]

    public init(regionID:String,date:String,source:Source,mapHash:String?,points:[ProbePoint]) {
        region_id = regionID;captured_utc = date;self.source = source;world_map_sha256 = mapHash
        source_point_count = points.count
        if points.count > Self.maximumPoints {
            self.points = (0..<Self.maximumPoints).map { points[$0*(points.count-1)/(Self.maximumPoints-1)] }
        } else { self.points = points }
    }
    public func validate(regionID:String,mapHash:String? = nil) throws {
        guard schema_version == 1,coordinate_system == "region_world_m_y_up",region_id == regionID,
              UUID(uuidString:region_id) != nil,ISO8601DateFormatter().date(from:captured_utc) != nil,
              source_point_count >= points.count,source_point_count <= 10_000_000,points.count <= Self.maximumPoints,
              points.allSatisfy({ $0.array.allSatisfy { $0.isFinite && abs($0) <= 10_000 } }) else { throw CampusError.corrupt }
        if source == .savedMap {
            guard let hash = world_map_sha256,hash.count == 64,hash.allSatisfy({"0123456789abcdef".contains($0)}),
                  mapHash == nil || mapHash == hash else { throw CampusError.corrupt }
        } else if world_map_sha256 != nil { throw CampusError.corrupt }
    }
    public struct Cell:Equatable {
        public let x:Int,z:Int,count:Int
    }
    private struct Key:Hashable { let x:Int,z:Int }
    // Each cell projects every height into a one-meter square on the X/Z plane.
    public func density(cellSize:Double = 1) -> [Cell] {
        guard cellSize.isFinite,cellSize >= 0.1 else { return [] }
        var counts:[Key:Int] = [:]
        for p in points where p.x.isFinite && p.z.isFinite && abs(p.x) <= 10_000 && abs(p.z) <= 10_000 {
            counts[Key(x:Int(floor(p.x/cellSize)),z:Int(floor(p.z/cellSize))),default:0] += 1
        }
        return counts.map { Cell(x:$0.key.x,z:$0.key.z,count:$0.value) }.sorted { $0.z == $1.z ? $0.x < $1.x : $0.z < $1.z }
    }
    public func count(x:Double,z:Double,cellSize:Double = 1) -> Int {
        guard x.isFinite,z.isFinite,cellSize.isFinite,cellSize >= 0.1,abs(x) <= 10_000,abs(z) <= 10_000 else { return 0 }
        let cx = floor(x/cellSize),cz = floor(z/cellSize)
        return points.filter { floor($0.x/cellSize) == cx && floor($0.z/cellSize) == cz }.count
    }
}

/// Clouds must already be transformed into the same regional reference frame.
public struct CampusFeatureLayer {
    public let id:String,name:String,cloud:CampusFeaturePointCloud
    public init(id:String,name:String,cloud:CampusFeaturePointCloud) { self.id = id;self.name = name;self.cloud = cloud }
}

public enum CampusFeatureDistribution {
    public static func transformed(_ cloud:CampusFeaturePointCloud,by matrix:[[Double]]) -> CampusFeaturePointCloud {
        var copy = cloud
        copy.points = cloud.points.map { p in let v = CampusMapGeometry.point(p.array,through:matrix);return ProbePoint(v[0],v[1],v[2]) }
        return copy
    }
    /// Give every visible map a share of the display budget so hiding a map never
    /// accidentally removes all points from another. Native files remain untouched.
    public static func sampledLayers(_ layers:[CampusFeatureLayer],budget:Int = CampusFeaturePointCloud.maximumPoints) -> [CampusFeatureLayer] {
        guard !layers.isEmpty,budget > 0 else { return [] }
        let total = layers.reduce(0) { $0+$1.cloud.points.count }
        guard total > budget else { return layers }
        let active = layers.filter { !$0.cloud.points.isEmpty },share = budget/max(1,active.count)
        return active.enumerated().compactMap { index,layer in
            var cloud = layer.cloud
            let count = min(cloud.points.count,share+(index < budget%active.count ? 1 : 0))
            guard count > 0 else { return nil }
            cloud.points = (0..<count).map { cloud.points[$0*(cloud.points.count-1)/max(1,count-1)] }
            return CampusFeatureLayer(id:layer.id,name:layer.name,cloud:cloud)
        }
    }
    public static func combined(_ layers:[CampusFeatureLayer]) -> CampusFeaturePointCloud? {
        guard let first = layers.first, layers.allSatisfy({ $0.cloud.region_id == first.cloud.region_id }) else { return nil }
        let displayed = sampledLayers(layers)
        var cloud = CampusFeaturePointCloud(regionID:first.cloud.region_id,date:layers.map { $0.cloud.captured_utc }.max() ?? first.cloud.captured_utc,source:.candidateOverlay,mapHash:nil,points:displayed.flatMap { $0.cloud.points })
        cloud.source_point_count = layers.reduce(0) { $0+$1.cloud.source_point_count }
        return cloud
    }
}
