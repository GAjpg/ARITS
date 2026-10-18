import Foundation

public enum CampusError: Error, LocalizedError {
    case invalid(String), noRoute, unsaved(String), conflict, corrupt, unsupportedZIP
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .noRoute: return "起点与终点之间没有可通行路线，请检查连接和楼梯配对。"
        case .unsaved(let name): return "区域「\(name)」尚未保存环境地图，请先完成采集。"
        case .conflict: return "数据已在其他操作中更新，请返回后重新打开。"
        case .corrupt: return "备份不完整或校验不符，未导入任何数据。"
        case .unsupportedZIP: return "请选择本工具导出的 ZIP 备份；此版本不支持加密或重新压缩的 ZIP。"
        }
    }
}

public enum CampusNodeKind: String, Codable, CaseIterable {
    /// elevator is kept apart from stair: elevator transitions get their own behaviour later.
    /// exit: a building entrance/exit, the hand-over point to outdoor maps later.
    case waypoint, junction, room, stair, elevator, exit
    public var title: String {
        switch self { case .waypoint: return "路点"; case .junction: return "岔路口"; case .room: return "教室 / 目的地"; case .stair: return "楼梯口"; case .elevator: return "电梯口"; case .exit: return "大楼出入口" }
    }
}
public struct CampusFloor: Codable, Equatable {
    public var id: String
    public var name: String
    public init(name: String, id: String = UUID().uuidString) { self.id = id; self.name = name }
}
public struct CampusRegion: Codable, Equatable {
    public var id: String
    public var floor_id: String
    public var name: String
    public var map_saved: Bool
    public var default_map_id: String?
    public init(floorID: String, name: String, id: String = UUID().uuidString) {
        self.id = id; floor_id = floorID; self.name = name; map_saved = false
    }
}
public struct CampusNode: Codable, Equatable {
    public var id: String
    public var floor_id: String
    public var name: String
    public var kind: CampusNodeKind
    public init(floorID: String, name: String, kind: CampusNodeKind, id: String = UUID().uuidString) {
        self.id = id; floor_id = floorID; self.name = name; self.kind = kind
    }
}
public struct CampusBinding: Codable, Equatable {
    public var region_id: String
    public var node_id: String
    public var anchor_id: String
    public var anchor_to_map: [[Double]]
    public init(regionID: String, nodeID: String, anchorID: String, transform: [[Double]]) {
        region_id = regionID; node_id = nodeID; anchor_id = anchorID; anchor_to_map = transform
    }
    public var position: [Double] { (0..<3).map { anchor_to_map[$0][3] } }
}
public struct CampusEdge: Codable, Equatable {
    public enum Kind: String, Codable { case walk, stairs }
    public var id: String
    public var from: String
    public var to: String
    public var kind: Kind
    public var region_id: String?
    public var length_m: Double?
    public var cost_m: Double
    public var bidirectional: Bool
    public var enabled: Bool
    public var measurement_source: String
    public init(from: String, to: String, regionID: String, length: Double) {
        id = UUID().uuidString; self.from = from; self.to = to; kind = .walk
        region_id = regionID; length_m = length; cost_m = length; bidirectional = true
        enabled = true; measurement_source = "ar_anchor_estimate"
    }
    public init(stairFrom: String, to: String, cost: Double = 8) {
        id = UUID().uuidString; from = stairFrom; self.to = to; kind = .stairs
        region_id = nil; length_m = nil; cost_m = cost; bidirectional = true
        enabled = true; measurement_source = "manual_transition_cost"
    }
}

public struct CampusGraph: Codable, Equatable {
    public var schema_version = 2
    public var building_id: String
    public var name: String
    public var revision = 0
    public var updated_utc: String
    public var floors: [CampusFloor] = []
    public var regions: [CampusRegion] = []
    public var nodes: [CampusNode] = []
    public var edges: [CampusEdge] = []
    public var bindings: [CampusBinding] = []
    public var rooms: [CampusRoom] = []
    public var map_candidates: [CampusMapCandidate] = []
    public init(name: String, id: String = UUID().uuidString) {
        building_id = id; self.name = name; updated_utc = ISO8601DateFormatter().string(from: Date())
    }
    private enum CodingKeys: String, CodingKey { case schema_version, building_id, name, revision, updated_utc, floors, regions, nodes, edges, bindings, rooms, map_candidates }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        schema_version = try c.decode(Int.self,forKey:.schema_version)
        building_id = try c.decode(String.self,forKey:.building_id); name = try c.decode(String.self,forKey:.name)
        revision = try c.decode(Int.self,forKey:.revision); updated_utc = try c.decode(String.self,forKey:.updated_utc)
        floors = try c.decode([CampusFloor].self,forKey:.floors); regions = try c.decode([CampusRegion].self,forKey:.regions)
        nodes = try c.decode([CampusNode].self,forKey:.nodes); edges = try c.decode([CampusEdge].self,forKey:.edges)
        bindings = try c.decode([CampusBinding].self,forKey:.bindings)
        rooms = try c.decodeIfPresent([CampusRoom].self,forKey:.rooms) ?? []
        map_candidates = try c.decodeIfPresent([CampusMapCandidate].self,forKey:.map_candidates) ?? []
    }
    public func nextWaypointName() -> String {
        let used = Set(nodes.map(\.name)); var i = 1
        while used.contains(String(format:"P%03d",i)) { i += 1 }
        return String(format:"P%03d",i)
    }
    public func room(_ id: String) -> CampusRoom? { rooms.first { $0.id == id } }
    public func roomFloor(_ room: CampusRoom) -> String? { edges.first { $0.id == room.edge_id }.flatMap { node($0.from)?.floor_id } }
    public func title(_ room: CampusRoom) -> String {
        let regionName = edges.first { $0.id == room.edge_id }?.region_id.flatMap { region($0)?.name }
        return "\(roomFloor(room).map { floorName($0) } ?? "未知楼层")"+(regionName.map { " · "+$0 } ?? "")+" · \(room.name)"
    }
    /// Keep all entrance records, but present a single room row per name and logical region.
    public var roomGroups:[[CampusRoom]] {
        let regions = Dictionary(uniqueKeysWithValues:edges.map { ($0.id,$0.region_id ?? $0.id) })
        var indexes:[String:Int] = [:],groups:[[CampusRoom]] = []
        for room in rooms {
            let key = (regions[room.edge_id] ?? room.edge_id)+":"+room.name.trimmingCharacters(in:.whitespacesAndNewlines)
            if let i = indexes[key] { groups[i].append(room) }
            else { indexes[key] = groups.count;groups.append([room]) }
        };return groups
    }
    public func sameNameRooms(_ id:String) -> [CampusRoom] { roomGroups.first { $0.contains { $0.id == id } } ?? [] }
    public var roomDestinations:[CampusDestination] { roomGroups.compactMap { $0.first.map { CampusDestination(roomID:$0.id,nearestSameName:true) } } }
    public func node(_ id: String) -> CampusNode? { nodes.first { $0.id == id } }
    public func region(_ id: String) -> CampusRegion? { regions.first { $0.id == id } }
    public func floorName(_ id: String) -> String { floors.first { $0.id == id }?.name ?? "未知楼层" }
    public func nodeLabel(_ node:CampusNode) -> String {
        let number = (nodes.firstIndex { $0.id == node.id } ?? nodes.count)+1
        guard node.kind != .waypoint else { return String(format:"路点 %03d",number) }
        let name = node.name.trimmingCharacters(in:.whitespacesAndNewlines)
        return name.isEmpty ? String(format:"未命名%@ %03d",node.kind.title,number) : name
    }
    /// Only ordinary waypoints omit their labels. Stairs, junctions and destinations keep names.
    public func nodeMapLabel(_ node:CampusNode) -> String? { node.kind == .waypoint ? nil : nodeLabel(node) }
    public func title(_ node: CampusNode) -> String { "\(floorName(node.floor_id)) · \(nodeLabel(node))" }
    public func binding(nodeID: String, regionID: String) -> CampusBinding? {
        bindings.first { $0.node_id == nodeID && $0.region_id == regionID }
    }
    public func validate() throws {
        func validID(_ id: String) -> Bool { UUID(uuidString: id) != nil }
        func validName(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.count <= 120 }
        func unique(_ ids: [String]) -> Bool { ids.allSatisfy(validID) && Set(ids).count == ids.count }
        guard [1,2,3].contains(schema_version), validID(building_id), validName(name), revision >= 0,
              floors.count <= 100, regions.count <= 200, nodes.count <= 3000, edges.count <= 10000,
              bindings.count <= 10000, rooms.count <= 10000, unique(rooms.map(\.id)),
              Set(nodes.map(\.id)).isDisjoint(with:Set(rooms.map(\.id))), unique(floors.map(\.id)), unique(regions.map(\.id)),
              unique(nodes.map(\.id)), unique(edges.map(\.id)), floors.allSatisfy({ validName($0.name) }) else {
            throw CampusError.invalid("路网格式、编号或名称无效。")
        }
        let floorIDs = Set(floors.map(\.id)), regionLookup = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, $0) })
        let nodeLookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        guard map_candidates.count <= 2000,unique(map_candidates.map(\.id)),unique(map_candidates.map(\.fileID)) else { throw CampusError.corrupt }
        let candidateNodes = Dictionary(grouping:bindings,by:\.region_id).mapValues { Set($0.map(\.node_id)) }
        for candidate in map_candidates {
            try candidate.validate(regionIDs:Set(regions.map(\.id)))
            let localNodes = candidateNodes[candidate.region_id] ?? []
            for ids in [candidate.preferred_node_ids,candidate.suggested_node_ids].compactMap({ $0 }) {
                guard Set(ids).isSubset(of:localNodes) else { throw CampusError.invalid("子环境的优先节点不属于此区域。") }
            }
        }
        for region in regions {
            if let id = region.default_map_id {
                guard map_candidates.contains(where: { $0.id == id && $0.region_id == region.id && $0.enabled }) else { throw CampusError.corrupt }
            }
        }
        guard regions.allSatisfy({ floorIDs.contains($0.floor_id) && validName($0.name) }),
              nodes.allSatisfy({ floorIDs.contains($0.floor_id) && ($0.name.isEmpty || validName($0.name)) }),
              Set(bindings.map { $0.region_id + ":" + $0.node_id }).count == bindings.count,
              Set(bindings.map { $0.region_id + ":" + $0.anchor_id }).count == bindings.count else {
            throw CampusError.invalid("节点、区域的楼层或绑定关系无效。")
        }
        for b in bindings {
            guard let r = regionLookup[b.region_id], let n = nodeLookup[b.node_id], r.floor_id == n.floor_id,
                  validID(b.anchor_id), RigidMatrix.valid(b.anchor_to_map) else {
                throw CampusError.invalid("节点的 AR 绑定无效。")
            }
        }
        for e in edges {
            guard let a = nodeLookup[e.from], let b = nodeLookup[e.to], a.id != b.id,
                  e.cost_m.isFinite, e.cost_m > 0, e.cost_m < 10000 else {
                throw CampusError.invalid("路线端点或通行距离无效。")
            }
            if e.kind == .walk {
                guard let rid = e.region_id, let r = regionLookup[rid], r.floor_id == a.floor_id, a.floor_id == b.floor_id,
                      binding(nodeID: a.id, regionID: rid) != nil, binding(nodeID: b.id, regionID: rid) != nil,
                      let length = e.length_m, length.isFinite, length > 0, length < 10000 else {
                    throw CampusError.invalid("走廊连接必须属于同一局部区域，两端都需要绑定。")
                }
            } else {
                guard e.region_id == nil, a.kind == .stair, b.kind == .stair, a.floor_id != b.floor_id,
                      e.length_m == nil || (e.length_m!.isFinite && e.length_m! > 0) else {
                    throw CampusError.invalid("楼梯需要连接不同楼层的两个楼梯口。")
                }
            }
        }
        for room in rooms {
            guard validName(room.name), room.fraction.isFinite, (0...1).contains(room.fraction),
                  edges.contains(where: { $0.id == room.edge_id && $0.kind == .walk }) else { throw CampusError.invalid("沿线房间的位置或连接无效。") }
        }
    }
    public mutating func removeEdge(_ id: String) {
        edges.removeAll { $0.id == id }; rooms.removeAll { $0.edge_id == id }
    }
    @discardableResult public mutating func connect(_ from: String, _ to: String, regionID: String) throws -> CampusEdge {
        guard from != to, let a = binding(nodeID: from, regionID: regionID), let b = binding(nodeID: to, regionID: regionID) else {
            throw CampusError.invalid("请先在当前区域绑定两个不同节点。")
        }
        if let existing = edges.first(where: { $0.kind == .walk && $0.region_id == regionID &&
            (($0.from == from && $0.to == to) || ($0.bidirectional && $0.to == from && $0.from == to)) }) { return existing }
        // The same local map supplies both positions; never subtract positions from different maps.
        let d = hypot(b.position[0] - a.position[0], b.position[2] - a.position[2])
        guard d >= 0.1 else { throw CampusError.invalid("两个节点太近，请检查是否重复标点。") }
        let e = CampusEdge(from: from, to: to, regionID: regionID, length: d); edges.append(e)
        try validate(); return e
    }
    public mutating func removeNode(_ id: String) {
        nodes.removeAll { $0.id == id }; bindings.removeAll { $0.node_id == id }
        for i in map_candidates.indices {
            map_candidates[i].preferred_node_ids?.removeAll { $0 == id }
            map_candidates[i].suggested_node_ids?.removeAll { $0 == id }
            map_candidates[i].node_coverage.removeValue(forKey:id)
        }
        for edge in edges.filter({ $0.from == id || $0.to == id }) { removeEdge(edge.id) }
    }
    public mutating func removeRegion(_ id: String) {
        let oldNodes = Set(bindings.filter { $0.region_id == id }.map(\.node_id))
        regions.removeAll { $0.id == id }; bindings.removeAll { $0.region_id == id }
        map_candidates.removeAll { $0.region_id == id }
        for edge in edges.filter({ $0.region_id == id }) { removeEdge(edge.id) }
        for nid in oldNodes where !bindings.contains(where: { $0.node_id == nid }) { removeNode(nid) }
    }
}

public struct CampusLeg: Codable, Equatable {
    public var kind: CampusEdge.Kind
    public var region_id: String?
    public var node_ids: [String]
    public var edge_ids: [String]
}
public struct CampusPath: Codable, Equatable {
    public var node_ids: [String]
    public var edge_ids: [String]
    public var total_cost_m: Double
    public var legs: [CampusLeg]
}
public enum CampusRouter {
    public static func plan(graph: CampusGraph, from: String, to: String) throws -> CampusPath {
        try graph.validate()
        guard graph.node(from) != nil, graph.node(to) != nil else { throw CampusError.invalid("请选择有效的起点和目的地。") }
        if from == to { return CampusPath(node_ids: [from], edge_ids: [], total_cost_m: 0, legs: []) }
        var adjacency: [String: [(String, CampusEdge)]] = [:]
        for e in graph.edges where e.enabled {
            // A draft region must never become a navigation shortcut.
            if e.kind == .walk && graph.region(e.region_id ?? "")?.map_saved != true { continue }
            adjacency[e.from, default: []].append((e.to, e))
            if e.bidirectional { adjacency[e.to, default: []].append((e.from, e)) }
        }
        var distance = [from: 0.0], previous: [String: (String, CampusEdge)] = [:], visited = Set<String>()
        while let next = distance.filter({ !visited.contains($0.key) }).min(by: {
            $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value
        }) {
            let current = next.key
            if current == to { break }
            visited.insert(current)
            for (neighbor, edge) in (adjacency[current] ?? []).sorted(by: { $0.1.id < $1.1.id }) where !visited.contains(neighbor) {
                let proposed = next.value + edge.cost_m
                if proposed < (distance[neighbor] ?? .infinity) { distance[neighbor] = proposed; previous[neighbor] = (current, edge) }
            }
        }
        guard let cost = distance[to], previous[to] != nil else { throw CampusError.noRoute }
        var ns = [to], es: [CampusEdge] = [], current = to
        while current != from {
            guard let p = previous[current] else { throw CampusError.noRoute }
            es.append(p.1); current = p.0; ns.append(current)
        }
        ns.reverse(); es.reverse()
        var legs: [CampusLeg] = []
        for (i, e) in es.enumerated() {
            if e.kind == .walk, let last = legs.last, last.kind == .walk, last.region_id == e.region_id {
                legs[legs.count-1].node_ids.append(ns[i+1]); legs[legs.count-1].edge_ids.append(e.id)
            } else {
                legs.append(CampusLeg(kind: e.kind, region_id: e.region_id, node_ids: [ns[i],ns[i+1]], edge_ids: [e.id]))
            }
        }
        return CampusPath(node_ids: ns, edge_ids: es.map(\.id), total_cost_m: cost, legs: legs)
    }
}

public struct CampusRegionSnapshot: Codable {
    public var schema_version = 1
    public var building_id: String
    public var region_id: String
    public var floor_id: String
    public var saved_utc: String
    public var source_session_id: String
    public var feature_point_count: Int
    public var saved_mapping_status = "mapped"
    public var bindings: [CampusBinding]
    public init(graph: CampusGraph, region: CampusRegion, sessionID: String, features: Int) {
        building_id = graph.building_id; region_id = region.id; floor_id = region.floor_id
        saved_utc = ISO8601DateFormatter().string(from: Date()); source_session_id = sessionID
        feature_point_count = features; bindings = graph.bindings.filter { $0.region_id == region.id }
    }
    public func validate(graph: CampusGraph, region: CampusRegion, candidate: Bool = false) throws {
        guard schema_version == 1, building_id == graph.building_id, region_id == region.id,
              floor_id == region.floor_id, UUID(uuidString: source_session_id) != nil, feature_point_count > 0,
              saved_mapping_status == "mapped", !bindings.isEmpty,
              Set(bindings.map(\.node_id)).count == bindings.count,
              Set(bindings.map(\.anchor_id)).count == bindings.count,
              bindings.allSatisfy({ $0.region_id == region.id && UUID(uuidString: $0.node_id) != nil &&
                  UUID(uuidString: $0.anchor_id) != nil && RigidMatrix.valid($0.anchor_to_map) }) else { throw CampusError.corrupt }
        // Deleted semantic nodes may leave unused anchors in an archived map.
        if !candidate {
            for binding in graph.bindings where binding.region_id == region.id {
                guard bindings.contains(binding) else { throw CampusError.corrupt }
            }
        }
    }
}
