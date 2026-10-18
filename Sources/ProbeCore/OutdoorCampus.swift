import Foundation
import CryptoKit

/// WGS-84 degrees. Campus arrays are [latitude, longitude]; public DTOs use named keys.
public struct OutdoorCoordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    public var isValid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude) <= 90 && abs(longitude) <= 180 }
}

public struct OutdoorLocalFrame: Sendable {
    public let origin: OutdoorCoordinate
    private let metresLatitude: Double, metresLongitude: Double
    public init(origin: OutdoorCoordinate) {
        self.origin = origin
        let p = origin.latitude * .pi / 180
        metresLatitude = 111132.92 - 559.82 * cos(2*p) + 1.175 * cos(4*p)
        metresLongitude = 111412.84 * cos(p) - 93.5 * cos(3*p)
    }
    /// East/north metres (AR uses x=east, z=-north).
    public func local(_ p: OutdoorCoordinate) -> (east: Double, north: Double) {
        ((p.longitude-origin.longitude)*metresLongitude, (p.latitude-origin.latitude)*metresLatitude)
    }
    public func coordinate(east: Double, north: Double) -> OutdoorCoordinate {
        .init(latitude: origin.latitude + north/metresLatitude, longitude: origin.longitude + east/metresLongitude)
    }
    public func distance(_ a: OutdoorCoordinate, _ b: OutdoorCoordinate) -> Double {
        let x = local(a), y = local(b); return hypot(y.east-x.east, y.north-x.north)
    }
    public func bearing(_ a: OutdoorCoordinate, _ b: OutdoorCoordinate) -> Double {
        let x = local(a), y = local(b)
        return (atan2(y.east-x.east, y.north-x.north)*180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }
    public func project(_ p: OutdoorCoordinate, from a: OutdoorCoordinate, to b: OutdoorCoordinate) -> (point: OutdoorCoordinate, fraction: Double, distanceM: Double) {
        let q = local(p), u = local(a), v = local(b), dx = v.east-u.east, dy = v.north-u.north
        let l2 = dx*dx+dy*dy
        let t = l2 > 1e-12 ? max(0,min(1,((q.east-u.east)*dx+(q.north-u.north)*dy)/l2)) : 0
        let e = u.east+t*dx, n = u.north+t*dy
        return (coordinate(east:e,north:n), t, hypot(q.east-e,q.north-n))
    }
}

private struct OutdoorArrayCoordinate: Decodable {
    let value: OutdoorCoordinate
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let lat = try c.decode(Double.self), lon = try c.decode(Double.self)
        guard c.isAtEnd else { throw OutdoorCampusError.invalid("地理点必须包含纬度、经度两个数") }
        value = .init(latitude:lat,longitude:lon)
    }
}

public enum OutdoorCampusError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public struct OutdoorEntrance: Decodable, Equatable, Sendable {
    public let coordinate: OutdoorCoordinate
    /// Dataset-local index; never a persistent physical entrance ID. -1 means a coordinate-only binding.
    public let nodeIndex: Int
    /// Stable id from campus-bindings, when supplied by the coordinator. Never a graph array index.
    public let bindingID: String?
    /// Human-verified walking access: physical door first, graph access point last.
    public let accessPath: [OutdoorCoordinate]?
    public let distanceM: Double
    public let source: String
    private enum CodingKeys: String, CodingKey { case pos, node, dist, source;case bindingID = "binding_id";case accessPath = "access_path" }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        coordinate = try c.decode(OutdoorArrayCoordinate.self,forKey:.pos).value
        nodeIndex = try c.decode(Int.self,forKey:.node)
        bindingID = try c.decodeIfPresent(String.self,forKey:.bindingID)
        if let arrays = try? c.decode([OutdoorArrayCoordinate].self,forKey:.accessPath) { accessPath = arrays.map(\.value) }
        else { accessPath = try c.decodeIfPresent([OutdoorCoordinate].self,forKey:.accessPath) }
        distanceM = try c.decodeIfPresent(Double.self,forKey:.dist) ?? 0
        source = try c.decodeIfPresent(String.self,forKey:.source) ?? "unknown"
    }
    public init(coordinate: OutdoorCoordinate, nodeIndex: Int, distanceM: Double = 0, source: String = "verified_binding", bindingID: String? = nil, accessPath: [OutdoorCoordinate]? = nil) {
        self.coordinate = coordinate; self.nodeIndex = nodeIndex; self.bindingID = bindingID; self.accessPath = accessPath; self.distanceM = distanceM; self.source = source
    }
}

public struct OutdoorBuilding: Decodable, Sendable {
    public let id: String
    public let name: String
    public let shortName: String
    /// Label priority from 1 to 5 (highest); legacy maps leave this unspecified.
    public let rank: Int?
    /// Complete disjoint/overlapping components after editing; ring remains the primary footprint.
    public let parts: [[OutdoorCoordinate]]?
    public var footprints: [[OutdoorCoordinate]] { parts ?? [ring] }
    public let kind: String?
    /// OSM storey count, not a verified enumeration of floor identifiers.
    public let levels: Int?
    public let ring: [OutdoorCoordinate]
    public let centroid: OutdoorCoordinate
    public let entrances: [OutdoorEntrance]
    public let inCampus: Bool
    public let walkThrough: Bool
    public var label: String { shortName.isEmpty ? name : shortName }
    /// What cards, search and destinations show: the full name; the short name only labels the map.
    public var fullName: String { name.isEmpty ? shortName : name }
    private enum CodingKeys: String, CodingKey { case osm, name, short, rank, parts, kind, levels, ring, centroid, doors, campus, walkThrough, door, doorNode, doorDist }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(String.self,forKey:.osm)
        name = try c.decodeIfPresent(String.self,forKey:.name) ?? ""
        shortName = try c.decodeIfPresent(String.self,forKey:.short) ?? ""
        rank = try c.decodeIfPresent(Int.self,forKey:.rank)
        parts = try c.decodeIfPresent([[OutdoorArrayCoordinate]].self,forKey:.parts)?.map { $0.map(\.value) }
        kind = try c.decodeIfPresent(String.self,forKey:.kind)
        if let i = try? c.decode(Int.self,forKey:.levels) { levels = i > 0 ? i : nil }
        else if let s = try? c.decode(String.self,forKey:.levels), let i = Int(s) { levels = i > 0 ? i : nil }
        else { levels = nil }
        ring = try c.decode([OutdoorArrayCoordinate].self,forKey:.ring).map(\.value)
        centroid = try c.decode(OutdoorArrayCoordinate.self,forKey:.centroid).value
        inCampus = try c.decodeIfPresent(Bool.self,forKey:.campus) ?? true
        walkThrough = try c.decodeIfPresent(Bool.self,forKey:.walkThrough) ?? false
        let doors = try c.decodeIfPresent([OutdoorEntrance].self,forKey:.doors) ?? []
        if doors.isEmpty, let p = try c.decodeIfPresent(OutdoorArrayCoordinate.self,forKey:.door), let n = try c.decodeIfPresent(Int.self,forKey:.doorNode) {
            entrances = [.init(coordinate:p.value,nodeIndex:n,distanceM:try c.decodeIfPresent(Double.self,forKey:.doorDist) ?? 0,source:"legacy")]
        } else { entrances = doors }
    }
}

public struct OutdoorArea: Decodable, Sendable {
    public let id: String, kind: String, name: String
    public let ring: [OutdoorCoordinate]
    private enum CodingKeys: String, CodingKey { case osm, kind, name, ring }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decode(String.self,forKey:.osm); kind = try c.decode(String.self,forKey:.kind)
        name = try c.decodeIfPresent(String.self,forKey:.name) ?? ""
        ring = try c.decode([OutdoorArrayCoordinate].self,forKey:.ring).map(\.value)
    }
}
public struct OutdoorRoad: Decodable, Sendable {
    public let kind: String, name: String
    public let points: [OutdoorCoordinate]
    private enum CodingKeys: String, CodingKey { case k, n, p }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        kind = try c.decode(String.self,forKey:.k); name = try c.decodeIfPresent(String.self,forKey:.n) ?? ""
        points = try c.decode([OutdoorArrayCoordinate].self,forKey:.p).map(\.value)
    }
}
public struct OutdoorGraphEdge: Decodable, Sendable {
    public let from: Int, to: Int
    public let distanceM: Double, factor: Double
    public let kind: String, name: String
    public var cost: Double { distanceM * factor }
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        from = try c.decode(Int.self); to = try c.decode(Int.self)
        distanceM = try c.decode(Double.self); factor = try c.decode(Double.self)
        kind = try c.decode(String.self); name = try c.decodeIfPresent(String.self) ?? ""
        guard c.isAtEnd else { throw OutdoorCampusError.invalid("路网边格式无效") }
    }
}
public struct OutdoorGraph: Decodable, Sendable {
    public let nodes: [OutdoorCoordinate]
    public let edges: [OutdoorGraphEdge]
    private enum CodingKeys: String, CodingKey { case nodes, edges }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        nodes = try c.decode([OutdoorArrayCoordinate].self,forKey:.nodes).map(\.value)
        edges = try c.decode([OutdoorGraphEdge].self,forKey:.edges)
    }
}
public struct OutdoorCampus: Decodable, Sendable {
    public let version: Int
    public let name: String, source: String
    public let origin: OutdoorCoordinate
    public let campusRing: [OutdoorCoordinate]
    public let buildings: [OutdoorBuilding]
    public let areas: [OutdoorArea]
    public let roads: [OutdoorRoad]
    public let graph: OutdoorGraph
    public var frame: OutdoorLocalFrame { .init(origin:origin) }
    private enum CodingKeys: String, CodingKey { case v, meta, campusRing, buildings, areas, roads, graph }
    private struct Meta: Decodable { let name: String; let source: String; let origin: OutdoorArrayCoordinate }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self), m = try c.decode(Meta.self,forKey:.meta)
        version = try c.decode(Int.self,forKey:.v); name = m.name; source = m.source; origin = m.origin.value
        campusRing = try c.decode([OutdoorArrayCoordinate].self,forKey:.campusRing).map(\.value)
        buildings = try c.decode([OutdoorBuilding].self,forKey:.buildings)
        areas = try c.decodeIfPresent([OutdoorArea].self,forKey:.areas) ?? []
        roads = try c.decodeIfPresent([OutdoorRoad].self,forKey:.roads) ?? []
        graph = try c.decode(OutdoorGraph.self,forKey:.graph)
        try validate()
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32*1024*1024 else { throw OutdoorCampusError.invalid("校园数据超过32MB") }
        return try JSONDecoder().decode(Self.self,from:data)
    }
    public func building(id: String) -> OutdoorBuilding? { buildings.first { $0.id == id } }
    public func validate() throws {
        guard version > 0, origin.isValid, abs(origin.latitude) < 85,
              !graph.nodes.isEmpty, graph.nodes.count <= 200_000, graph.edges.count <= 500_000,
              graph.nodes.allSatisfy(\.isValid), campusRing.count >= 3, campusRing.allSatisfy(\.isValid),
              Set(buildings.map(\.id)).count == buildings.count else { throw OutdoorCampusError.invalid("校园坐标或索引无效") }
        for e in graph.edges {
            guard graph.nodes.indices.contains(e.from), graph.nodes.indices.contains(e.to),
                  e.from != e.to, e.distanceM.isFinite, e.distanceM > 0, e.factor.isFinite, e.factor >= 1, e.cost.isFinite else {
                throw OutdoorCampusError.invalid("校园路网边无效")
            }
            // The heuristic must remain admissible even for malformed supplied edge lengths.
        }
        for b in buildings {
            guard !b.id.isEmpty, b.centroid.isValid, b.ring.count >= 3, b.ring.allSatisfy(\.isValid),
                  b.rank.map({ (1...5).contains($0) }) ?? true,
                  b.parts.map({ !$0.isEmpty && $0.count <= 64 && $0.first == b.ring && $0.allSatisfy { $0.count >= 3 && $0.count <= 2000 && $0.allSatisfy(\.isValid) } }) ?? true,
                  b.entrances.allSatisfy({ graph.nodes.indices.contains($0.nodeIndex) && $0.coordinate.isValid && $0.distanceM.isFinite && $0.distanceM >= 0 }) else {
                throw OutdoorCampusError.invalid("建筑或门口索引无效：\(b.id)")
            }
        }
        guard roads.allSatisfy({ $0.points.allSatisfy(\.isValid) }), areas.allSatisfy({ $0.ring.allSatisfy(\.isValid) }) else {
            throw OutdoorCampusError.invalid("底图坐标无效")
        }
    }
}

/// Whole-file replacement, not a DTO re-encode: unknown fields (gates/POIs/OSM metadata) survive.
/// Immutable snapshots are written before an atomic publication. A crash cannot remove the last version.
public struct OutdoorCampusStorage {
    public struct Selection {
        public let data:Data,campus:OutdoorCampus,isCustom:Bool,warning:String?
    }
    public let directory:URL
    public var currentURL:URL { directory.appendingPathComponent("campus.json") }
    public init(directory:URL) { self.directory = directory }
    public static func packagedData(in bundle:Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource:"campus",withExtension:"json",subdirectory:"Outdoor") ?? bundle.url(forResource:"campus",withExtension:"json") else { return nil }
        return try? Data(contentsOf:url)
    }
    public func current(bundled:Data?) throws -> Selection {
        var warning:String?
        if FileManager.default.fileExists(atPath:currentURL.path) {
            do { let d = try read(currentURL);return Selection(data:d,campus:try OutdoorCampus.decode(d),isCustom:true,warning:nil) }
            catch { warning = "自定义校园地图无法读取，已回到内置版本："+error.localizedDescription }
        }
        guard let bundled else { throw OutdoorCampusError.invalid(warning ?? "没有可用的校园地图") }
        return Selection(data:bundled,campus:try OutdoorCampus.decode(bundled),isCustom:false,warning:warning)
    }
    /// Import adds connectivity and polygon checks without changing legacy decode/routing behavior.
    @discardableResult public static func validateImport(_ data:Data) throws -> OutdoorCampus {
        let campus = try OutdoorCampus.decode(data),n = campus.graph.nodes.count
        guard campus.buildings.count <= 20_000 else { throw OutdoorCampusError.invalid("楼栋数量超过上限") }
        var adjacent = [[Int]](repeating:[],count:n)
        for e in campus.graph.edges { adjacent[e.from].append(e.to);adjacent[e.to].append(e.from) }
        var seen = Set([0]),queue = [0],i = 0
        while i < queue.count { let u = queue[i];i += 1;for v in adjacent[u] where seen.insert(v).inserted { queue.append(v) } }
        guard seen.count == n else { throw OutdoorCampusError.invalid("步行路网未连通（\(n-seen.count) 个节点不在主连通区域），请在工作台补齐连接后再导入。") }
        var count = 0
        for b in campus.buildings { for footprint in b.footprints {
            var p = footprint.map { campus.frame.local($0) }
            if p.count > 1,abs(p[0].east-p.last!.east)+abs(p[0].north-p.last!.north) < 1e-7 { p.removeLast() }
            count += p.count
            guard p.count >= 3,p.count <= 2000,count <= 100_000 else { throw OutdoorCampusError.invalid("楼栋「\(b.label)」轮廓点数无效或过多") }
            let area = abs(p.indices.reduce(0.0) { $0+p[$1].east*p[($1+1)%p.count].north-p[($1+1)%p.count].east*p[$1].north })/2
            guard area > 0.01 else { throw OutdoorCampusError.invalid("楼栋「\(b.label)」轮廓没有有效面积") }
            func cross(_ a:(east:Double,north:Double),_ b:(east:Double,north:Double),_ c:(east:Double,north:Double)) -> Double { (b.east-a.east)*(c.north-a.north)-(b.north-a.north)*(c.east-a.east) }
            for a in p.indices { for b in (a+1)..<p.count where b != a+1 && !(a == 0 && b == p.count-1) {
                let u = p[a],v = p[(a+1)%p.count],x = p[b],y = p[(b+1)%p.count]
                if cross(u,v,x)*cross(u,v,y) < -1e-10 && cross(x,y,u)*cross(x,y,v) < -1e-10 { throw OutdoorCampusError.invalid("楼栋轮廓有自交，请在工作台修正") }
            } }
        } }
        return campus
    }
    public func install(_ data:Data,bundled:Data?) throws {
        _ = try Self.validateImport(data)
        let old = try current(bundled:bundled)
        try snapshot(old.data)
        try data.write(to:currentURL,options:.atomic)
        prune()
    }
    public func previous() -> Data? {
        let hash = (try? read(currentURL)).map(Self.hash)
        for url in snapshots() {
            if let data = try? read(url),Self.hash(data) != hash,(try? OutdoorCampus.decode(data)) != nil { return data }
        }
        return nil
    }
    public func restore(bundled:Data?) throws {
        guard let previous = previous() else { throw OutdoorCampusError.invalid("还没有可恢复的上一版") }
        _ = try Self.validateImport(previous)
        let old = try current(bundled:bundled)
        try snapshot(old.data)
        try previous.write(to:currentURL,options:.atomic)
        prune()
    }
    private func read(_ url:URL) throws -> Data {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 32*1024*1024 else { throw OutdoorCampusError.invalid("校园地图超过32MB") }
        return try Data(contentsOf:url)
    }
    private func snapshot(_ data:Data) throws {
        let dir = directory.appendingPathComponent("versions",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let stamp = String(format:"%020.0f",Date().timeIntervalSince1970*1_000_000)
        try data.write(to:dir.appendingPathComponent(stamp+"-"+UUID().uuidString+".json"),options:.atomic)
    }
    private func snapshots() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at:directory.appendingPathComponent("versions"),includingPropertiesForKeys:nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    private func prune() { for old in snapshots().dropFirst(4) { try? FileManager.default.removeItem(at:old) } }
    private static func hash(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}
