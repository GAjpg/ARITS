import Foundation
import CryptoKit

/// Route and geometry are captured in one gravity-aligned ARSession. This file
/// is a sidecar; scan.json and the original raw-depth export stay compatible.
///
/// Schema 1 has untyped nodes and edges without ids. Schema 2 adds node kind, optional
/// capture context and stable edge ids. Both are read; new maps are written as schema 2.
/// Loading never rewrites the file; v1 edge ids are derived deterministically in memory.
public struct LiDARNodeCaptureContext: Codable, Equatable {
    /// ARFrame.timestamp of the frame used to place the node.
    public var timestamp: Double
    public var session_id: String
    public var generation: Int?
    /// Camera pose when the node was placed (row-major, session coordinates).
    public var camera_to_session: [[Double]]
    /// Nearest accepted keyframe and its time offset; nil when none was close enough.
    public var keyframe_index: Int?
    public var keyframe_dt_s: Double?
    public init(timestamp: Double, session_id: String, generation: Int?, camera_to_session: [[Double]],
                keyframe_index: Int? = nil, keyframe_dt_s: Double? = nil) {
        self.timestamp = timestamp; self.session_id = session_id; self.generation = generation
        self.camera_to_session = camera_to_session; self.keyframe_index = keyframe_index; self.keyframe_dt_s = keyframe_dt_s
    }
}

public struct LiDARRouteNode: Codable, Equatable {
    public var id: String
    public var name: String
    public var position: ProbePoint
    /// nil in schema 1; read as waypoint.
    public var kind: CampusNodeKind?
    public var capture: LiDARNodeCaptureContext?
    public init(name: String, position: ProbePoint, id: String = UUID().uuidString,
                kind: CampusNodeKind? = nil, capture: LiDARNodeCaptureContext? = nil) {
        self.id = id; self.name = name; self.position = position; self.kind = kind; self.capture = capture
    }
    public var resolvedKind: CampusNodeKind { kind ?? .waypoint }
}

public struct LiDARRouteEdge: Codable, Equatable {
    public var from: String, to: String
    /// Stable id. nil only in schema-1 files; LiDARNavigationMap fills it on load.
    public var id: String?
    public init(_ from: String, _ to: String, id: String? = nil) { self.from = from; self.to = to; self.id = id }
}

public struct LiDARNavigationMap: Codable {
    public static let currentSchema = 2
    public var schema_version = LiDARNavigationMap.currentSchema
    public var kind = "lidar_navigation_map"
    public var map_id: String, session_id: String, name: String
    public var coordinate_system = "ARKit_Y_up_camera_minus_Z_row_major_meters"
    public var created_utc = ISO8601DateFormatter().string(from: Date())
    public var initial_world_map_used = false
    public var points_file = "geometry.f32"
    public var point_count: Int
    public var voxel_m = 0.10
    public var nodes: [LiDARRouteNode]
    public var edges: [LiDARRouteEdge]
    /// Which nodes are destinations. "rooms_and_named_stairs" (written by LiDARRouteEditor):
    /// room entrances plus named stair nodes. nil in older files: every named node, as before.
    public static let roomsAndNamedStairs = "rooms_and_named_stairs"
    public var destination_policy: String?
    /// "space": routes come from the walkable space (experimental); nodes are semantic points and
    /// edges, if any, are a legacy baseline only. nil: the hand-drawn network is the route.
    public var routing_mode: String?
    public static let spaceRouting = "space"
    public var usesSpaceRouting: Bool { routing_mode == Self.spaceRouting }
    /// Capture sessions that built this map, oldest first. nil in maps saved before supplements.
    public var sources: [LiDARMapSource]?
    /// Route size limits; raised from 200 / 600 for floor-scale maps grown by supplements.
    public static let maxNodes = 2_000, maxEdges = 6_000
    public init(mapID: String, sessionID: String, name: String, pointCount: Int,
                nodes: [LiDARRouteNode], edges: [LiDARRouteEdge]) {
        map_id = mapID; session_id = sessionID; self.name = name
        point_count = pointCount; self.nodes = nodes; self.edges = edges
        assignEdgeIDs()
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema_version = try c.decode(Int.self, forKey: .schema_version)
        kind = try c.decode(String.self, forKey: .kind)
        map_id = try c.decode(String.self, forKey: .map_id); session_id = try c.decode(String.self, forKey: .session_id)
        name = try c.decode(String.self, forKey: .name)
        coordinate_system = try c.decode(String.self, forKey: .coordinate_system)
        created_utc = try c.decode(String.self, forKey: .created_utc)
        initial_world_map_used = try c.decode(Bool.self, forKey: .initial_world_map_used)
        points_file = try c.decode(String.self, forKey: .points_file)
        point_count = try c.decode(Int.self, forKey: .point_count)
        voxel_m = try c.decode(Double.self, forKey: .voxel_m)
        nodes = try c.decode([LiDARRouteNode].self, forKey: .nodes)
        edges = try c.decode([LiDARRouteEdge].self, forKey: .edges)
        destination_policy = try c.decodeIfPresent(String.self, forKey: .destination_policy)
        sources = try c.decodeIfPresent([LiDARMapSource].self, forKey: .sources)
        routing_mode = try c.decodeIfPresent(String.self, forKey: .routing_mode)
        assignEdgeIDs()
    }
    /// Deterministic ids for edges that have none: hash of endpoints plus occurrence count,
    /// so reloading the same v1 file always yields the same ids.
    private mutating func assignEdgeIDs() {
        var seen = [String:Int]()
        for i in edges.indices where edges[i].id == nil {
            let base = "\(edges[i].from)|\(edges[i].to)",n = seen[base,default:0];seen[base] = n+1
            edges[i].id = "e-"+SHA256.hash(data:Data("\(base)|\(n)".utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
        }
    }
    /// Groups of node ids connected by edges.
    public func components() -> [[String]] {
        var adjacency = [String:[String]]()
        for e in edges { adjacency[e.from,default:[]].append(e.to);adjacency[e.to,default:[]].append(e.from) }
        var seen = Set<String>(),groups = [[String]]()
        for n in nodes where !seen.contains(n.id) {
            var stack = [n.id],group = [String]();seen.insert(n.id)
            while let id = stack.popLast() {
                group.append(id)
                for next in adjacency[id] ?? [] where !seen.contains(next) { seen.insert(next);stack.append(next) }
            }
            groups.append(group)
        }
        return groups
    }
    /// requireConnected=false validates a draft that may still contain separate branches.
    public func validate(requireConnected: Bool = true) throws {
        guard [1,2].contains(schema_version), kind == "lidar_navigation_map",
              UUID(uuidString: map_id) != nil, UUID(uuidString: session_id) != nil,
              !initial_world_map_used, coordinate_system == "ARKit_Y_up_camera_minus_Z_row_major_meters",
              points_file == "geometry.f32", (100...LiDARScanLimits.mapVoxelsV3).contains(point_count),
              voxel_m.isFinite, (0.04...0.3).contains(voxel_m), !name.isEmpty, name.count <= 120,
              ((usesSpaceRouting ? 1 : 2)...LiDARNavigationMap.maxNodes).contains(nodes.count), edges.count <= LiDARNavigationMap.maxEdges,
              routing_mode == nil || usesSpaceRouting,
              Set(nodes.map(\.id)).count == nodes.count,
              nodes.allSatisfy({ !$0.id.isEmpty && $0.name.count <= 120 && $0.position.array.allSatisfy { $0.isFinite && abs($0) < 1000 } }),
              schema_version == 2 || nodes.allSatisfy({ $0.kind == nil && $0.capture == nil }),
              destination_policy == nil || destination_policy == Self.roomsAndNamedStairs else {
            throw LiDARScanError.invalid("几何导航地图的格式或路线无效")
        }
        let ids = Set(nodes.map(\.id))
        guard usesSpaceRouting || !edges.isEmpty, edges.allSatisfy({ $0.from != $0.to && ids.contains($0.from) && ids.contains($0.to) }),
              Set(edges.compactMap(\.id)).count == edges.count else {
            throw LiDARScanError.invalid("路线连接无效")
        }
        if requireConnected && !usesSpaceRouting && components().count != 1 { throw LiDARScanError.invalid("存在未连接的节点") }
        if let sources {
            guard sources.count <= 200, Set(sources.map(\.scan_id)).count == sources.count, sources.allSatisfy({ $0.valid }),
                  sources.dropFirst().allSatisfy({ $0.kind == LiDARMapSource.supplement }) else { throw LiDARScanError.invalid("地图来源记录无效") }
        }
    }
    /// Join the closest edge, then use Dijkstra to either end of that edge.
    /// The camera is not snapped to the route; the caller can show the offset.
    public func route(from camera: ProbePoint, to destination: String) throws -> [ProbePoint] {
        try validate()
        guard camera.array.allSatisfy(\.isFinite), nodes.contains(where: { $0.id == destination }) else {
            throw LiDARScanError.invalid("目的地或当前位置无效")
        }
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
        var closest: (LiDARRouteEdge, ProbePoint, Double)?
        for e in edges {
            let a = byID[e.from]!, b = byID[e.to]!
            let dx = b.x-a.x, dz = b.z-a.z, length2 = dx*dx+dz*dz
            guard length2 > 0.01 else { continue }
            let t = min(1, max(0, ((camera.x-a.x)*dx+(camera.z-a.z)*dz)/length2))
            let p = ProbePoint(a.x+t*dx, a.y+t*(b.y-a.y), a.z+t*dz)
            let d = hypot(camera.x-p.x, camera.z-p.z)
            if closest == nil || d < closest!.2 { closest = (e,p,d) }
        }
        guard let (edge,join,_) = closest else { throw LiDARScanError.invalid("没有可通行的连线") }
        var distances = [String:Double](), previous = [String:String]()
        for id in [edge.from,edge.to] { distances[id] = hypot(byID[id]!.x-join.x,byID[id]!.z-join.z) }
        var visited = Set<String>()
        while let next = distances.filter({ !visited.contains($0.key) }).min(by: { $0.value < $1.value }) {
            if next.key == destination { break }
            visited.insert(next.key)
            for e in edges {
                let other: String
                if e.from == next.key { other = e.to } else if e.to == next.key { other = e.from } else { continue }
                let a = byID[next.key]!,b = byID[other]!,cost = next.value+hypot(a.x-b.x,a.z-b.z)
                if cost < (distances[other] ?? .infinity) { distances[other] = cost; previous[other] = next.key }
            }
        }
        guard distances[destination] != nil else { throw LiDARScanError.invalid("目的地不可达") }
        var ids = [destination]
        while let p = previous[ids[0]] { ids.insert(p,at:0) }
        var result = [join]
        for id in ids {
            let p = byID[id]!
            if hypot(p.x-result.last!.x,p.z-result.last!.z) > 0.02 { result.append(p) }
        }
        if result.count == 1 { result.append(result[0]) }
        return result
    }
}

extension LiDARNavigationMap {
    /// Walking length of a route returned by route(from:to:), horizontal.
    public static func length(_ route: [ProbePoint]) -> Double {
        zip(route,route.dropFirst()).reduce(0) { $0+hypot($1.1.x-$1.0.x,$1.1.z-$1.0.z) }
    }
    /// Several entrances can lead to the same room: route to each reachable one and keep the
    /// shortest by walking distance along the network, not by straight-line distance.
    /// Unreachable entrances are skipped; throws only if none is reachable.
    public func route(from camera: ProbePoint, toAnyOf destinations: [String]) throws -> (destination: String, route: [ProbePoint], length_m: Double) {
        var best: (String,[ProbePoint],Double)?
        for id in Set(destinations).sorted() {
            guard let r = try? route(from:camera,to:id) else { continue }
            let l = Self.length(r)
            if best == nil || l < best!.2 { best = (id,r,l) }
        }
        guard let best else { throw LiDARScanError.invalid("这个房间的入口都不可达") }
        return (best.0,best.1,best.2)
    }
    /// Nodes that share a destination name, for showing one list entry per room.
    /// Entities stay separate; this only groups them for display and routing.
    /// Destinations joined to the network, one entry per name. With the editor's policy: room
    /// entrances (from plates or manual rooms) and named stair / elevator nodes, which stay
    /// ordinary route nodes. Older maps without a policy keep every named node.
    /// Pickers: rooms first; "others" are named, connected nodes that are not rooms or waypoints
    /// (junctions, stairs, elevators). Automatic "节点N" names and waypoints are never offered.
    public func namedChoices() -> (rooms: [(name: String, nodeIDs: [String])], others: [(name: String, nodeIDs: [String])]) {
        let connected = Set(edges.flatMap { [$0.from,$0.to] })
        func groups(_ keep: (LiDARRouteNode) -> Bool) -> [(name: String, nodeIDs: [String])] {
            var order = [String](),ids = [String:[String]](),names = [String:String]()
            for n in nodes where (usesSpaceRouting || connected.contains(n.id)) && keep(n) {
                let key = LiDARText.normalize(n.name)
                if ids[key] == nil { order.append(key);names[key] = n.name }
                ids[key,default:[]].append(n.id)
            }
            return order.map { (names[$0]!,ids[$0]!) }
        }
        return (groups { $0.resolvedKind == .room },
                groups { ![.room,.waypoint].contains($0.resolvedKind) && !$0.name.hasPrefix("节点") })
    }
    public func destinationGroups() -> [(name: String, nodeIDs: [String])] {
        var order = [String](),groups = [String:[String]]()
        let connected = Set(edges.flatMap { [$0.from,$0.to] })
        func eligible(_ n: LiDARRouteNode) -> Bool {
            guard usesSpaceRouting || connected.contains(n.id) else { return false }
            guard destination_policy == Self.roomsAndNamedStairs else { return n.resolvedKind == .room || !n.name.hasPrefix("节点") }
            return n.resolvedKind == .room || ([.stair,.elevator,.exit].contains(n.resolvedKind) && !n.name.hasPrefix("节点"))
        }
        for n in nodes where eligible(n) {
            let key = LiDARText.normalize(n.name)
            if groups[key] == nil { order.append(key) }
            groups[key,default:[]].append(n.id)
        }
        return order.map { key in (nodes.first { LiDARText.normalize($0.name) == key }!.name,groups[key]!) }
    }
}

/// One capture session that contributed to a map. The initial session defines map coordinates
/// (identity); a supplement records the manually confirmed alignment of its own session.
public struct LiDARMapSource: Codable, Equatable {
    public static let initial = "initial", supplement = "supplement"
    public var kind: String
    public var scan_id: String, session_id: String
    /// Row-major map_from_session; identity for the initial session.
    public var map_from_session: [[Double]]
    /// "manual": a person confirmed the localization before capture continued.
    public var confirmation: String
    public var added_utc: String
    public var accepted_frames: Int
    /// Which localization the person confirmed (supplements only).
    public var generation: Int?, attempt_id: String?, candidate_index: Int?
    public init(kind: String, scanID: String, sessionID: String, mapFromSession: [[Double]], confirmation: String = "manual", acceptedFrames: Int) {
        self.kind = kind; scan_id = scanID; session_id = sessionID; map_from_session = mapFromSession
        self.confirmation = confirmation; added_utc = ISO8601DateFormatter().string(from: Date()); accepted_frames = acceptedFrames
    }
    var valid: Bool {
        [Self.initial, Self.supplement].contains(kind) && UUID(uuidString: scan_id) != nil && UUID(uuidString: session_id) != nil
            && RigidMatrix.valid(map_from_session) && ["manual", "identity"].contains(confirmation) && accepted_frames >= 0
    }
}

public enum LiDARPointFile {
    public static func encode(_ points: [ProbePoint]) throws -> Data {
        guard points.count <= LiDARScanLimits.mapVoxelsV3, points.allSatisfy({ $0.array.allSatisfy { $0.isFinite && abs($0) < 1000 } }) else {
            throw LiDARScanError.invalid("点云超出运行文件的范围")
        }
        var data = Data(capacity: points.count*12)
        for p in points { for v in p.array {
            var bits = Float(v).bitPattern.littleEndian
            withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) }
        } }
        return data
    }
    public static func decode(_ data: Data, count: Int) throws -> [ProbePoint] {
        guard (0...LiDARScanLimits.mapVoxelsV3).contains(count),data.count == count*12 else { throw LiDARScanError.invalid("运行点云长度不符") }
        let points: [ProbePoint] = data.withUnsafeBytes { raw in
            func value(_ offset: Int) -> Double { Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:offset,as:UInt32.self)))) }
            return (0..<count).map { ProbePoint(value($0*12),value($0*12+4),value($0*12+8)) }
        }
        guard points.allSatisfy({ $0.array.allSatisfy { $0.isFinite && abs($0) < 1000 } }) else { throw LiDARScanError.invalid("运行点云含无效坐标") }
        return points
    }
}

/// A result can be used only in the ARSession that generated its query.
public struct LiDARSessionAlignment {
    public private(set) var sessionID: String
    public private(set) var mapFromSession: [[Double]]?
    public init(sessionID: String) { self.sessionID = sessionID }
    public mutating func reset(sessionID: String) { self.sessionID = sessionID; mapFromSession = nil }
    public mutating func accept(_ transform: [[Double]], sessionID: String) throws {
        guard self.sessionID == sessionID, RigidMatrix.valid(transform) else {
            throw LiDARScanError.invalid("定位结果属于旧会话或变换无效，请重新定位")
        }
        mapFromSession = transform
    }
    public func cameraInMap(_ sessionFromCamera: [[Double]]) throws -> [[Double]] {
        guard let mapFromSession, RigidMatrix.valid(sessionFromCamera) else { throw LiDARScanError.invalid("会话尚未定位") }
        return CampusMapGeometry.multiply(mapFromSession,sessionFromCamera)
    }
}

/// The same archive implementation is exercised by core tests and the UI.
public enum LiDARNavigationArchive {
    /// Files kept by the lightweight export and by raw-data cleanup. Sidecars are optional.
    public static let lightweightFiles = ["navigation.json","geometry.f32","reference.jpg","budget-summary.json","capture-summary.json","landmarks.json","placement.json","magnetic-reference.json","magnetic-samples.json","magnetic-samples.jsonl","passage-calibration.json","walked-trajectory.json"]
    public static func write<T:Encodable>(_ value:T,to url:URL) throws {
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(value).write(to:url,options:.atomic)
    }
    public static func load(_ directory:URL) throws -> (LiDARNavigationMap,[ProbePoint]) { try load(directory,insideTransaction:false) }
    /// insideTransaction: only for publish/restore checking the state they are about to commit.
    static func load(_ directory:URL,insideTransaction:Bool) throws -> (LiDARNavigationMap,[ProbePoint]) {
        // An unfinished publish/restore may have mixed two versions: never open it as a map.
        guard insideTransaction || !LiDARMapVersions.hasOpenTransaction(directory) else { throw LiDARScanError.invalid("这张地图的上次更新未完成，等待恢复后才能使用") }
        let metadata = directory.appendingPathComponent("navigation.json")
        let bytes = try Data(contentsOf:metadata)
        guard bytes.count <= 1_048_576 else { throw LiDARScanError.invalid("地图元数据过大") }
        let map = try JSONDecoder().decode(LiDARNavigationMap.self,from:bytes);try map.validate()
        let points = try LiDARPointFile.decode(Data(contentsOf:directory.appendingPathComponent(map.points_file)),count:map.point_count)
        return (map,points)
    }
    public static func importZIP(_ zip:URL,into root:URL) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-import-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let source = try CampusBackupZIP.extract(zip,to:temp);try CampusFiles.verify(source)
        let (map,_) = try load(source)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let destination = root.appendingPathComponent("map-"+map.map_id)
        guard !FileManager.default.fileExists(atPath:destination.path) else { throw LiDARScanError.invalid("这张地图已经存在，未覆盖原数据") }
        try FileManager.default.moveItem(at:source,to:destination);return destination
    }
    public static func exportZIP(_ directory:URL,to output:URL) throws {
        let (map,_) = try load(directory)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("geometry-export-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temp) }
        let folder = temp.appendingPathComponent("map-"+map.map_id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for name in LiDARNavigationArchive.lightweightFiles {
            let source = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:source.path) { try FileManager.default.copyItem(at:source,to:folder.appendingPathComponent(name)) }
        }
        // Landmark evidence images travel with the lightweight map; it is small by design.
        let landmarks = directory.appendingPathComponent(LiDARLandmarkSet.directoryName)
        if FileManager.default.fileExists(atPath:landmarks.path) {
            try FileManager.default.copyItem(at:landmarks,to:folder.appendingPathComponent(LiDARLandmarkSet.directoryName))
        }
        try ProbeIO.makeManifest(at:folder);try ProbeZip.create(directory:folder,destination:output)
    }
    /// Cleaning diagnostic depth must not also delete the navigable map.
    public static func removeRawScanData(in directory:URL) throws {
        _ = try load(directory)
        for name in ["frames","scan.json","preview.ply","events.jsonl","on-device-result.json"] {
            let file = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
        }
        try ProbeIO.makeManifest(at:directory)
    }
}

/// Pure route editing for the mapping screen. Every command can be undone; undo restores
/// the full previous state, so linked edges and the connection start come back together.
/// Names are never cleared: unnamed nodes get the next free automatic number.
public struct LiDARRouteEditor: Equatable {
    public private(set) var nodes: [LiDARRouteNode]
    public private(set) var edges: [LiDARRouteEdge]
    /// The node the next added node connects from; nil means the next node starts a new branch.
    public private(set) var connectFrom: String?
    public private(set) var dirty = false
    /// Space routing: points are semantic only; nothing is connected automatically.
    public var spaceMode = false
    private struct State: Equatable { var nodes: [LiDARRouteNode]; var edges: [LiDARRouteEdge]; var connectFrom: String?; var title: String }
    private var history = [State]()
    public init(nodes: [LiDARRouteNode] = [], edges: [LiDARRouteEdge] = []) {
        self.nodes = nodes; self.edges = edges; connectFrom = nodes.last?.id
        for i in self.edges.indices where self.edges[i].id == nil { self.edges[i].id = UUID().uuidString }
    }
    public var canUndo: Bool { !history.isEmpty }
    /// Title of the command that undo would revert.
    public var undoTitle: String? { history.last?.title }
    private mutating func record(_ title: String) {
        history.append(State(nodes:nodes,edges:edges,connectFrom:connectFrom,title:title))
        if history.count > 200 { history.removeFirst() }
        dirty = true
    }
    public func node(_ id: String) -> LiDARRouteNode? { nodes.first { $0.id == id } }
    public static func automaticName(_ n: Int) -> String { "节点\(n)" }
    private func nextAutomaticNumber() -> Int {
        let used = nodes.compactMap { node -> Int? in
            guard node.name.hasPrefix("节点") else { return nil };return Int(node.name.dropFirst(2))
        }
        return (used.max() ?? 0)+1
    }
    /// Adds a node and, unless a new branch was started, connects it from `connectFrom`.
    @discardableResult
    public mutating func addNode(name: String?, kind: CampusNodeKind = .waypoint, position: ProbePoint,
                                 capture: LiDARNodeCaptureContext? = nil, id: String = UUID().uuidString) throws -> LiDARRouteNode {
        guard position.array.allSatisfy({ $0.isFinite && abs($0) < 1000 }),nodes.count < LiDARNavigationMap.maxNodes,!nodes.contains(where: { $0.id == id }) else {
            throw LiDARScanError.invalid("节点位置无效或节点过多")
        }
        let trimmed = name?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        guard trimmed.count <= 120 else { throw LiDARScanError.invalid("名称过长") }
        record("标点")
        let node = LiDARRouteNode(name:trimmed.isEmpty ? Self.automaticName(nextAutomaticNumber()) : trimmed,position:position,id:id,kind:kind,capture:capture)
        if !spaceMode,let from = connectFrom,nodes.contains(where: { $0.id == from }) { edges.append(LiDARRouteEdge(from,node.id,id:UUID().uuidString)) }
        nodes.append(node);connectFrom = spaceMode ? nil : node.id
        return node
    }
    /// The next added node will not be connected to any existing node.
    public mutating func startNewBranch() { guard connectFrom != nil else { return };record("开始新分支");connectFrom = nil }
    public mutating func setConnectFrom(_ id: String) throws {
        guard nodes.contains(where: { $0.id == id }) else { throw LiDARScanError.invalid("节点不存在") }
        guard connectFrom != id else { return }
        record("切换连线起点");connectFrom = id
    }
    public mutating func connect(_ a: String,_ b: String) throws {
        guard a != b,nodes.contains(where: { $0.id == a }),nodes.contains(where: { $0.id == b }),edges.count < LiDARNavigationMap.maxEdges else {
            throw LiDARScanError.invalid("连线端点无效")
        }
        guard !edges.contains(where: { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }) else {
            throw LiDARScanError.invalid("这两个节点已经相连")
        }
        record("连接节点");edges.append(LiDARRouteEdge(a,b,id:UUID().uuidString))
    }
    public mutating func rename(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard let i = nodes.firstIndex(where: { $0.id == id }),!trimmed.isEmpty,trimmed.count <= 120 else {
            throw LiDARScanError.invalid("名称无效")
        }
        guard nodes[i].name != trimmed else { return }
        record("修改名称");nodes[i].name = trimmed
    }
    public mutating func setKind(_ id: String, _ kind: CampusNodeKind) throws {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { throw LiDARScanError.invalid("节点不存在") }
        guard nodes[i].kind != kind else { return }
        record("修改类型");nodes[i].kind = kind
    }
    /// Removes a node and every edge touching it.
    public mutating func removeNode(_ id: String) throws {
        guard nodes.contains(where: { $0.id == id }) else { throw LiDARScanError.invalid("节点不存在") }
        record("删除节点")
        nodes.removeAll { $0.id == id };edges.removeAll { $0.from == id || $0.to == id }
        if connectFrom == id { connectFrom = nodes.last?.id }
    }
    public mutating func removeEdge(id: String) throws {
        guard edges.contains(where: { $0.id == id }) else { throw LiDARScanError.invalid("连线不存在") }
        record("删除连线");edges.removeAll { $0.id == id }
    }
    public struct EntranceAttachment: Equatable {
        /// connected_to_node: joined an existing node; split_edge: a waypoint was inserted on an edge.
        public var kind: String
        public var join: ProbePoint
        public var distance_m: Double
        public var joinedNodeID: String
    }
    /// Adds a room entrance (kind .room) and joins it to the nearest point of the network
    /// within `attachRadius`: to an edge endpoint if the projection is within 0.3 m of it,
    /// otherwise by splitting that edge with a new waypoint. One undoable command; the
    /// current connection start is left unchanged.
    @discardableResult
    public mutating func addEntrance(name: String, position: ProbePoint, capture: LiDARNodeCaptureContext? = nil,
                                     attachRadius: Double = 3.0, id: String = UUID().uuidString) throws -> (node: LiDARRouteNode, attachment: EntranceAttachment) {
        let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,trimmed.count <= 120 else { throw LiDARScanError.invalid("房间需要名称") }
        guard position.array.allSatisfy({ $0.isFinite && abs($0) < 1000 }),nodes.count < LiDARNavigationMap.maxNodes-1,!nodes.contains(where: { $0.id == id }) else {
            throw LiDARScanError.invalid("入口位置无效或节点过多")
        }
        if spaceMode {
            // Space routing: the entrance is a semantic point; reachability is checked by the planner.
            record("添加房间入口")
            let entrance = LiDARRouteNode(name:trimmed,position:position,id:id,kind:.room,capture:capture)
            nodes.append(entrance)
            return (entrance,EntranceAttachment(kind:"space_point",join:position,distance_m:0,joinedNodeID:entrance.id))
        }
        guard let target = nearestJoin(position) else { throw LiDARScanError.invalid("请先标出路线，入口需要接到路网上") }
        guard target.distance <= attachRadius else {
            throw LiDARScanError.invalid(String(format:"入口离最近的路线 %.1f 米，超过 %.0f 米，请先把路线标到门口附近",target.distance,attachRadius))
        }
        let keepFrom = connectFrom
        record("添加房间入口")
        let entrance = LiDARRouteNode(name:trimmed,position:position,id:id,kind:.room,capture:capture)
        var joinedID = target.nodeID,kind = "connected_to_node"
        if joinedID == nil,let edgeIndex = target.edgeIndex {
            let edge = edges.remove(at:edgeIndex)
            let waypoint = LiDARRouteNode(name:Self.automaticName(nextAutomaticNumber()),position:target.point,kind:.waypoint)
            nodes.append(waypoint)
            edges.append(LiDARRouteEdge(edge.from,waypoint.id,id:UUID().uuidString));edges.append(LiDARRouteEdge(waypoint.id,edge.to,id:UUID().uuidString))
            joinedID = waypoint.id;kind = "split_edge"
        }
        nodes.append(entrance);edges.append(LiDARRouteEdge(joinedID!,entrance.id,id:UUID().uuidString))
        connectFrom = keepFrom
        return (entrance,EntranceAttachment(kind:kind,join:target.point,distance_m:target.distance,joinedNodeID:joinedID!))
    }
    /// Nearest join on the network in XZ: an edge projection, snapped to an endpoint within 0.3 m;
    /// a lone node when there are no edges yet.
    public func nearestJoin(_ p: ProbePoint) -> (point: ProbePoint, distance: Double, nodeID: String?, edgeIndex: Int?)? {
        let byID = Dictionary(uniqueKeysWithValues:nodes.map { ($0.id,$0) })
        var best: (ProbePoint,Double,String?,Int?)?
        for (i,e) in edges.enumerated() {
            guard let a = byID[e.from]?.position,let b = byID[e.to]?.position else { continue }
            let dx = b.x-a.x,dz = b.z-a.z,l2 = dx*dx+dz*dz
            let t = l2 > 1e-9 ? min(1,max(0,((p.x-a.x)*dx+(p.z-a.z)*dz)/l2)) : 0
            let q = ProbePoint(a.x+t*dx,a.y+t*(b.y-a.y),a.z+t*dz),d = hypot(p.x-q.x,p.z-q.z)
            let length = sqrt(l2)
            let snapped: String? = t*length <= 0.3 ? e.from : (1-t)*length <= 0.3 ? e.to : nil
            let point = snapped.map { byID[$0]!.position } ?? q
            if best == nil || d < best!.1 { best = (point,d,snapped,snapped == nil ? i : nil) }
        }
        if best == nil {
            for n in nodes where n.resolvedKind != .room {
                let d = hypot(p.x-n.position.x,p.z-n.position.z)
                if best == nil || d < best!.1 { best = (n.position,d,n.id,nil) }
            }
        }
        return best.map { (point:$0.0,distance:$0.1,nodeID:$0.2,edgeIndex:$0.3) }
    }
    /// Reverts the last command and returns its title.
    @discardableResult public mutating func undo() -> String? {
        guard let last = history.popLast() else { return nil }
        nodes = last.nodes;edges = last.edges;connectFrom = last.connectFrom;dirty = true
        return last.title
    }
    public mutating func markSaved() { dirty = false }
    /// Problems that block a navigable map; empty means it can be saved for navigation.
    public func issues() -> [String] {
        if spaceMode { return nodes.isEmpty ? ["至少需要标出一个地点"] : [] }
        var result = [String]()
        if nodes.count < 2 { result.append("至少需要两个节点") }
        if edges.isEmpty { result.append("至少需要一条连线") }
        let map = LiDARNavigationMap(mapID:UUID().uuidString,sessionID:UUID().uuidString,name:"draft",pointCount:100,nodes:nodes,edges:edges)
        let groups = map.components()
        if groups.count > 1 { result.append("路网分成 \(groups.count) 段，请连接后再保存") }
        let connected = Set(edges.flatMap { [$0.from,$0.to] })
        let loose = nodes.filter { $0.resolvedKind == .room && !connected.contains($0.id) }
        if !loose.isEmpty { result.append("\(loose.count) 个房间入口没有接入路网，暂时不能导航到") }
        return result
    }
    public struct SaveCheck: Equatable {
        /// Must be fixed before saving a navigable map.
        public var blocking: [String]
        /// Shown for confirmation; saving may continue.
        public var warnings: [String]
        public var platesWithoutEntrance: [String]
    }
    /// Blocking: fewer than two nodes, no edge, a split network, or a room entrance not joined
    /// to the network. Warning only: plates that have no entrance yet.
    public func saveCheck(landmarks: LiDARLandmarkSet? = nil) -> SaveCheck {
        let plates = Self.platesWithoutEntrance(landmarks)
        return SaveCheck(blocking:issues(),warnings:plates.isEmpty ? [] : ["\(plates.count) 块门牌还没有设置入口，不会出现在目的地列表里，但仍可辅助定位"],
                         platesWithoutEntrance:plates.map(\.id))
    }
    /// Plates without a routable entrance: a reminder only; they still help localization.
    public static func platesWithoutEntrance(_ set: LiDARLandmarkSet?) -> [LiDARLandmark] {
        (set?.landmarks ?? []).filter { $0.category == .room_plate && !$0.destination.enabled }
    }
    public func map(mapID: String, sessionID: String, name: String, pointCount: Int, voxel: Double) -> LiDARNavigationMap {
        var map = LiDARNavigationMap(mapID:mapID,sessionID:sessionID,name:name,pointCount:pointCount,nodes:nodes,edges:edges)
        map.voxel_m = voxel;map.destination_policy = LiDARNavigationMap.roomsAndNamedStairs
        if spaceMode { map.routing_mode = LiDARNavigationMap.spaceRouting }
        return map
    }
}

// MARK: - Landmarks (stage 2a): landmarks.json beside navigation.json

/// Evidence for one confirmed observation: enough to recompute the 3D result later.
public struct LiDARLandmarkEvidence: Codable, Equatable {
    public var timestamp: Double
    public var session_id: String
    public var generation: Int?
    public var camera_to_session: [[Double]]
    public var calibration: LiDARCalibration
    /// Native-orientation high-quality JPEG relative to the map directory, e.g. landmarks/<id>/0.jpg.
    public var image_file: String
    /// Optional depth / confidence copies for recomputation, relative paths.
    public var depth_file: String?
    public var confidence_file: String?
    /// [x, y, w, h] native pixels, origin top-left.
    public var native_box: [Double]
    public var orientation = "right"
    /// ocr_selection: the box of the text the user selected; none_full_image: no plate box
    /// (manual text entry), native_box is the whole image and must not be used as a plate box.
    /// nil in files written before this field existed.
    public var box_source: String?
    /// Frame of camera_to_session: "map" when a supplement already moved it into map coordinates;
    /// nil means the capture session's own coordinates (all files before supplements). Never re-transform a "map" pose.
    public var pose_frame: String?
    public init(timestamp: Double, session_id: String, generation: Int?, camera_to_session: [[Double]], calibration: LiDARCalibration,
                image_file: String, depth_file: String? = nil, confidence_file: String? = nil, native_box: [Double], box_source: String? = nil) {
        self.timestamp = timestamp; self.session_id = session_id; self.generation = generation; self.camera_to_session = camera_to_session
        self.calibration = calibration; self.image_file = image_file; self.depth_file = depth_file; self.confidence_file = confidence_file
        self.native_box = native_box; self.box_source = box_source
    }
}

public struct LiDARLandmarkText: Codable, Equatable {
    public var raw: String
    public var normalized: String
    public var candidates: [LiDARTextCandidate]
    /// The user confirmed (or typed) this text.
    public var confirmed_by_user: Bool
    /// The user changed the recognized text.
    public var edited: Bool
    public init(raw: String, candidates: [LiDARTextCandidate], confirmedByUser: Bool, edited: Bool) {
        self.raw = raw; normalized = LiDARText.normalize(raw); self.candidates = candidates
        confirmed_by_user = confirmedByUser; self.edited = edited
    }
}

/// Whether the landmark can be a navigation destination. Enabling requires a routable
/// binding; a confirmed category alone does not make it routable.
public struct LiDARLandmarkDestination: Codable, Equatable {
    public var enabled: Bool
    public var node_id: String?
    public init(enabled: Bool, node_id: String?) { self.enabled = enabled; self.node_id = node_id }
}

public struct LiDARLandmark: Codable, Equatable {
    public enum Category: String, Codable { case room_plate, reference_feature }
    public enum Trigger: String, Codable { case manual, auto }
    /// One physical entity. Equal texts stay separate entities; never merged for a list.
    public var id: String
    public var category: Category
    public var trigger: Trigger
    public var text: LiDARLandmarkText
    public var destination: LiDARLandmarkDestination
    public var geometry: LiDARLandmarkGeometryResult
    public var evidence: [LiDARLandmarkEvidence]
    public var best_crop: String?
    public var created_utc: String
    /// Where the plate is fixed. A plate on a door moves with the door, so its position and
    /// normal must never constrain a pose; it stays text / region evidence only.
    public enum Mount: String, Codable { case wall, door, unknown }
    /// nil in files written before this field existed; treat as unknown.
    public var mount: Mount?
    /// True only for a wall-mounted plate with a measured geometry.
    public var usableForPose: Bool { mount == .wall && geometry.status == "measured" }
    /// Name shown to people and used for the entrance (e.g. "132" for a plate reading "3-132").
    /// nil: the plate text. Recognition always uses `text` (exact, normalized), never this name.
    public var display_name: String?
    public var displayName: String { display_name ?? text.raw }
    public init(id: String = UUID().uuidString, category: Category, trigger: Trigger, text: LiDARLandmarkText,
                destination: LiDARLandmarkDestination, geometry: LiDARLandmarkGeometryResult, evidence: [LiDARLandmarkEvidence],
                best_crop: String? = nil, created_utc: String = ISO8601DateFormatter().string(from: Date())) {
        self.id = id; self.category = category; self.trigger = trigger; self.text = text; self.destination = destination
        self.geometry = geometry; self.evidence = evidence; self.best_crop = best_crop; self.created_utc = created_utc
    }
}

public struct LiDARLandmarkSet: Codable, Equatable {
    public static let fileName = "landmarks.json"
    public static let directoryName = "landmarks"
    public var schema_version = 1
    public var kind = "lidar_landmarks"
    public var map_id: String
    public var coordinate_system = "ARKit_Y_up_camera_minus_Z_row_major_meters"
    /// SHA-256 of geometry.f32 when the landmarks were measured; nil if unknown.
    public var geometry_sha256: String?
    public var landmarks: [LiDARLandmark]
    public init(mapID: String, geometrySHA256: String?, landmarks: [LiDARLandmark] = []) {
        map_id = mapID; geometry_sha256 = geometrySHA256; self.landmarks = landmarks
    }
    /// Rules: manual room plates need user-confirmed text; auto features are never room
    /// plates and never destinations; a destination needs an existing node; files stay inside
    /// the landmarks/ directory.
    public func validate(against map: LiDARNavigationMap) throws {
        guard schema_version == 1, kind == "lidar_landmarks", map_id == map.map_id,
              coordinate_system == map.coordinate_system, landmarks.count <= 500,
              Set(landmarks.map(\.id)).count == landmarks.count else { throw LiDARScanError.invalid("门牌数据与地图不匹配") }
        let nodes = Set(map.nodes.map(\.id))
        func inside(_ path: String) -> Bool {
            path.hasPrefix(Self.directoryName+"/") && !path.contains("..") && !path.hasPrefix("/") && !path.contains("\\")
        }
        for l in landmarks {
            guard !l.id.isEmpty, l.text.raw.count <= 200, l.text.normalized == LiDARText.normalize(l.text.raw),
                  l.display_name.map({ let t = $0.trimmingCharacters(in: .whitespacesAndNewlines); return !t.isEmpty && t == $0 && t.count <= 120 }) ?? true else {
                throw LiDARScanError.invalid("门牌文字无效")
            }
            if l.category == .room_plate { guard l.trigger == .manual, l.text.confirmed_by_user else { throw LiDARScanError.invalid("门牌需要人工确认") } }
            if l.trigger == .auto { guard l.category == .reference_feature, !l.destination.enabled else { throw LiDARScanError.invalid("自动识别的特征不能作为门牌或目的地") } }
            if l.destination.enabled {
                guard let id = l.destination.node_id, nodes.contains(id) else { throw LiDARScanError.invalid("目的地需要绑定已有节点") }
                guard map.nodes.first(where: { $0.id == id })?.resolvedKind == .room else { throw LiDARScanError.invalid("门牌目的地需要绑定房间入口节点") }
            }
            if let id = l.destination.node_id { guard nodes.contains(id) else { throw LiDARScanError.invalid("门牌绑定的节点不存在") } }
            let finite = { (p: ProbePoint?) in p.map { $0.array.allSatisfy { $0.isFinite && abs($0) < 1000 } } ?? true }
            guard (l.geometry.status == "unknown" && l.geometry.center == nil) ||
                  (l.geometry.status == "measured" && l.geometry.center != nil && l.geometry.normal != nil),
                  finite(l.geometry.center), finite(l.geometry.normal), l.geometry.spread_m.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw LiDARScanError.invalid("门牌三维状态无效")
            }
            guard l.evidence.count <= Self.maxEvidencePerLandmark else { throw LiDARScanError.invalid("门牌证据帧过多") }
            for e in l.evidence {
                let c = e.calibration,b = e.native_box
                guard [nil,"ocr_selection","none_full_image"].contains(e.box_source),
                      inside(e.image_file), e.depth_file.map(inside) ?? true, e.confidence_file.map(inside) ?? true,
                      e.timestamp.isFinite, RigidMatrix.valid(e.camera_to_session),
                      b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0, b[0] >= 0, b[1] >= 0,
                      b[0]+b[2] <= Double(c.image_width)+0.5, b[1]+b[3] <= Double(c.image_height)+0.5 else {
                    throw LiDARScanError.invalid("门牌证据文件或框无效")
                }
                try c.validate()
            }
            if let crop = l.best_crop { guard inside(crop) else { throw LiDARScanError.invalid("门牌裁切图路径无效") } }
        }
    }
    public static let maxEvidencePerLandmark = 10
    /// Per evidence file (JPEG, depth or confidence copy).
    public static let maxEvidenceFileBytes = 8_000_000
    /// Loads and validates landmarks.json. When `geometrySHA256` is given and the file recorded a
    /// different hash, the landmarks were measured on other geometry and are rejected. Every
    /// referenced evidence file must exist inside the map directory and stay under the size cap.
    public static func load(_ directory: URL, map: LiDARNavigationMap, geometrySHA256: String? = nil) throws -> LiDARLandmarkSet? {
        try loadReport(directory,map:map,geometrySHA256:geometrySHA256)?.set
    }
    /// Plates saved before room entrances existed may point their destination at a plain route
    /// node. Those destinations are disabled in memory (the binding is kept, the file is not
    /// rewritten) so the map still opens; `downgraded` lists the affected landmark ids.
    public static func downgradeLegacyDestinations(_ set: LiDARLandmarkSet, map: LiDARNavigationMap) -> (set: LiDARLandmarkSet, downgraded: [String]) {
        var copy = set,downgraded = [String]()
        let rooms = Set(map.nodes.filter { $0.resolvedKind == .room }.map(\.id)),ids = Set(map.nodes.map(\.id))
        for i in copy.landmarks.indices where copy.landmarks[i].destination.enabled {
            let node = copy.landmarks[i].destination.node_id
            if let node,ids.contains(node),!rooms.contains(node) {
                copy.landmarks[i].destination.enabled = false;downgraded.append(copy.landmarks[i].id)
            }
        }
        return (copy,downgraded)
    }
    public static func loadReport(_ directory: URL, map: LiDARNavigationMap, geometrySHA256: String? = nil) throws -> (set: LiDARLandmarkSet, downgraded: [String])? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let data = try Data(contentsOf:url);guard data.count <= 4_194_304 else { throw LiDARScanError.invalid("门牌数据过大") }
        let (set,downgraded) = downgradeLegacyDestinations(try JSONDecoder().decode(LiDARLandmarkSet.self,from:data),map:map)
        try set.validate(against:map)
        if let expected = geometrySHA256,let recorded = set.geometry_sha256,expected != recorded {
            throw LiDARScanError.invalid("门牌数据与当前几何不匹配")
        }
        let root = directory.standardizedFileURL.path
        for l in set.landmarks {
            for path in l.evidence.flatMap({ [$0.image_file,$0.depth_file,$0.confidence_file].compactMap { $0 } })+[l.best_crop].compactMap({ $0 }) {
                let file = directory.appendingPathComponent(path).standardizedFileURL
                guard file.path.hasPrefix(root+"/"),
                      let size = try? FileManager.default.attributesOfItem(atPath:file.path)[.size] as? Int,
                      size <= maxEvidenceFileBytes else { throw LiDARScanError.invalid("门牌证据文件缺失或过大：\(path)") }
            }
        }
        return (set,downgraded)
    }
}

// MARK: - Building → floor → region (ARProbe's hierarchy; one LiDAR map is one region for now)

/// Buildings and floors of the map library, stored at the library root. Each map's own placement
/// lives in its folder (`placement.json`) so a single-map export keeps its building and floor.
public struct LiDARCampusCatalog: Codable, Equatable {
    public static let fileName = "campus-catalog.json"
    public struct Floor: Codable, Equatable {
        public var id: String, name: String
        /// Optional storey number for ordering (e.g. -1, 1, 2); nil sorts after numbered floors.
        public var level: Int?
        public init(name: String, level: Int? = nil, id: String = UUID().uuidString) { self.id = id; self.name = name; self.level = level }
    }
    public struct Building: Codable, Equatable {
        public var id: String, name: String
        public var floors: [Floor]
        public init(name: String, floors: [Floor] = [], id: String = UUID().uuidString) { self.id = id; self.name = name; self.floors = floors }
        public var sortedFloors: [Floor] {
            floors.sorted { ($0.level ?? .max, $0.name) < ($1.level ?? .max, $1.name) }
        }
    }
    public var schema_version = 1
    public var buildings: [Building] = []
    public init(buildings: [Building] = []) { self.buildings = buildings }

    public static func cleanName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw LiDARScanError.invalid("名称不能为空，且不超过60个字") }
        return name
    }
    public func validate() throws {
        guard schema_version == 1 else { throw LiDARScanError.invalid("楼栋目录版本不受支持") }
        var ids = Set<String>(), names = Set<String>()
        for b in buildings {
            _ = try Self.cleanName(b.name)
            guard ids.insert(b.id).inserted, names.insert(b.name).inserted else { throw LiDARScanError.invalid("楼栋编号或名称重复") }
            var floorNames = Set<String>()
            for f in b.floors {
                _ = try Self.cleanName(f.name)
                guard ids.insert(f.id).inserted, floorNames.insert(f.name).inserted else { throw LiDARScanError.invalid("「\(b.name)」中楼层编号或名称重复") }
            }
        }
    }
    public func building(_ id: String) -> Building? { buildings.first { $0.id == id } }
    public func resolve(_ placement: LiDARMapPlacement) -> (building: Building, floor: Floor)? {
        guard let b = building(placement.building_id), let f = b.floors.first(where: { $0.id == placement.floor_id }) else { return nil }
        return (b, f)
    }
    @discardableResult public mutating func addBuilding(_ raw: String) throws -> Building {
        let name = try Self.cleanName(raw)
        guard !buildings.contains(where: { $0.name == name }) else { throw LiDARScanError.invalid("已有同名楼栋") }
        let b = Building(name: name); buildings.append(b); return b
    }
    @discardableResult public mutating func addFloor(_ raw: String, level: Int? = nil, to buildingID: String) throws -> Floor {
        let name = try Self.cleanName(raw)
        guard let i = buildings.firstIndex(where: { $0.id == buildingID }) else { throw LiDARScanError.invalid("楼栋不存在") }
        guard !buildings[i].floors.contains(where: { $0.name == name }) else { throw LiDARScanError.invalid("该楼栋已有同名楼层") }
        let f = Floor(name: name, level: level); buildings[i].floors.append(f); return f
    }
    public mutating func renameBuilding(_ id: String, to raw: String) throws {
        let name = try Self.cleanName(raw)
        guard let i = buildings.firstIndex(where: { $0.id == id }) else { throw LiDARScanError.invalid("楼栋不存在") }
        guard !buildings.contains(where: { $0.id != id && $0.name == name }) else { throw LiDARScanError.invalid("已有同名楼栋") }
        buildings[i].name = name
    }
    public mutating func renameFloor(_ id: String, in buildingID: String, to raw: String, level: Int?) throws {
        let name = try Self.cleanName(raw)
        guard let i = buildings.firstIndex(where: { $0.id == buildingID }), let j = buildings[i].floors.firstIndex(where: { $0.id == id }) else { throw LiDARScanError.invalid("楼层不存在") }
        guard !buildings[i].floors.contains(where: { $0.id != id && $0.name == name }) else { throw LiDARScanError.invalid("该楼栋已有同名楼层") }
        buildings[i].floors[j].name = name; buildings[i].floors[j].level = level
    }
    /// Removal never orphans a map: anything still placed there must be moved first.
    public mutating func removeBuilding(_ id: String, placements: [LiDARMapPlacement]) throws {
        guard !placements.contains(where: { $0.building_id == id }) else { throw LiDARScanError.invalid("楼栋中仍有地图，请先移动或删除地图") }
        buildings.removeAll { $0.id == id }
    }
    public mutating func removeFloor(_ id: String, in buildingID: String, placements: [LiDARMapPlacement]) throws {
        guard !placements.contains(where: { $0.floor_id == id }) else { throw LiDARScanError.invalid("楼层中仍有地图，请先移动或删除地图") }
        guard let i = buildings.firstIndex(where: { $0.id == buildingID }) else { return }
        buildings[i].floors.removeAll { $0.id == id }
    }
    /// For an imported map whose building or floor is unknown here: add them under the IDs and
    /// names the map carried. Returns false (catalog unchanged) when an ID or name would clash,
    /// in which case the map stays unclassified for the user to place by hand.
    @discardableResult public mutating func adopt(_ p: LiDARMapPlacement) -> Bool {
        if resolve(p) != nil { return true }
        var next = self
        if let i = next.buildings.firstIndex(where: { $0.id == p.building_id }) {
            next.buildings[i].floors.append(Floor(name: p.floor_name, id: p.floor_id))
        } else {
            next.buildings.append(Building(name: p.building_name, floors: [Floor(name: p.floor_name, id: p.floor_id)], id: p.building_id))
        }
        guard (try? next.validate()) != nil else { return false }
        self = next; return true
    }
    public static func load(root: URL) throws -> LiDARCampusCatalog {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return LiDARCampusCatalog() }
        let catalog = try JSONDecoder().decode(LiDARCampusCatalog.self, from: Data(contentsOf: url))
        try catalog.validate(); return catalog
    }
    public func save(root: URL) throws {
        try validate(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try LiDARNavigationArchive.write(self, to: root.appendingPathComponent(Self.fileName))
    }
}

/// Where one map belongs. Names are copies kept only so an import can recreate a missing
/// building or floor; the catalog's names win whenever the IDs resolve.
public struct LiDARMapPlacement: Codable, Equatable {
    public static let fileName = "placement.json"
    public var schema_version = 1
    public var map_id: String
    public var building_id: String, building_name: String
    public var floor_id: String, floor_name: String
    public var region_name: String
    public init(mapID: String, building: LiDARCampusCatalog.Building, floor: LiDARCampusCatalog.Floor, region: String) throws {
        map_id = mapID; building_id = building.id; building_name = building.name
        floor_id = floor.id; floor_name = floor.name; region_name = try LiDARCampusCatalog.cleanName(region)
    }
    public func validate(mapID: String) throws {
        guard schema_version == 1, map_id == mapID else { throw LiDARScanError.invalid("归属文件与地图不符") }
        for name in [building_name, floor_name, region_name] { _ = try LiDARCampusCatalog.cleanName(name) }
        guard !building_id.isEmpty, !floor_id.isEmpty else { throw LiDARScanError.invalid("归属文件缺少楼栋或楼层编号") }
    }
    public enum Status: Equatable { case none, placed(LiDARMapPlacement), invalid(String) }
    /// A missing file means "unclassified"; a damaged one is reported, never guessed.
    public static func load(_ directory: URL, mapID: String) -> Status {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        do {
            let p = try JSONDecoder().decode(LiDARMapPlacement.self, from: Data(contentsOf: url))
            try p.validate(mapID: mapID); return .placed(p)
        } catch { return .invalid(error.localizedDescription) }
    }
    /// Placement is a sidecar: navigation.json and geometry are untouched, only the manifest is refreshed.
    public func write(to directory: URL) throws {
        let (map, _) = try LiDARNavigationArchive.load(directory)
        try validate(mapID: map.map_id)
        try LiDARNavigationArchive.write(self, to: directory.appendingPathComponent(Self.fileName))
        try ProbeIO.makeManifest(at: directory)
    }
}

/// Library view grouped as building → floor → maps (regions). Pure, for the home and picker screens.
public struct LiDARLibraryGrouping: Equatable {
    public struct Region: Equatable { public var map_id: String; public var name: String }
    public struct FloorGroup: Equatable { public var floor: LiDARCampusCatalog.Floor; public var regions: [Region] }
    public struct BuildingGroup: Equatable { public var building: LiDARCampusCatalog.Building; public var floors: [FloorGroup] }
    public struct Unclassified: Equatable { public var map_id: String; public var name: String; public var reason: String }
    public var buildings: [BuildingGroup]
    public var unclassified: [Unclassified]
    /// Region names that occur more than once on one floor (allowed, but confusing in pickers).
    public var duplicateRegionNames: [String]
    public init(catalog: LiDARCampusCatalog, maps: [(mapID: String, mapName: String, placement: LiDARMapPlacement.Status)]) {
        var byFloor = [String: [Region]](), loose = [Unclassified]()
        for m in maps {
            switch m.placement {
            case .none: loose.append(.init(map_id: m.mapID, name: m.mapName, reason: "未分类"))
            case .invalid(let reason): loose.append(.init(map_id: m.mapID, name: m.mapName, reason: "归属文件无效：\(reason)"))
            case .placed(let p):
                if catalog.resolve(p) != nil { byFloor[p.floor_id, default: []].append(.init(map_id: m.mapID, name: p.region_name)) }
                else { loose.append(.init(map_id: m.mapID, name: m.mapName, reason: "楼栋或楼层不在目录中（\(p.building_name) · \(p.floor_name)）")) }
            }
        }
        var duplicates = [String]()
        buildings = catalog.buildings.sorted { $0.name < $1.name }.map { b in
            BuildingGroup(building: b, floors: b.sortedFloors.map { f in
                let regions = (byFloor[f.id] ?? []).sorted { ($0.name, $0.map_id) < ($1.name, $1.map_id) }
                var seen = Set<String>()
                for r in regions where !seen.insert(r.name).inserted { duplicates.append("\(b.name) · \(f.name) · \(r.name)") }
                return FloorGroup(floor: f, regions: regions)
            })
        }
        unclassified = loose.sorted { ($0.name, $0.map_id) < ($1.name, $1.map_id) }
        duplicateRegionNames = Array(Set(duplicates)).sorted()
    }
}

// MARK: - Map versions (supplement saves update a map in place; the previous state stays restorable)

public enum LiDARMapVersions {
    public static let directoryName = "versions"
    /// The assignment to a building/floor is not part of a map version: restoring never moves a map.
    static let excluded: Set<String> = [LiDARMapPlacement.fileName]
    public struct Version: Codable, Equatable {
        public var id: String, created_utc: String, map_id: String
        public var point_count: Int, nodes: Int, edges: Int, sources: Int
    }
    private static func root(_ dir: URL) -> URL { dir.appendingPathComponent(directoryName, isDirectory: true) }
    /// Written before any published file is swapped and removed only after the new state loads:
    /// while it exists the folder may mix two versions, whatever load() says.
    public static let transactionFile = ".map-transaction.json"
    private struct Transaction: Codable { var backup_id: String; var operation: String; var started_utc: String }
    private static func begin(_ dir: URL, backup: String, operation: String) throws {
        try LiDARNavigationArchive.write(Transaction(backup_id: backup, operation: operation, started_utc: ISO8601DateFormatter().string(from: Date())),
                                         to: dir.appendingPathComponent(transactionFile))
    }
    private static func end(_ dir: URL) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(transactionFile)) }
    public static func hasOpenTransaction(_ dir: URL) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(transactionFile).path) }
    private static func isLink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    private static func versioned(_ dir: URL) -> [String] { LiDARNavigationArchive.lightweightFiles.filter { !excluded.contains($0) } }
    /// Copies the published map (lightweight files and plate evidence) into versions/<id>/.
    @discardableResult public static func snapshot(_ dir: URL) throws -> String {
        let (map, _) = try LiDARNavigationArchive.load(dir)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let id = f.string(from: Date()) + "-" + UUID().uuidString.prefix(6)
        let fm = FileManager.default, temp = root(dir).appendingPathComponent("." + id), final = root(dir).appendingPathComponent(id)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        do {
            for name in versioned(dir) {
                let src = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                guard !isLink(src) else { throw LiDARScanError.invalid("地图文件不能是链接") }
                try fm.copyItem(at: src, to: temp.appendingPathComponent(name))
            }
            let evidence = dir.appendingPathComponent(LiDARLandmarkSet.directoryName)
            if fm.fileExists(atPath: evidence.path) {
                guard !isLink(evidence) else { throw LiDARScanError.invalid("门牌证据目录不能是链接") }
                try fm.copyItem(at: evidence, to: temp.appendingPathComponent(LiDARLandmarkSet.directoryName))
            }
            let info = Version(id: id, created_utc: ISO8601DateFormatter().string(from: Date()), map_id: map.map_id,
                               point_count: map.point_count, nodes: map.nodes.count, edges: map.edges.count, sources: map.sources?.count ?? 1)
            try LiDARNavigationArchive.write(info, to: temp.appendingPathComponent("version.json"))
            try fm.moveItem(at: temp, to: final)
        } catch { try? fm.removeItem(at: temp); throw error }
        return id
    }
    /// Newest first. Unfinished or damaged versions are skipped.
    public static func list(_ dir: URL) -> [Version] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root(dir), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { !$0.lastPathComponent.hasPrefix(".") }.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("version.json")),
                  let v = try? JSONDecoder().decode(Version.self, from: data), v.id == url.lastPathComponent,
                  (try? LiDARNavigationArchive.load(url)) != nil else { return nil }
            return v
        }.sorted { $0.id > $1.id }
    }
    /// Replaces the published map with a version. The current state is snapshotted first, so a
    /// restore can itself be undone. navigation.json is written last.
    @discardableResult public static func restore(_ dir: URL, id: String) throws -> String {
        guard !id.contains("/"), !id.hasPrefix("."), list(dir).contains(where: { $0.id == id }) else { throw LiDARScanError.invalid("找不到这个地图版本") }
        let source = root(dir).appendingPathComponent(id), fm = FileManager.default
        let (old, _) = try LiDARNavigationArchive.load(source), (current, _) = try LiDARNavigationArchive.load(dir)
        guard old.map_id == current.map_id else { throw LiDARScanError.invalid("版本不属于这张地图") }
        let backup = try snapshot(dir)
        try begin(dir, backup: backup, operation: "restore")
        func replace(_ name: String) throws {
            let src = source.appendingPathComponent(name), dst = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                let staged = dir.appendingPathComponent(".restore-" + name)
                try? fm.removeItem(at: staged); try fm.copyItem(at: src, to: staged)
                if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: staged) } else { try fm.moveItem(at: staged, to: dst) }
            } else if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        }
        for name in versioned(dir) where name != "navigation.json" { try replace(name) }
        try replace(LiDARLandmarkSet.directoryName)
        try replace("navigation.json")
        try ProbeIO.makeManifest(at: dir)
        end(dir)
        return backup
    }
    /// Publishes a supplement save in place. `staged` holds the complete new lightweight files
    /// (and optionally landmarks/); it must load as a valid map with the same map_id. The current
    /// map is snapshotted first; any failure while swapping restores that snapshot, so the map
    /// never stays half-written. Returns the snapshot id of the previous state.
    @discardableResult public static func publish(_ dir: URL, staged: URL, keep: Int = 3) throws -> String {
        let (next, _) = try LiDARNavigationArchive.load(staged), (current, _) = try LiDARNavigationArchive.load(dir)
        guard next.map_id == current.map_id else { throw LiDARScanError.invalid("新数据不属于这张地图") }
        let backup = try snapshot(dir), fm = FileManager.default
        try begin(dir, backup: backup, operation: "publish")
        do {
            for name in versioned(dir) where name != "navigation.json" {
                let src = staged.appendingPathComponent(name), dst = dir.appendingPathComponent(name)
                guard fm.fileExists(atPath: src.path) else { continue }
                if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: src) } else { try fm.moveItem(at: src, to: dst) }
            }
            let evidence = staged.appendingPathComponent(LiDARLandmarkSet.directoryName), target = dir.appendingPathComponent(LiDARLandmarkSet.directoryName)
            if fm.fileExists(atPath: evidence.path) {
                if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: evidence) } else { try fm.moveItem(at: evidence, to: target) }
            }
            let nav = dir.appendingPathComponent("navigation.json")
            _ = try fm.replaceItemAt(nav, withItemAt: staged.appendingPathComponent("navigation.json"))
            _ = try LiDARNavigationArchive.load(dir, insideTransaction: true)
            try ProbeIO.makeManifest(at: dir)
            end(dir)
        } catch {
            if (try? restoreWithoutBackup(dir, id: backup)) != nil { end(dir) }
            throw error
        }
        try? prune(dir, keep: keep)
        return backup
    }
    private static func restoreWithoutBackup(_ dir: URL, id: String) throws {
        let source = root(dir).appendingPathComponent(id), fm = FileManager.default
        for name in versioned(dir) + [LiDARLandmarkSet.directoryName] where name != "navigation.json" {
            let src = source.appendingPathComponent(name), dst = dir.appendingPathComponent(name), staged = dir.appendingPathComponent(".restore-" + name)
            try? fm.removeItem(at: staged)
            if fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: staged)
                if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: staged) } else { try fm.moveItem(at: staged, to: dst) }
            } else if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        }
        let staged = dir.appendingPathComponent(".restore-navigation.json"); try? fm.removeItem(at: staged)
        try fm.copyItem(at: source.appendingPathComponent("navigation.json"), to: staged)
        let nav = dir.appendingPathComponent("navigation.json")
        if fm.fileExists(atPath: nav.path) { _ = try fm.replaceItemAt(nav, withItemAt: staged) } else { try fm.moveItem(at: staged, to: nav) }
        try ProbeIO.makeManifest(at: dir)
    }
    /// After an interrupted publish or restore (open transaction), rolls back to that operation's
    /// backup even if the mixed folder happens to load. Otherwise, for a folder that no longer loads,
    /// restores the newest valid version. Returns the version used, or nil when nothing was done.
    @discardableResult public static func recoverIfBroken(_ dir: URL) -> String? {
        if hasOpenTransaction(dir) {
            // Damaged marker, missing backup or failed rollback: leave everything as evidence; the map stays closed.
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(transactionFile)),
                  let t = try? JSONDecoder().decode(Transaction.self, from: data), list(dir).contains(where: { $0.id == t.backup_id }),
                  (try? restoreWithoutBackup(dir, id: t.backup_id)) != nil else { return nil }
            end(dir); return t.backup_id
        }
        guard (try? LiDARNavigationArchive.load(dir)) == nil, let newest = list(dir).first else { return nil }
        return (try? restoreWithoutBackup(dir, id: newest.id)) != nil ? newest.id : nil
    }
    /// Keeps the newest `keep` versions.
    public static func prune(_ dir: URL, keep: Int = 3) throws {
        for v in list(dir).dropFirst(max(0, keep)) { try FileManager.default.removeItem(at: root(dir).appendingPathComponent(v.id)) }
    }
    /// Copies plate evidence captured during a supplement scan into the map. Existing ids are
    /// never overwritten; links are refused. Returns the ids copied.
    @discardableResult public static func copyEvidence(from scan: URL, to map: URL, ids: [String]) throws -> [String] {
        let fm = FileManager.default, src = scan.appendingPathComponent(LiDARLandmarkSet.directoryName), dst = map.appendingPathComponent(LiDARLandmarkSet.directoryName)
        var copied = [String]()
        for id in ids {
            guard UUID(uuidString: id) != nil else { throw LiDARScanError.invalid("门牌编号无效") }
            let from = src.appendingPathComponent(id), to = dst.appendingPathComponent(id)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            guard !isLink(from) else { throw LiDARScanError.invalid("门牌证据不能是链接") }
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to); copied.append(id)
        }
        return copied
    }
}


// MARK: - Cross-map links and multi-map routes (ARProbe's stair pairing, per LiDAR map)

public struct LiDARNodeRef: Codable, Hashable {
    public var map_id: String, node_id: String
    public init(map: String, node: String) { map_id = map; node_id = node }
}

/// A walkable connection between two maps: stairs (stair ↔ stair nodes), elevator (elevator ↔
/// elevator nodes) or a same-floor walkway between region maps (any nodes). Costs are manual
/// walking-equivalent metres, not measured.
public struct LiDARMapLink: Codable, Equatable {
    public enum Kind: String, Codable, CaseIterable {
        case stairs, elevator, walkway
        public var title: String { switch self { case .stairs: return "楼梯"; case .elevator: return "电梯"; case .walkway: return "同层通道" } }
        public var defaultCost: Double { switch self { case .stairs: return 15; case .elevator: return 30; case .walkway: return 0 } }
        public var nodeKind: CampusNodeKind? { switch self { case .stairs: return .stair; case .elevator: return .elevator; case .walkway: return nil } }
    }
    public var id: String
    public var kind: Kind
    public var a: LiDARNodeRef, b: LiDARNodeRef
    public var cost_m: Double
    public var bidirectional = true
    public var enabled = true
    /// Shared by all links of one elevator shaft or stair core; reserved for elevator features.
    public var group_id: String?
    public init(kind: Kind, a: LiDARNodeRef, b: LiDARNodeRef, cost: Double? = nil, groupID: String? = nil, id: String = UUID().uuidString) {
        self.id = id; self.kind = kind; self.a = a; self.b = b; cost_m = cost ?? kind.defaultCost; group_id = groupID
    }
}

public struct LiDARCampusLinks: Codable, Equatable {
    public static let fileName = "campus-links.json"
    public var schema_version = 1
    public var links: [LiDARMapLink] = []
    public init(links: [LiDARMapLink] = []) { self.links = links }
    /// Structural checks only; maps that are not loaded are not judged here.
    public func validate() throws {
        guard schema_version == 1, Set(links.map(\.id)).count == links.count,
              links.allSatisfy({ $0.a.map_id != $0.b.map_id && $0.cost_m.isFinite && $0.cost_m >= 0 && $0.cost_m < 10_000 }) else {
            throw LiDARScanError.invalid("跨图连接记录无效")
        }
    }
    /// Node kinds must fit the link: stairs join stair nodes, elevators elevator nodes.
    public static func check(_ link: LiDARMapLink, maps: [String: LiDARNavigationMap]) throws {
        guard link.a.map_id != link.b.map_id else { throw LiDARScanError.invalid("连接的两端必须在不同地图") }
        for end in [link.a, link.b] {
            guard let node = maps[end.map_id]?.nodes.first(where: { $0.id == end.node_id }) else { throw LiDARScanError.invalid("连接端点不存在") }
            if let want = link.kind.nodeKind, node.resolvedKind != want { throw LiDARScanError.invalid("「\(node.name)」不是\(want.title)，不能用于\(link.kind.title)连接") }
        }
    }
    public mutating func add(_ link: LiDARMapLink, maps: [String: LiDARNavigationMap]) throws {
        try Self.check(link, maps: maps)
        guard !links.contains(where: { Set([$0.a, $0.b]) == Set([link.a, link.b]) }) else { throw LiDARScanError.invalid("这两个节点已经连接") }
        links.append(link)
    }
    public func links(touching mapID: String) -> [LiDARMapLink] { links.filter { $0.a.map_id == mapID || $0.b.map_id == mapID } }
    /// Elevator id ("电梯1"…) of an elevator link that already uses this node, if any.
    public func elevatorGroup(at ref: LiDARNodeRef) -> String? {
        links.first { $0.kind == .elevator && ($0.a == ref || $0.b == ref) && !($0.group_id ?? "").isEmpty }?.group_id
    }
    /// The next unused "电梯N" id.
    public func nextElevatorGroupName() -> String {
        let used = Set(links.compactMap(\.group_id))
        var n = 1
        while used.contains("电梯\(n)") { n += 1 }
        return "电梯\(n)"
    }
    /// Fills empty elevator ids. Elevator links that share an endpoint node belong to one elevator
    /// (1F↔2F and 2F↔3F through the same 2F door); such a group reuses an id already present in it,
    /// otherwise gets the next "电梯N". Deterministic for the same file, so callers can apply it in
    /// memory and the mapping tools can persist the identical result. Existing ids are never changed.
    public func resolvingElevatorGroups() -> (links: LiDARCampusLinks, assigned: Int) {
        var result = self
        let elevators = links.indices.filter { links[$0].kind == .elevator }
        var parent = Dictionary(uniqueKeysWithValues: elevators.map { ($0, $0) })
        func find(_ i: Int) -> Int { var i = i; while parent[i]! != i { i = parent[i]! }; return i }
        for (n, i) in elevators.enumerated() {
            for j in elevators[(n + 1)...] where !Set([links[i].a, links[i].b]).isDisjoint(with: [links[j].a, links[j].b]) {
                let (ri, rj) = (find(i), find(j)); if ri != rj { parent[max(ri, rj)] = min(ri, rj) }
            }
        }
        var groups = [Int: [Int]]()
        for i in elevators { groups[find(i), default: []].append(i) }
        var assigned = 0
        for root in groups.keys.sorted() {
            let members = groups[root]!.sorted()
            guard members.contains(where: { (result.links[$0].group_id ?? "").isEmpty }) else { continue }
            let id = members.lazy.compactMap { self.links[$0].group_id }.first { !$0.isEmpty } ?? result.nextElevatorGroupName()
            for m in members where (result.links[m].group_id ?? "").isEmpty { result.links[m].group_id = id; assigned += 1 }
        }
        return (result, assigned)
    }
    /// Links whose endpoints still exist with fitting kinds; others are ignored, never guessed.
    public func usable(maps: [String: LiDARNavigationMap]) -> [LiDARMapLink] {
        links.filter { $0.enabled && (try? Self.check($0, maps: maps)) != nil }
    }
    public static func load(root: URL) throws -> LiDARCampusLinks {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return LiDARCampusLinks() }
        let links = try JSONDecoder().decode(LiDARCampusLinks.self, from: Data(contentsOf: url)); try links.validate(); return links
    }
    public func save(root: URL) throws { try validate(); try LiDARNavigationArchive.write(self, to: root.appendingPathComponent(Self.fileName)) }
}

/// A route over several maps: one leg per map; each leg but the last ends at a link node.
public struct LiDARMultiMapRoute: Equatable {
    public struct Leg: Equatable {
        public var map_id: String
        /// Node the leg starts from (nil for the first leg: the camera position).
        public var entry_node_id: String?
        /// Exit link node, or the destination node on the last leg.
        public var target_node_id: String
        public var length_m: Double
        /// The link taken after this leg; nil on the last leg.
        public var link: LiDARMapLink?
    }
    public var legs: [Leg]
    public var total_m: Double
    public var destination: LiDARNodeRef { LiDARNodeRef(map: legs.last!.map_id, node: legs.last!.target_node_id) }
}

/// Ties the outdoor campus map (OpenStreetMap building ids, real door coordinates) to the indoor
/// library (catalog building UUIDs, maps and their exit / elevator nodes). Stored at the library
/// root beside the catalog and links. Every binding has its own stable id; OSM ids and
/// coordinates are attributes, never keys. Storeys come from the catalog floors' `level`.
public struct LiDARCampusBindings: Codable, Equatable {
    public static let fileName = "campus-bindings.json"
    public struct GeoPoint: Codable, Equatable {
        public var lat: Double, lon: Double
        public init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
        public var valid: Bool { lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon) && !(lat == 0 && lon == 0) }
        /// Metres between two points (equirectangular; campus distances).
        public func distance(to o: GeoPoint) -> Double {
            let k = Double.pi / 180, x = (o.lon - lon) * k * cos((lat + o.lat) / 2 * k), y = (o.lat - lat) * k
            return 6_371_000 * hypot(x, y)
        }
    }
    /// One catalog building ↔ one outdoor (OpenStreetMap) building.
    public struct Building: Codable, Equatable {
        public var id: String, building_id: String, osm_id: String
        public init(buildingID: String, osmID: String, id: String = UUID().uuidString) { self.id = id; building_id = buildingID; osm_id = osmID }
    }
    /// The outdoor map's door this entrance corresponds to: its building and position at binding time
    /// (door list indices change when the campus data is regenerated, so they are not stored).
    public struct CampusDoor: Codable, Equatable {
        public var osm_id: String, position: GeoPoint
        public init(osmID: String, position: GeoPoint) { osm_id = osmID; self.position = position }
    }
    /// A real building entrance: the map's exit node and where the door is outside.
    public struct Entrance: Codable, Equatable {
        public enum Source: String, Codable { case gps, campus_door, manual }
        public var id: String
        public var building_id: String
        public var node: LiDARNodeRef
        /// The door outside; nil until recorded.
        public var position: GeoPoint?
        public var accuracy_m: Double?
        public var source: Source?
        public var campus_door: CampusDoor?
        /// Confirmed on site by a person (not just recorded).
        public var verified = false
        /// A walking path drawn from the door (first point) to a point on the campus path network
        /// (last point); routing follows it instead of guessing a connector.
        public var access_path: [GeoPoint]?
        public var updated_utc: String
        public init(buildingID: String, node: LiDARNodeRef, id: String = UUID().uuidString) {
            self.id = id; building_id = buildingID; self.node = node; updated_utc = ISO8601DateFormatter().string(from: Date())
        }
    }
    /// A destination with a stable id across map edits: a name and the entrance nodes that reach it.
    public struct Destination: Codable, Equatable {
        public var id: String, building_id: String, name: String, nodes: [LiDARNodeRef]
        public init(buildingID: String, name: String, nodes: [LiDARNodeRef], id: String = UUID().uuidString) {
            self.id = id; building_id = buildingID; self.name = name; self.nodes = nodes
        }
    }
    /// A hall call device at one elevator (link group) on one floor. Without it, no automatic call.
    public struct ElevatorDevice: Codable, Equatable {
        public enum Direction: String, Codable { case up, down }
        public var id: String, group_id: String, building_id: String, floor_id: String
        /// Advertised name of the board (e.g. "ELEV-2F"); the phone-local peripheral id is not shared.
        public var peripheral_name: String
        public var directions: [Direction]
        public init(groupID: String, buildingID: String, floorID: String, peripheralName: String, directions: [Direction], id: String = UUID().uuidString) {
            self.id = id; group_id = groupID; building_id = buildingID; floor_id = floorID; peripheral_name = peripheralName; self.directions = directions
        }
    }
    public var schema_version = 1
    public var buildings: [Building] = []
    public var entrances: [Entrance] = []
    public var destinations: [Destination] = []
    public var elevator_devices: [ElevatorDevice] = []
    public init() {}

    /// Structural checks; references to the catalog and maps are reported by `problems`.
    public func validate() throws {
        func unique<T: Hashable>(_ xs: [T]) -> Bool { Set(xs).count == xs.count }
        guard schema_version == 1 else { throw LiDARScanError.invalid("出入口绑定版本不受支持") }
        guard unique(buildings.map(\.id)), unique(buildings.map(\.building_id)), unique(buildings.map(\.osm_id)),
              buildings.allSatisfy({ !$0.osm_id.trimmingCharacters(in: .whitespaces).isEmpty }) else { throw LiDARScanError.invalid("楼栋绑定重复或为空") }
        guard unique(entrances.map(\.id)), unique(entrances.map(\.node)) else { throw LiDARScanError.invalid("出入口绑定重复") }
        for e in entrances {
            guard e.position?.valid ?? true, e.campus_door?.position.valid ?? true, e.accuracy_m.map({ $0.isFinite && $0 >= 0 && $0 < 1000 }) ?? true,
                  ISO8601DateFormatter().date(from: e.updated_utc) != nil else { throw LiDARScanError.invalid("出入口坐标无效") }
            if let path = e.access_path {
                let length = zip(path, path.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
                guard (2...30).contains(path.count), path.allSatisfy(\.valid), length <= 300 else { throw LiDARScanError.invalid("门的引路无效（2–30 个点，总长不超过 300 米）") }
            }
        }
        guard unique(destinations.map(\.id)) else { throw LiDARScanError.invalid("目的地编号重复") }
        for d in destinations {
            _ = try LiDARCampusCatalog.cleanName(d.name)
            guard !d.nodes.isEmpty, unique(d.nodes) else { throw LiDARScanError.invalid("目的地「\(d.name)」没有有效入口") }
        }
        guard unique(elevator_devices.map(\.id)), unique(elevator_devices.map { [$0.group_id, $0.floor_id] }) else { throw LiDARScanError.invalid("呼梯装置绑定重复") }
        for d in elevator_devices {
            guard !d.group_id.isEmpty, !d.peripheral_name.trimmingCharacters(in: .whitespaces).isEmpty, !d.directions.isEmpty, unique(d.directions) else {
                throw LiDARScanError.invalid("呼梯装置「\(d.peripheral_name)」信息不完整")
            }
        }
    }
    /// What does not resolve against the catalog, maps and links (shown to the person; such bindings
    /// are not used). `maps` are the loaded maps with their placements.
    public func problems(catalog: LiDARCampusCatalog, maps: [String: (map: LiDARNavigationMap, placement: LiDARMapPlacement?)],
                         links: [LiDARMapLink]) -> [String] {
        var out = [String]()
        func name(_ id: String) -> String { catalog.building(id)?.name ?? "未知楼栋" }
        for b in buildings where catalog.building(b.building_id) == nil { out.append("楼栋绑定 \(b.osm_id)：室内楼栋已不存在") }
        for e in entrances {
            guard let m = maps[e.node.map_id] else { out.append("「\(name(e.building_id))」出入口：地图不存在"); continue }
            guard let node = m.map.nodes.first(where: { $0.id == e.node.node_id }) else { out.append("「\(name(e.building_id))」出入口：节点已删除"); continue }
            if node.resolvedKind != .exit { out.append("「\(node.name)」不是大楼出入口节点") }
            if m.placement?.building_id != e.building_id { out.append("「\(node.name)」所在地图不属于「\(name(e.building_id))」") }
            if e.position == nil { out.append("「\(node.name)」还没有记录室外坐标") }
        }
        for d in destinations {
            for n in d.nodes where maps[n.map_id]?.map.nodes.contains(where: { $0.id == n.node_id }) != true { out.append("目的地「\(d.name)」有入口已不存在") }
        }
        for d in elevator_devices {
            guard let b = catalog.building(d.building_id), let f = b.floors.first(where: { $0.id == d.floor_id }) else { out.append("呼梯装置「\(d.peripheral_name)」：楼层不存在"); continue }
            if f.level == nil { out.append("「\(b.name)·\(f.name)」没有填楼层号，无法判断上/下行") }
            let onFloor = Set(maps.values.filter { $0.placement?.floor_id == d.floor_id }.map(\.map.map_id))
            if !links.contains(where: { $0.kind == .elevator && $0.group_id == d.group_id && (onFloor.contains($0.a.map_id) || onFloor.contains($0.b.map_id)) }) {
                out.append("呼梯装置「\(d.peripheral_name)」：该楼层没有编号为 \(d.group_id) 的电梯连接")
            }
        }
        return out
    }
    public func osmID(forBuilding id: String) -> String? { buildings.first { $0.building_id == id }?.osm_id }
    public func building(forOSM osm: String) -> String? { buildings.first { $0.osm_id == osm }?.building_id }
    public func entrance(at node: LiDARNodeRef) -> Entrance? { entrances.first { $0.node == node } }
    public func entrances(ofBuilding id: String) -> [Entrance] { entrances.filter { $0.building_id == id } }
    public func device(group: String, floor: String) -> ElevatorDevice? { elevator_devices.first { $0.group_id == group && $0.floor_id == floor } }

    /// One-to-one: an OSM building already bound elsewhere must be unbound first.
    public mutating func bindBuilding(_ buildingID: String, osmID raw: String) throws {
        let osm = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !osm.isEmpty else { throw LiDARScanError.invalid("室外楼栋编号不能为空") }
        if let other = buildings.first(where: { $0.osm_id == osm && $0.building_id != buildingID }) {
            throw LiDARScanError.invalid("该室外楼栋已绑定到另一栋楼（\(other.building_id.prefix(8))）")
        }
        if let i = buildings.firstIndex(where: { $0.building_id == buildingID }) { buildings[i].osm_id = osm }
        else { buildings.append(Building(buildingID: buildingID, osmID: osm)) }
    }
    /// Records (or replaces) where an exit node's door is outside; the entrance keeps its id.
    @discardableResult public mutating func setEntrance(_ node: LiDARNodeRef, building: String, position: GeoPoint, accuracy: Double?,
                                                       source: Entrance.Source, door: CampusDoor? = nil, verified: Bool = false) throws -> Entrance {
        guard position.valid else { throw LiDARScanError.invalid("坐标无效") }
        var e = entrance(at: node) ?? Entrance(buildingID: building, node: node)
        e.building_id = building; e.position = position; e.accuracy_m = accuracy; e.source = source; e.campus_door = door; e.verified = verified
        // A moved door keeps its access path, which now starts at the new position.
        if var path = e.access_path, !path.isEmpty { path[0] = position; e.access_path = path }
        e.updated_utc = ISO8601DateFormatter().string(from: Date())
        if let i = entrances.firstIndex(where: { $0.id == e.id }) { entrances[i] = e } else { entrances.append(e) }
        try validate(); return e
    }
    public mutating func removeEntrance(at node: LiDARNodeRef) { entrances.removeAll { $0.node == node } }
    /// Sets (or with nil removes) a door's access path; its first point is the door.
    public mutating func setAccessPath(_ node: LiDARNodeRef, _ path: [GeoPoint]?) throws {
        guard let i = entrances.firstIndex(where: { $0.node == node }), let door = entrances[i].position else { throw LiDARScanError.invalid("请先记录这扇门的位置") }
        if var p = path { if p.first != door { p.insert(door, at: 0) }; entrances[i].access_path = p } else { entrances[i].access_path = nil }
        entrances[i].updated_utc = ISO8601DateFormatter().string(from: Date())
        try validate()
    }

    public static func load(root: URL) throws -> LiDARCampusBindings {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return LiDARCampusBindings() }
        let b = try JSONDecoder().decode(LiDARCampusBindings.self, from: Data(contentsOf: url)); try b.validate(); return b
    }
    public func save(root: URL) throws { try validate(); try LiDARNavigationArchive.write(self, to: root.appendingPathComponent(Self.fileName)) }
}

/// The last trusted indoor position per map on this phone, for "start from where I last was".
/// Only formally decided alignments are recorded (never a provisional quick correction). An entry
/// is offered only while the map's geometry is unchanged, and it is a search prior, not a pose.
public struct LiDARIndoorResume: Codable, Equatable {
    public static let fileName = "indoor-resume.json"
    public struct Entry: Codable, Equatable {
        public enum Reason: String, Codable { case confirmed, corrected, walking, arrived, exited, transfer }
        public var map_id: String, geometry_sha256: String
        public var position: ProbePoint
        public var saved_utc: String
        public var reason: Reason
        public init(mapID: String, geometrySHA256: String, position: ProbePoint, reason: Reason, at date: Date = Date()) {
            map_id = mapID; geometry_sha256 = geometrySHA256; self.position = position; self.reason = reason
            saved_utc = ISO8601DateFormatter().string(from: date)
        }
        public var savedDate: Date? { ISO8601DateFormatter().date(from: saved_utc) }
    }
    public var schema_version = 1
    public var entries: [Entry] = []
    public init() {}
    public mutating func record(_ e: Entry) {
        guard e.position.x.isFinite, e.position.y.isFinite, e.position.z.isFinite, !e.geometry_sha256.isEmpty else { return }
        entries.removeAll { $0.map_id == e.map_id }; entries.append(e)
    }
    /// Left this map by elevator or stairs: the position now lives on the next floor's map.
    public mutating func transfer(from mapID: String, to e: Entry) {
        entries.removeAll { $0.map_id == mapID }; record(e)
    }
    public mutating func remove(mapID: String) { entries.removeAll { $0.map_id == mapID } }
    /// The entry for this map, only if it was recorded on the same geometry.
    public func entry(mapID: String, geometrySHA256: String) -> Entry? {
        entries.first { $0.map_id == mapID && $0.geometry_sha256 == geometrySHA256 }
    }
    public static func load(root: URL) -> LiDARIndoorResume {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
              let r = try? JSONDecoder().decode(LiDARIndoorResume.self, from: data), r.schema_version == 1 else { return LiDARIndoorResume() }
        return r
    }
    public func save(root: URL) throws { try LiDARNavigationArchive.write(self, to: root.appendingPathComponent(Self.fileName)) }
}

/// In-map walking lengths for cross-map planning, measured on each map's space grid (the same
/// planner, calibration and parameters navigation uses). A map without a grid has no in-map
/// edges; nothing falls back to straight lines or the hand-drawn network. Grids load lazily and
/// lengths are memoised, so one instance should live as long as its grids (use from one queue).
public final class LiDARSpaceDistances {
    private let measure: (String, ProbePoint, ProbePoint) -> (length: Double?, reason: String)
    private var memo = [String: Double?]()
    /// Why a leg was unusable, for "which entrance is not connected" messages.
    public private(set) var failures = [String]()
    /// `measure` returns a walking length, or nil plus the reason it is unreachable.
    public init(measure: @escaping (String, ProbePoint, ProbePoint) -> (length: Double?, reason: String)) { self.measure = measure }
    /// Grids load lazily on first use of a map (nil: that map has no walkable area).
    public convenience init(grids: [String: LiDARSpaceGrid]) { self.init(loadGrid: { grids[$0] }) }
    public convenience init(loadGrid: @escaping (String) -> LiDARSpaceGrid?) {
        var grids = [String: LiDARSpaceGrid?]()
        self.init { id, a, b in
            if grids[id] == nil { grids[id] = .some(loadGrid(id)) }
            guard let g = grids[id]! else { return (nil, "该地图没有可走区域") }
            let r = LiDARSpacePlanner.route(g, from: (a.x, a.z), to: (b.x, b.z))
            return (r.length_m, r.reason)
        }
    }
    public func length(_ mapID: String, from a: ProbePoint, to b: ProbePoint, label: String = "") -> Double? {
        let key = String(format: "%@|%.2f,%.2f|%.2f,%.2f", mapID, a.x, a.z, b.x, b.z)
        if let hit = memo[key] { return hit }
        let r = measure(mapID, a, b)
        if r.length == nil, !label.isEmpty { failures.append("\(label)：\(r.reason)") }
        memo[key] = .some(r.length); return r.length
    }
}

public enum LiDARMultiMapPlanner {
    /// Dijkstra over link endpoints and destinations. Within a map, costs are space-route lengths
    /// (an unreachable pair is no edge); across maps, the links' manual costs. The start is the
    /// camera position in the start map. Throws when no destination is reachable.
    public static func plan(maps: [String: LiDARNavigationMap], links: [LiDARMapLink], startMap: String, start: ProbePoint,
                            destinations: [LiDARNodeRef], distances: LiDARSpaceDistances) throws -> LiDARMultiMapRoute {
        guard maps[startMap] != nil else { throw LiDARScanError.invalid("起始地图不存在") }
        let usable = LiDARCampusLinks(links: links).usable(maps: maps)
        let goals = Set(destinations.filter { d in maps[d.map_id]?.nodes.contains { $0.id == d.node_id } == true })
        guard !goals.isEmpty else { throw LiDARScanError.invalid("目的地不在已加载的地图中") }
        // Vertices: link endpoints and goals, per map.
        var vertices = Set(goals)
        for l in usable { vertices.insert(l.a); vertices.insert(l.b) }
        func node(_ v: LiDARNodeRef) -> LiDARRouteNode? { maps[v.map_id]?.nodes.first { $0.id == v.node_id } }
        func nodeLength(_ u: LiDARNodeRef, _ v: LiDARNodeRef) -> Double? {
            guard let a = node(u), let b = node(v) else { return nil }
            return distances.length(u.map_id, from: a.position, to: b.position, label: "「\(a.name)」→「\(b.name)」")
        }
        var dist = [LiDARNodeRef: Double](), previous = [LiDARNodeRef: (from: LiDARNodeRef?, link: LiDARMapLink?)]()
        for v in vertices where v.map_id == startMap {
            if let n = node(v), let d = distances.length(startMap, from: start, to: n.position, label: "当前位置→「\(n.name)」") { dist[v] = d; previous[v] = (nil, nil) }
        }
        var done = Set<LiDARNodeRef>()
        while let u = dist.filter({ !done.contains($0.key) }).min(by: { $0.value < $1.value })?.key {
            done.insert(u)
            if goals.contains(u) { break }
            let du = dist[u]!
            func relax(_ v: LiDARNodeRef, _ cost: Double, _ link: LiDARMapLink?) {
                if du + cost < dist[v] ?? .infinity { dist[v] = du + cost; previous[v] = (u, link) }
            }
            // Along links leaving u.
            for l in usable {
                if l.a == u { relax(l.b, l.cost_m, l) }
                if l.b == u && l.bidirectional { relax(l.a, l.cost_m, l) }
            }
            // Within u's map, to the other vertices of that map.
            for v in vertices where v.map_id == u.map_id && v != u && !done.contains(v) {
                if let c = nodeLength(u, v) { relax(v, c, nil) }
            }
        }
        guard let goal = goals.filter({ dist[$0] != nil && done.contains($0) }).min(by: { dist[$0]! < dist[$1]! }) else { throw CampusError.noRoute }
        // Walk back: consecutive vertices in one map form a leg; a link separates legs.
        var chain = [(ref: LiDARNodeRef, link: LiDARMapLink?)](), cur: LiDARNodeRef? = goal
        while let c = cur, let p = previous[c] { chain.insert((c, p.link), at: 0); cur = p.from }
        var legs = [LiDARMultiMapRoute.Leg](), entry: String? = nil, legStart = 0.0
        for (i, step) in chain.enumerated() {
            let nextLink = i + 1 < chain.count ? chain[i + 1].link : nil
            if nextLink != nil || i == chain.count - 1 {
                let length = dist[step.ref]! - legStart
                legs.append(.init(map_id: step.ref.map_id, entry_node_id: entry, target_node_id: step.ref.node_id, length_m: max(0, length), link: nextLink))
                if let nextLink { entry = chain[i + 1].ref.node_id; legStart = dist[chain[i + 1].ref]! - 0; _ = nextLink }
            }
        }
        return LiDARMultiMapRoute(legs: legs, total_m: dist[goal]!)
    }
}

extension LiDARNavigationArchive {
    /// Edits a saved map's route (e.g. a node's kind) without new capture: the edited map is
    /// staged and published through LiDARMapVersions, so the previous route stays restorable.
    public static func updateRoute(_ directory: URL, _ edit: (inout LiDARRouteEditor) throws -> Void) throws {
        let (map, points) = try load(directory)
        var editor = LiDARRouteEditor(nodes: map.nodes, edges: map.edges)
        try edit(&editor)
        var next = editor.map(mapID: map.map_id, sessionID: map.session_id, name: map.name, pointCount: points.count, voxel: map.voxel_m)
        next.created_utc = map.created_utc; next.sources = map.sources; next.routing_mode = map.routing_mode
        try next.validate()
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("route-edit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory.appendingPathComponent(map.points_file), to: stage.appendingPathComponent(map.points_file))
        try write(next, to: stage.appendingPathComponent("navigation.json"))
        try LiDARMapVersions.publish(directory, staged: stage)
    }
}

// MARK: - Space routing (experiment/space-routing; see Docs/空间路网接口.md)

/// Map-frame raster: column i along X, row j along Z; cell (i,j) covers
/// [origin_x + i·cell, +cell) × [origin_z + j·cell, +cell).
public struct LiDARGridSpec: Codable, Equatable {
    public var origin_x: Double, origin_z: Double, cell_m: Double
    public var width: Int, height: Int
    public static let maxCells = 4_000_000
    public init(origin_x: Double, origin_z: Double, cell_m: Double = 0.1, width: Int, height: Int) {
        self.origin_x = origin_x; self.origin_z = origin_z; self.cell_m = cell_m; self.width = width; self.height = height
    }
    public func validate() throws {
        guard origin_x.isFinite, origin_z.isFinite, abs(origin_x) < 1000, abs(origin_z) < 1000, cell_m > 0, cell_m <= 1,
              (1...4000).contains(width), (1...4000).contains(height), width * height <= Self.maxCells else {
            throw LiDARScanError.invalid("栅格尺寸或原点无效")
        }
    }
    public var count: Int { width * height }
    public func cell(_ x: Double, _ z: Double) -> (i: Int, j: Int)? {
        let i = Int(floor((x - origin_x) / cell_m)), j = Int(floor((z - origin_z) / cell_m))
        return i >= 0 && i < width && j >= 0 && j < height ? (i, j) : nil
    }
    public func center(_ i: Int, _ j: Int) -> (x: Double, z: Double) { (origin_x + (Double(i) + 0.5) * cell_m, origin_z + (Double(j) + 0.5) * cell_m) }
}

/// Binary layer run-length code: per row, alternating run lengths starting with 0-runs, each an
/// unsigned LEB128 varint; rows concatenated, then standard Base64.
public enum LiDARRLE {
    public static func encode(_ bits: [Bool], width: Int, height: Int) -> String {
        var bytes = [UInt8]()
        func varint(_ v: Int) { var v = v; repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; bytes.append(b) } while v > 0 }
        for j in 0..<height {
            var value = false, run = 0
            for i in 0..<width {
                if bits[j * width + i] == value { run += 1 } else { varint(run); value.toggle(); run = 1 }
            }
            varint(run)
        }
        return Data(bytes).base64EncodedString()
    }
    public static func decode(_ text: String, width: Int, height: Int) throws -> [Bool] {
        guard width > 0, height > 0, width * height <= LiDARGridSpec.maxCells, text.count <= 22_400_000,
              let data = Data(base64Encoded: text), data.count <= 16_777_216 else { throw LiDARScanError.invalid("通行栅格编码无效") }
        let bytes = [UInt8](data)
        var out = [Bool](), p = 0
        out.reserveCapacity(width * height)
        func varint() throws -> Int {
            var v = 0, shift = 0
            while true {
                guard p < bytes.count, shift <= 28 else { throw LiDARScanError.invalid("通行栅格编码截断") }
                let b = bytes[p]; p += 1; v |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return v }; shift += 7
            }
        }
        for _ in 0..<height {
            var sum = 0, value = false, first = true
            while sum < width {
                let run = try varint()
                guard run > 0 || first, sum + run <= width else { throw LiDARScanError.invalid("通行栅格游程无效") }
                out.append(contentsOf: repeatElement(value, count: run)); sum += run; value.toggle(); first = false
            }
        }
        guard p == bytes.count else { throw LiDARScanError.invalid("通行栅格编码有多余数据") }
        return out
    }
}

public struct LiDARSuggestedPath: Codable, Equatable {
    public var id: String
    /// [[x, z], …] in map coordinates.
    public var points: [[Double]]
    /// Total width; cells within width/2 are forced walkable (user authorization).
    public var width_m: Double
    /// workbench | phone
    public var source: String
    public var created_utc: String
    public init(points: [[Double]], width: Double = 0.6, source: String, id: String = UUID().uuidString) {
        self.id = id; self.points = points; width_m = width; self.source = source; created_utc = ISO8601DateFormatter().string(from: Date())
    }
    var valid: Bool {
        !id.isEmpty && points.count >= 2 && points.count <= 2_000 && points.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) < 1000 } })
            && (0.3...2.0).contains(width_m) && ["workbench", "phone"].contains(source)
    }
}

/// Per-map passage calibration. walkable == nil: no manual raster (auto everywhere). Otherwise
/// every cell inside the rectangle, white included, is final; outside it auto applies, "uncalibrated".
public struct LiDARPassageCalibration: Codable, Equatable {
    public static let fileName = "passage-calibration.json"
    public struct Walkable: Codable, Equatable {
        public var origin_x: Double, origin_z: Double, cell_m: Double, width: Int, height: Int, rle: String
        public var spec: LiDARGridSpec { LiDARGridSpec(origin_x: origin_x, origin_z: origin_z, cell_m: cell_m, width: width, height: height) }
    }
    public var schema_version = 1
    public var kind = "lidar_passage_calibration"
    public var map_id: String
    public var base_geometry_sha256: String?
    public var updated_utc: String
    /// workbench | phone
    public var editor: String
    public var walkable: Walkable?
    public var suggested_paths: [LiDARSuggestedPath]
    public var auto_params: [String: Double]?
    public init(mapID: String, geometrySHA256: String?, editor: String, walkable: Walkable? = nil, paths: [LiDARSuggestedPath] = []) {
        map_id = mapID; base_geometry_sha256 = geometrySHA256; updated_utc = ISO8601DateFormatter().string(from: Date())
        self.editor = editor; self.walkable = walkable; suggested_paths = paths
    }
    /// map_id must match; a different geometry hash is only a warning (supplements keep the frame).
    public func validate(mapID: String) throws {
        guard schema_version == 1, kind == "lidar_passage_calibration", map_id == mapID else { throw LiDARScanError.invalid("通行空间校准文件不属于这张地图") }
        guard ["workbench", "phone"].contains(editor), suggested_paths.count <= 500, Set(suggested_paths.map(\.id)).count == suggested_paths.count,
              suggested_paths.allSatisfy(\.valid) else { throw LiDARScanError.invalid("建议通行路径无效") }
        if let w = walkable { try w.spec.validate(); _ = try LiDARRLE.decode(w.rle, width: w.width, height: w.height) }
    }
    public static func load(_ directory: URL, mapID: String) throws -> LiDARPassageCalibration? {
        let url = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 32_000_000 else { throw LiDARScanError.invalid("通行空间校准文件过大") }
        let c = try JSONDecoder().decode(LiDARPassageCalibration.self, from: data); try c.validate(mapID: mapID); return c
    }
}

/// Where the mapper actually walked (accepted keyframe camera positions, map XZ, ~0.25 m apart).
public struct LiDARWalkedTrajectory: Codable, Equatable {
    public static let fileName = "walked-trajectory.json"
    public var schema_version = 1
    public var map_id: String
    /// One polyline per capture session, [[x, z], …].
    public var polylines: [[[Double]]]
    public init(mapID: String, polylines: [[[Double]]]) { map_id = mapID; self.polylines = polylines }
    /// From scan manifests: frame camera positions, moved by each scan's map_from_session when present.
    public static func from(mapID: String, scans: [LiDARScanManifest], spacing: Double = 0.25) -> LiDARWalkedTrajectory {
        let lines = scans.map { scan -> [[Double]] in
            var out = [[Double]]()
            for f in scan.frames {
                let pose = scan.map_from_session.map { CampusMapGeometry.multiply($0, f.camera_to_session) } ?? f.camera_to_session
                let p = [pose[0][3], pose[2][3]]
                if let last = out.last, hypot(p[0] - last[0], p[1] - last[1]) < spacing { continue }
                out.append(p)
            }
            return out
        }.filter { $0.count >= 2 }
        return LiDARWalkedTrajectory(mapID: mapID, polylines: lines)
    }
}

public struct LiDARSpaceParams: Codable, Equatable {
    public var cell_m = 0.1, floor_band_m = 0.15, obstacle_low_m = 0.2, obstacle_high_m = 1.8, obstacle_min_points = 3.0
    public var inflate_m = 0.2, hole_close_m = 0.3, walked_radius_m = 0.35
    // Routing
    public var target_max_m = 1.2, target_ratio = 0.85, halfwidth_window_m = 1.5, clearance_weight = 8.0, clearance_power = 1.5
    public var narrow_halfwidth_m = 1.0, path_cost = 0.35, path_detour_ratio = 1.2
    public var snap_distance_m = 0.8, snap_angle_deg = 25.0, snap_min_length_m = 1.2, endpoint_snap_m = 1.0
    public init() {}
    public var dictionary: [String: Double] {
        ["cell_m": cell_m, "floor_band_m": floor_band_m, "obstacle_low_m": obstacle_low_m, "obstacle_high_m": obstacle_high_m,
         "obstacle_min_points": obstacle_min_points, "inflate_m": inflate_m, "hole_close_m": hole_close_m, "walked_radius_m": walked_radius_m,
         "target_max_m": target_max_m, "target_ratio": target_ratio, "halfwidth_window_m": halfwidth_window_m, "clearance_weight": clearance_weight,
         "clearance_power": clearance_power, "narrow_halfwidth_m": narrow_halfwidth_m, "path_cost": path_cost, "path_detour_ratio": path_detour_ratio,
         "snap_distance_m": snap_distance_m, "snap_angle_deg": snap_angle_deg, "snap_min_length_m": snap_min_length_m, "endpoint_snap_m": endpoint_snap_m]
    }
}

/// Raster helpers: exact Euclidean distance transform (Felzenszwalb) and separable max filter.
enum LiDARRaster {
    /// Squared distance (in cells²) from every cell to the nearest `feature` cell.
    static func edt(_ feature: [Bool], _ w: Int, _ h: Int) -> [Float] {
        let inf: Float = 1e20, n = max(w, h)
        var g = [Float](repeating: 0, count: w * h), f = [Float](repeating: 0, count: n), d = f
        var v = [Int](repeating: 0, count: n), z = [Float](repeating: 0, count: n + 1)
        func pass(_ len: Int) {
            var k = 0; v[0] = 0; z[0] = -inf; z[1] = inf
            if len > 1 {
                for q in 1..<len {
                    var s = ((f[q] + Float(q * q)) - (f[v[k]] + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k])
                    while s <= z[k] { k -= 1; s = ((f[q] + Float(q * q)) - (f[v[k]] + Float(v[k] * v[k]))) / Float(2 * q - 2 * v[k]) }
                    k += 1; v[k] = q; z[k] = s; z[k + 1] = inf
                }
            }
            k = 0
            for q in 0..<len { while z[k + 1] < Float(q) { k += 1 }; d[q] = Float((q - v[k]) * (q - v[k])) + f[v[k]] }
        }
        for i in 0..<w { for j in 0..<h { f[j] = feature[j * w + i] ? 0 : inf }; pass(h); for j in 0..<h { g[j * w + i] = d[j] } }
        for j in 0..<h { for i in 0..<w { f[i] = g[j * w + i] }; pass(w); for i in 0..<w { g[j * w + i] = d[i] } }
        return g
    }
    /// Cells within `radius` cells of a feature.
    static func dilate(_ feature: [Bool], _ w: Int, _ h: Int, radius: Double) -> [Bool] {
        let r2 = Float(radius * radius); return edt(feature, w, h).map { $0 <= r2 }
    }
    static func maxFilter(_ a: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        func line(_ get: (Int) -> Float, _ n: Int) -> [Float] {
            var out = [Float](repeating: 0, count: n), dq = [Int](), head = 0
            for k in 0..<(n + r) {
                if k < n { while dq.count > head && get(dq[dq.count - 1]) <= get(k) { dq.removeLast() }; dq.append(k) }
                let c = k - r
                if c >= 0 { while dq[head] < c - r { head += 1 }; out[c] = get(dq[head]) }
            }
            return out
        }
        var tmp = [Float](repeating: 0, count: w * h), out = tmp
        for j in 0..<h { let row = line({ a[j * w + $0] }, w); for i in 0..<w { tmp[j * w + i] = row[i] } }
        for i in 0..<w { let col = line({ tmp[$0 * w + i] }, h); for j in 0..<h { out[j * w + i] = col[j] } }
        return out
    }
}

/// Walkable layers of one map. All layers are row-major [j * width + i].
/// Floor height per 2 m block. Large maps drift vertically (舞台东 全层: ~23 cm between ends), so a
/// single floorY misses whole regions. Each block takes the lowest well-supported horizontal level;
/// blocks without one borrow the nearest valid block within 6 m; outliers (> 0.3 m from the 3×3
/// neighbourhood median, e.g. a table top) are replaced by that median.
public struct LiDARFloorField: Codable, Equatable {
    public var origin_x: Double, origin_z: Double, block_m: Double, width: Int, height: Int
    public var values: [Double]
    public var global: Double
    public func floor(_ x: Double, _ z: Double) -> Double {
        let i = Int(Foundation.floor((x - origin_x) / block_m)), j = Int(Foundation.floor((z - origin_z) / block_m))
        guard i >= 0, j >= 0, i < width, j < height else { return global }
        return values[j * width + i]
    }
    public static func build(_ points: [ProbePoint], block: Double = 2, band: Double = 0.15, minSupport: Int = 30) -> LiDARFloorField {
        let global = LiDARSampling.floorHeight(LiDARSampling.sample(points, limit: 8_000))
        let minX = points.map(\.x).min() ?? 0, minZ = points.map(\.z).min() ?? 0
        let w = max(1, Int(ceil(((points.map(\.x).max() ?? 0) - minX) / block)) + 1), h = max(1, Int(ceil(((points.map(\.z).max() ?? 0) - minZ) / block)) + 1)
        var ys = [[Double]](repeating: [], count: w * h)
        for p in points { ys[Int((p.z - minZ) / block) * w + Int((p.x - minX) / block)].append(p.y) }
        var level = [Double?](repeating: nil, count: w * h)
        for q in 0..<(w * h) where ys[q].count >= minSupport {
            let sorted = ys[q].sorted()
            // Lowest level with horizontal support: walk up the low quantiles until enough points sit within the band.
            for frac in [0.02, 0.05, 0.1, 0.2] {
                let c = sorted[min(sorted.count - 1, Int(Double(sorted.count) * frac))]
                if sorted.filter({ abs($0 - c) <= band }).count >= minSupport { level[q] = c; break }
            }
        }
        // Outliers against the 3×3 neighbourhood median.
        var cleaned = level
        for j in 0..<h { for i in 0..<w {
            guard let v = level[j * w + i] else { continue }
            var n = [Double]()
            for dj in -1...1 { for di in -1...1 where !(di == 0 && dj == 0) {
                let a = i + di, b = j + dj
                if a >= 0, b >= 0, a < w, b < h, let u = level[b * w + a] { n.append(u) }
            } }
            if n.count >= 3 { let m = n.sorted()[n.count / 2]; if abs(v - m) > 0.3 { cleaned[j * w + i] = m } }
        } }
        // Fill gaps from the nearest valid block within 6 m.
        let reach = Int(ceil(6 / block))
        var values = [Double](repeating: global, count: w * h)
        for j in 0..<h { for i in 0..<w {
            if let v = cleaned[j * w + i] { values[j * w + i] = v; continue }
            var best: (Double, Int)?
            for b in max(0, j - reach)...min(h - 1, j + reach) { for a in max(0, i - reach)...min(w - 1, i + reach) {
                if let u = cleaned[b * w + a] { let d = (a - i) * (a - i) + (b - j) * (b - j); if d < (best?.1 ?? .max) { best = (u, d) } }
            } }
            values[j * w + i] = best?.0 ?? global
        } }
        return LiDARFloorField(origin_x: minX, origin_z: minZ, block_m: block, width: w, height: h, values: values, global: global)
    }
}

public struct LiDARSpaceGrid {
    public var spec: LiDARGridSpec
    public var floorY: Double
    /// Local floor heights; nil in grids written before it existed (then floorY applies everywhere).
    public var floorField: LiDARFloorField?
    public var params: LiDARSpaceParams
    public var observedFloor, walked, holeFilled, obstacle, auto, base, forced, effective: [Bool]
    public var calibratedRect: LiDARGridSpec?
    public var paths: [LiDARSuggestedPath]
    public static func build(points: [ProbePoint], params k: LiDARSpaceParams = LiDARSpaceParams(), trajectory: LiDARWalkedTrajectory? = nil,
                             calibration: LiDARPassageCalibration? = nil) throws -> LiDARSpaceGrid {
        let pts = points.filter { $0.array.allSatisfy { $0.isFinite && abs($0) < 1000 } }
        guard pts.count >= 100 else { throw LiDARScanError.invalid("点云不足，无法生成通行空间") }
        var xs = pts.map(\.x), zs = pts.map(\.z)
        for p in calibration?.suggested_paths ?? [] { xs += p.points.map { $0[0] }; zs += p.points.map { $0[1] } }
        if let w = calibration?.walkable { xs += [w.origin_x, w.origin_x + Double(w.width) * w.cell_m]; zs += [w.origin_z, w.origin_z + Double(w.height) * w.cell_m] }
        let c = k.cell_m, ox = floor(((xs.min() ?? 0) - 1) / c) * c, oz = floor(((zs.min() ?? 0) - 1) / c) * c
        let spec = LiDARGridSpec(origin_x: ox, origin_z: oz, cell_m: c, width: Int(ceil(((xs.max() ?? 0) + 1 - ox) / c)), height: Int(ceil(((zs.max() ?? 0) + 1 - oz) / c)))
        try spec.validate()
        let w = spec.width, h = spec.height, n = spec.count
        let field = LiDARFloorField.build(pts)
        let floorY = field.global
        var observed = [Bool](repeating: false, count: n), counts = [Int](repeating: 0, count: n)
        for p in pts {
            guard let cell = spec.cell(p.x, p.z) else { continue }
            let dy = p.y - field.floor(p.x, p.z), idx = cell.j * w + cell.i
            if abs(dy) <= k.floor_band_m { observed[idx] = true }
            if dy >= k.obstacle_low_m && dy <= k.obstacle_high_m { counts[idx] += 1 }
        }
        let obstacle = counts.map { Double($0) >= k.obstacle_min_points }
        let blocked = LiDARRaster.dilate(obstacle, w, h, radius: k.inflate_m / c)
        // Small holes only: closing of the observed floor.
        let r = k.hole_close_m / c
        let dil = LiDARRaster.dilate(observed, w, h, radius: r)
        let closed = LiDARRaster.edt(dil.map { !$0 }, w, h).map { $0 > Float(r * r) }
        let holeFilled = (0..<n).map { closed[$0] && !observed[$0] }
        var walkedMask = [Bool](repeating: false, count: n)
        for line in trajectory?.polylines ?? [] {
            for s in 0..<(line.count - 1) {
                let a = line[s], b = line[s + 1], steps = max(1, Int(hypot(b[0] - a[0], b[1] - a[1]) / (c / 2)))
                for t in 0...steps {
                    let f = Double(t) / Double(steps)
                    if let cell = spec.cell(a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f) { walkedMask[cell.j * w + cell.i] = true }
                }
            }
        }
        let walked = LiDARRaster.dilate(walkedMask, w, h, radius: k.walked_radius_m / c)
        let auto = (0..<n).map { (observed[$0] || holeFilled[$0] || walked[$0]) && !blocked[$0] }
        var base = auto
        var rect: LiDARGridSpec?
        if let cal = calibration?.walkable {
            let s = cal.spec, bits = try LiDARRLE.decode(cal.rle, width: s.width, height: s.height)
            rect = s
            for j in 0..<h { for i in 0..<w {
                let (x, z) = spec.center(i, j)
                if let cc = s.cell(x, z) { base[j * w + i] = bits[cc.j * s.width + cc.i] }
            } }
        }
        let paths = calibration?.suggested_paths ?? []
        var forced = [Bool](repeating: false, count: n)
        for p in paths {
            let half = p.width_m / 2
            for s in 0..<(p.points.count - 1) {
                let a = p.points[s], b = p.points[s + 1]
                func clampI(_ x: Double) -> Int { max(0, min(w - 1, Int(floor((x - ox) / c)))) }
                func clampJ(_ z: Double) -> Int { max(0, min(h - 1, Int(floor((z - oz) / c)))) }
                for j in clampJ(min(a[1], b[1]) - half)...clampJ(max(a[1], b[1]) + half) { for i in clampI(min(a[0], b[0]) - half)...clampI(max(a[0], b[0]) + half) {
                    let (x, z) = spec.center(i, j)
                    if LiDARSpacePlanner.segmentDistance(x, z, a, b) <= half { forced[j * w + i] = true }
                } }
            }
        }
        let effective = (0..<n).map { base[$0] || forced[$0] }
        return LiDARSpaceGrid(spec: spec, floorY: floorY, floorField: field, params: k, observedFloor: observed, walked: walked, holeFilled: holeFilled, obstacle: obstacle,
                              auto: auto, base: base, forced: forced, effective: effective, calibratedRect: rect, paths: paths)
    }
}

public struct LiDARSpaceRoute: Codable, Equatable {
    public struct Snap: Codable, Equatable { public var x: Double, z: Double, distance_m: Double }
    public var status: String
    public var reason: String
    public var length_m: Double?
    public var points: [[Double]]
    public var variant: String?
    public var lengths: [String: Double]
    public var start_snap: Snap?, end_snap: Snap?
    public var used_paths: [String]
    public var algorithm = "space_route_v1"
    public var params: [String: Double]
}

public enum LiDARSpacePlanner {
    static func segmentDistance(_ x: Double, _ z: Double, _ a: [Double], _ b: [Double]) -> Double {
        let dx = b[0] - a[0], dz = b[1] - a[1], l2 = dx * dx + dz * dz
        let t = l2 > 0 ? max(0, min(1, ((x - a[0]) * dx + (z - a[1]) * dz) / l2)) : 0
        return hypot(x - (a[0] + dx * t), z - (a[1] + dz * t))
    }
    /// Per-cell fields shared by both route variants.
    struct Fields { var dist: [Float]; var target: [Float]; var cost: [Float]; var narrow: [Bool]; var onPath: [Bool] }
    static func fields(_ g: LiDARSpaceGrid) -> Fields {
        let w = g.spec.width, h = g.spec.height, c = Float(g.spec.cell_m), k = g.params
        let dist = LiDARRaster.edt(g.effective.map { !$0 }, w, h).map { $0.squareRoot() * c }
        let half = LiDARRaster.maxFilter(dist, w, h, radius: Int(k.halfwidth_window_m / g.spec.cell_m))
        var target = [Float](repeating: 0, count: w * h), cost = target, narrow = [Bool](repeating: false, count: w * h)
        for q in 0..<(w * h) {
            target[q] = min(Float(k.target_max_m), Float(k.target_ratio) * half[q])
            let short = target[q] > 0 ? max(0, min(1, (target[q] - dist[q]) / target[q])) : 0
            cost[q] = 1 + Float(k.clearance_weight) * powf(short, Float(k.clearance_power))
            narrow[q] = Double(half[q]) < k.narrow_halfwidth_m
        }
        return Fields(dist: dist, target: target, cost: cost, narrow: narrow, onPath: g.forced)
    }
    static func astar(_ g: LiDARSpaceGrid, _ cost: [Float], _ s: Int, _ t: Int) -> [Int]? {
        let w = g.spec.width, n = g.spec.count
        let minCost = cost.enumerated().filter { g.effective[$0.offset] }.map(\.element).min() ?? 1
        var gs = [Float](repeating: .infinity, count: n), came = [Int32](repeating: -1, count: n), closed = [Bool](repeating: false, count: n)
        var heap = [(Float, Int)]()
        func push(_ e: (Float, Int)) { heap.append(e); var i = heap.count - 1; while i > 0 { let p = (i - 1) / 2; if heap[p].0 <= heap[i].0 { break }; heap.swapAt(p, i); i = p } }
        func pop() -> (Float, Int) {
            let top = heap[0]; heap[0] = heap[heap.count - 1]; heap.removeLast(); var i = 0
            while true { let l = 2 * i + 1, r = l + 1; var m = i
                if l < heap.count && heap[l].0 < heap[m].0 { m = l }; if r < heap.count && heap[r].0 < heap[m].0 { m = r }
                if m == i { break }; heap.swapAt(i, m); i = m }
            return top
        }
        let tx = t % w, tz = t / w
        func hcost(_ q: Int) -> Float { let dx = Float(abs(q % w - tx)), dz = Float(abs(q / w - tz)); return (max(dx, dz) + 0.41421356 * min(dx, dz)) * minCost }
        gs[s] = 0; push((hcost(s), s))
        let moves = [(1, 0, Float(1)), (-1, 0, 1), (0, 1, 1), (0, -1, 1), (1, 1, 1.41421356), (1, -1, 1.41421356), (-1, 1, 1.41421356), (-1, -1, 1.41421356)]
        while !heap.isEmpty {
            let (_, u) = pop()
            if closed[u] { continue }; closed[u] = true
            if u == t { break }
            let ux = u % w, uz = u / w
            for (dx, dz, step) in moves {
                let vx = ux + dx, vz = uz + dz
                guard vx >= 0, vx < w, vz >= 0, vz < g.spec.height else { continue }
                let v = vz * w + vx
                guard g.effective[v], !closed[v] else { continue }
                // No corner cutting between two blocked neighbours.
                if dx != 0 && dz != 0 && (!g.effective[uz * w + vx] || !g.effective[vz * w + ux]) { continue }
                let ng = gs[u] + step * cost[v]
                if ng < gs[v] { gs[v] = ng; came[v] = Int32(u); push((ng + hcost(v), v)) }
            }
        }
        guard gs[t].isFinite else { return nil }
        var path = [t]
        while path.last! != s { path.append(Int(came[path.last!])) }
        return path.reversed()
    }
    /// Straight line between two map points stays on effective cells with at least `need` metres to the edge.
    static func clear(_ g: LiDARSpaceGrid, _ f: Fields, _ a: (Double, Double), _ b: (Double, Double), need: Float) -> Bool {
        let steps = max(1, Int(hypot(b.0 - a.0, b.1 - a.1) / (g.spec.cell_m / 2)))
        for t in 0...steps {
            let s = Double(t) / Double(steps)
            guard let cell = g.spec.cell(a.0 + (b.0 - a.0) * s, a.1 + (b.1 - a.1) * s) else { return false }
            let q = cell.j * g.spec.width + cell.i
            if !g.effective[q] || f.dist[q] < need { return false }
        }
        return true
    }
    /// String pulling that keeps the clearance the replaced stretch already had (capped at the target).
    static func pull(_ g: LiDARSpaceGrid, _ f: Fields, _ pts: [(Double, Double)], cells: [Int]) -> [(Double, Double)] {
        guard pts.count > 2 else { return pts }
        var out = [pts[0]], i = 0
        while i < pts.count - 1 {
            var best = i + 1, need = min(f.dist[cells[i]], f.target[cells[i]]), fails = 0, j = i + 1
            while j < pts.count {
                need = min(need, min(f.dist[cells[j]], f.target[cells[j]]))
                if clear(g, f, pts[i], pts[j], need: need - 0.05) { best = j; fails = 0 } else { fails += 1; if fails > 25 { break } }
                j += 1
            }
            out.append(pts[best]); i = best
        }
        return out
    }
    /// Stretches running along a suggested path (≤ snap distance, ≤ snap angle, ≥ min length) are
    /// replaced by the path's own projection, if the joins on and off it are walkable.
    enum Piece { case free(Range<Int>); case rail((Double, Double), (Double, Double), String) }
    static func snap(_ g: LiDARSpaceGrid, _ f: Fields, _ pts: [(Double, Double)]) -> [Piece] {
        guard !g.paths.isEmpty, pts.count > 2 else { return [.free(0..<pts.count)] }
        let k = g.params
        var segs = [(id: String, a: [Double], b: [Double])]()
        for p in g.paths { for s in 0..<(p.points.count - 1) { segs.append((p.id, p.points[s], p.points[s + 1])) } }
        var label = [Int?](repeating: nil, count: pts.count)
        for (i, p) in pts.enumerated() {
            let q = pts[min(i + 5, pts.count - 1)], r = pts[max(i - 5, 0)], heading = atan2(q.1 - r.1, q.0 - r.0)
            var best: (Int, Double)?
            for (si, s) in segs.enumerated() {
                let d = segmentDistance(p.0, p.1, s.a, s.b), sh = atan2(s.b[1] - s.a[1], s.b[0] - s.a[0])
                var ang = abs(heading - sh).truncatingRemainder(dividingBy: .pi); if ang > .pi / 2 { ang = .pi - ang }
                if d <= k.snap_distance_m && ang * 180 / .pi <= k.snap_angle_deg && d < (best?.1 ?? .infinity) { best = (si, d) }
            }
            label[i] = best?.0
        }
        func project(_ p: (Double, Double), _ s: (id: String, a: [Double], b: [Double])) -> (Double, Double) {
            let dx = s.b[0] - s.a[0], dz = s.b[1] - s.a[1], l2 = dx * dx + dz * dz
            let t = l2 > 0 ? max(0, min(1, ((p.0 - s.a[0]) * dx + (p.1 - s.a[1]) * dz) / l2)) : 0
            return (s.a[0] + dx * t, s.a[1] + dz * t)
        }
        var pieces = [Piece](), freeStart = 0, i = 0
        while i < pts.count {
            var j = i
            while j + 1 < pts.count && label[j + 1] == label[i] { j += 1 }
            if let si = label[i], hypot(pts[j].0 - pts[i].0, pts[j].1 - pts[i].1) >= k.snap_min_length_m {
                let a = project(pts[i], segs[si]), b = project(pts[j], segs[si])
                if clear(g, f, pts[i], a, need: 0), clear(g, f, b, pts[j], need: 0), clear(g, f, a, b, need: 0) {
                    if freeStart < i { pieces.append(.free(freeStart..<i)) }
                    pieces.append(.rail(a, b, segs[si].id)); freeStart = j + 1
                }
            }
            i = j + 1
        }
        if freeStart < pts.count { pieces.append(.free(freeStart..<pts.count)) }
        return pieces
    }
    static func simplify(_ p: [(Double, Double)]) -> [(Double, Double)] {
        guard p.count > 2 else { return p }
        var out = [p[0]]
        for i in 1..<(p.count - 1) {
            let a = out.last!, b = p[i], c = p[i + 1]
            let turn = abs(remainder(atan2(c.1 - b.1, c.0 - b.0) - atan2(b.1 - a.1, b.0 - a.0), 2 * .pi)) * 180 / .pi
            if turn >= 8 && hypot(b.0 - a.0, b.1 - a.1) >= 0.3 { out.append(b) }
        }
        out.append(p.last!); return out
    }
    static func length(_ p: [(Double, Double)]) -> Double { zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.0 - $1.0.0, $1.1.1 - $1.0.1) } }
    static func nearestWalkable(_ g: LiDARSpaceGrid, _ x: Double, _ z: Double) -> (Int, Double)? {
        let c = g.spec.cell_m, r = Int(ceil(g.params.endpoint_snap_m / c))
        let ci = Int(floor((x - g.spec.origin_x) / c)), cj = Int(floor((z - g.spec.origin_z) / c))
        var best: (Int, Double)?
        for j in (cj - r)...(cj + r) { for i in (ci - r)...(ci + r) where i >= 0 && j >= 0 && i < g.spec.width && j < g.spec.height {
            let q = j * g.spec.width + i
            guard g.effective[q] else { continue }
            let (cx, cz) = g.spec.center(i, j), d = hypot(cx - x, cz - z)
            if d <= g.params.endpoint_snap_m && d < (best?.1 ?? .infinity) { best = (q, d) }
        } }
        return best
    }
    /// Nearest walkable cell centre within `maxDistance` (for "you have left the mapped area":
    /// guidance back to it). Nil when none is that close.
    public static func nearestWalkable(_ g: LiDARSpaceGrid, x: Double, z: Double, maxDistance: Double) -> (x: Double, z: Double, distance: Double)? {
        let c = g.spec.cell_m, r = Int(ceil(maxDistance / c))
        let ci = Int(floor((x - g.spec.origin_x) / c)), cj = Int(floor((z - g.spec.origin_z) / c))
        let j0 = max(0, cj - r), j1 = min(g.spec.height - 1, cj + r), i0 = max(0, ci - r), i1 = min(g.spec.width - 1, ci + r)
        guard j0 <= j1, i0 <= i1 else { return nil }
        var best: (x: Double, z: Double, distance: Double)?
        for j in j0...j1 {
            for i in i0...i1 where g.effective[j * g.spec.width + i] {
                let (cx, cz) = g.spec.center(i, j), d = hypot(cx - x, cz - z)
                if d <= maxDistance && d < (best?.distance ?? .infinity) { best = (cx, cz, d) }
            }
        }
        return best
    }
    /// Route A uses every suggested path; route B only those in narrow places. A wins unless it is
    /// more than path_detour_ratio times longer than B (physical length, both on walkable cells).
    public static func route(_ g: LiDARSpaceGrid, from: (x: Double, z: Double), to: (x: Double, z: Double)) -> LiDARSpaceRoute {
        let params = g.params.dictionary
        func fail(_ reason: String) -> LiDARSpaceRoute {
            LiDARSpaceRoute(status: "unreachable", reason: reason, length_m: nil, points: [], variant: nil, lengths: [:], start_snap: nil, end_snap: nil, used_paths: [], params: params)
        }
        guard let s = nearestWalkable(g, from.x, from.z) else { return fail("起点不在可走区域（1 米内没有可走格）") }
        guard let t = nearestWalkable(g, to.x, to.z) else { return fail("终点不在可走区域（1 米内没有可走格）") }
        let f = fields(g), w = g.spec.width
        func variant(_ pathCost: (Int) -> Bool) -> (pts: [(Double, Double)], used: Set<String>, length: Double)? {
            var cost = f.cost
            for q in 0..<cost.count where f.onPath[q] && pathCost(q) { cost[q] = Float(g.params.path_cost) }
            guard let cells = astar(g, cost, s.0, t.0) else { return nil }
            let raw = cells.map { g.spec.center($0 % w, $0 / w) }.map { ($0.x, $0.z) }
            // Snapped pieces are used as drawn; each free stretch is pulled straight on its own.
            var out = [(Double, Double)](), used = Set<String>()
            for piece in snap(g, f, raw) {
                switch piece {
                case .rail(let a, let b, let id): out += [a, b]; used.insert(id)
                case .free(let r): out += pull(g, f, Array(raw[r]), cells: Array(cells[r]))
                }
            }
            let pts = simplify(out)
            return (pts, used, length(pts))
        }
        guard let free = variant({ f.narrow[$0] }) else { return fail("起点和终点之间没有连通的可走区域") }
        var chosen = free, name = "free", lengths = ["free": free.length]
        if !g.paths.isEmpty, let all = variant({ _ in true }) {
            lengths["with_paths"] = all.length
            if all.length <= g.params.path_detour_ratio * free.length { chosen = all; name = "with_paths" }
        }
        let sc = g.spec.center(s.0 % w, s.0 / w), ec = g.spec.center(t.0 % w, t.0 / w)
        return LiDARSpaceRoute(status: "ok", reason: "", length_m: chosen.length, points: chosen.pts.map { [$0.0, $0.1] }, variant: name, lengths: lengths,
                               start_snap: .init(x: sc.x, z: sc.z, distance_m: s.1), end_snap: .init(x: ec.x, z: ec.z, distance_m: t.1),
                               used_paths: chosen.used.sorted(), params: params)
    }
}

/// Cached grid for tools (space-route prepare/route) and the workbench; layers RLE-encoded.
public struct LiDARSpaceGridFile: Codable {
    public struct Grid: Codable { public var origin_x: Double, origin_z: Double, cell_m: Double, width: Int, height: Int, floor_y: Double }
    public var schema_version = 1
    public var algorithm = "space_grid_v1"
    public var map_id: String
    public var geometry_sha256: String?
    public var params: LiDARSpaceParams
    public var grid: Grid
    public var layers: [String: String]
    public var calibrated_rect: LiDARGridSpec?
    public var suggested_paths: [LiDARSuggestedPath]
    /// Local floor heights (2 m blocks); optional for older grid files.
    public var floor_field: LiDARFloorField?
    static let layerNames = ["observed_floor", "walked", "hole_filled", "obstacle", "auto", "base", "forced", "effective"]
    public init(_ g: LiDARSpaceGrid, mapID: String, geometrySHA256: String?) {
        map_id = mapID; geometry_sha256 = geometrySHA256; params = g.params
        grid = Grid(origin_x: g.spec.origin_x, origin_z: g.spec.origin_z, cell_m: g.spec.cell_m, width: g.spec.width, height: g.spec.height, floor_y: g.floorY)
        let bits = [g.observedFloor, g.walked, g.holeFilled, g.obstacle, g.auto, g.base, g.forced, g.effective]
        layers = Dictionary(uniqueKeysWithValues: zip(Self.layerNames, bits.map { LiDARRLE.encode($0, width: g.spec.width, height: g.spec.height) }))
        calibrated_rect = g.calibratedRect; suggested_paths = g.paths; floor_field = g.floorField
    }
    public func spaceGrid() throws -> LiDARSpaceGrid {
        let spec = LiDARGridSpec(origin_x: grid.origin_x, origin_z: grid.origin_z, cell_m: grid.cell_m, width: grid.width, height: grid.height)
        try spec.validate()
        func layer(_ name: String) throws -> [Bool] {
            guard let rle = layers[name] else { throw LiDARScanError.invalid("缺少栅格层 \(name)") }
            return try LiDARRLE.decode(rle, width: spec.width, height: spec.height)
        }
        return LiDARSpaceGrid(spec: spec, floorY: grid.floor_y, floorField: floor_field, params: params, observedFloor: try layer("observed_floor"), walked: try layer("walked"),
                              holeFilled: try layer("hole_filled"), obstacle: try layer("obstacle"), auto: try layer("auto"), base: try layer("base"),
                              forced: try layer("forced"), effective: try layer("effective"), calibratedRect: calibrated_rect, paths: suggested_paths)
    }
}


extension LiDARWalkedTrajectory {
    public func merged(with other: LiDARWalkedTrajectory) -> LiDARWalkedTrajectory { LiDARWalkedTrajectory(mapID: map_id, polylines: polylines + other.polylines) }
}

extension LiDARMapVersions {
    /// Replaces one sidecar (e.g. passage-calibration.json) through the versioned, transactional
    /// publish: the current route and geometry are staged unchanged next to the new file.
    @discardableResult public static func publishSidecar(_ dir: URL, name: String, data: Data) throws -> String {
        guard LiDARNavigationArchive.lightweightFiles.contains(name), !["navigation.json", "geometry.f32"].contains(name) else { throw LiDARScanError.invalid("不支持的附加文件") }
        let (map, _) = try LiDARNavigationArchive.load(dir)
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        for file in ["navigation.json", map.points_file] { try FileManager.default.copyItem(at: dir.appendingPathComponent(file), to: stage.appendingPathComponent(file)) }
        try data.write(to: stage.appendingPathComponent(name), options: .atomic)
        return try publish(dir, staged: stage)
    }
}
