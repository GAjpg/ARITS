import Foundation

public enum CampusStartSelection: Equatable {
    case unknown, place(CampusDestination), region(String)
    case floor(String), environment(regionID:String,nodeID:String?)
    public var directRegionID:String? {
        switch self { case .environment(let id,_),.region(let id):return id;default:return nil }
    }
    public var nearbyNodeID:String? {
        switch self { case .environment(_,let node):return node;case .place(let p):return p.kind == .node ? p.id : nil;default:return nil }
    }
    public func title(in graph:CampusGraph) -> String {
        switch self {
        case .unknown:return "不知道起始地"
        case .place(let p):return p.title(in:graph)
        case .region(let id):return graph.region(id).map { graph.floorName($0.floor_id)+" · "+$0.name } ?? "未知区域"
        case .floor(let id):return graph.floorName(id)+" · 不知道环境"
        case .environment(let id,let node):
            return (graph.region(id).map { graph.floorName($0.floor_id)+" · "+$0.name } ?? "未知环境")+(node.flatMap { graph.node($0).map { " · "+graph.nodeLabel($0)+"附近" } } ?? "")
        }
    }
}

// The start hint constrains only initial localization, never the later route.
// Neighborhood distances follow the floor's walk graph, not different maps' origins.
public struct CampusLocalizationScope {
    public let regionIDs:Set<String>
    public let edgeRanges:[String:[ClosedRange<Double>]]
    public static func make(graph:CampusGraph,start:CampusStartSelection,maxWalkDistance:Double = 20) throws -> CampusLocalizationScope {
        try graph.validate()
        guard maxWalkDistance.isFinite,maxWalkDistance > 0 else { throw CampusError.invalid("起始地搜索范围无效。") }
        let walks = graph.edges.filter { $0.kind == .walk && $0.enabled && graph.region($0.region_id!)?.map_saved == true }
        if case .floor(let fid) = start {
            guard graph.floors.contains(where:{$0.id == fid}) else { throw CampusError.invalid("所选楼层已不存在。") }
            let local = walks.filter { graph.node($0.from)?.floor_id == fid }
            guard !local.isEmpty else { throw CampusError.invalid("该楼层尚无已保存的可通行环境。") }
            return CampusLocalizationScope(regionIDs:Set(local.compactMap(\.region_id)),edgeRanges:Dictionary(uniqueKeysWithValues:local.map { ($0.id,[0...1]) }))
        }
        if case .environment(let rid,let nid) = start {
            guard let r = graph.region(rid),r.map_saved else { throw CampusError.invalid("所选环境尚未保存。") }
            let local = walks.filter { $0.region_id == rid }
            let ranges:[String:[ClosedRange<Double>]]
            if let nid {
                guard graph.binding(nodeID:nid,regionID:rid) != nil else { throw CampusError.invalid("附近节点不属于所选环境。") }
                ranges = try make(graph:graph,start:.place(CampusDestination(nodeID:nid)),maxWalkDistance:maxWalkDistance).edgeRanges.filter { item in local.contains { $0.id == item.key } }
            } else { ranges = Dictionary(uniqueKeysWithValues:local.map { ($0.id,[0...1]) }) }
            guard !ranges.isEmpty else { throw CampusError.invalid("所选环境附近没有可通行线路。") }
            return CampusLocalizationScope(regionIDs:[rid],edgeRanges:ranges)
        }
        if start == .unknown { return CampusLocalizationScope(regionIDs:Set(walks.compactMap(\.region_id)),edgeRanges:Dictionary(uniqueKeysWithValues:walks.map { ($0.id,[0.0...1.0]) })) }
        var floorID:String,seeds:[String:Double] = [:],ranges:[String:[ClosedRange<Double>]] = [:]
        switch start {
        case .unknown,.floor,.environment:fatalError("handled above")
        case .region(let rid):
            guard let r = graph.region(rid),r.map_saved else { throw CampusError.invalid("起始区域尚未保存。") };floorID = r.floor_id
            for e in walks where e.region_id == rid { seeds[e.from] = 0;seeds[e.to] = 0;ranges[e.id] = [0...1] }
        case .place(let p):
            if p.kind == .node {
                guard let n = graph.node(p.id) else { throw CampusError.invalid("起始地已不存在。") };floorID = n.floor_id;seeds[n.id] = 0
            } else {
                guard let room = graph.room(p.id),let e = walks.first(where:{$0.id == room.edge_id}),let n = graph.node(e.from) else { throw CampusError.invalid("起始房间的线路不可通行或尚未保存。") }
                floorID = n.floor_id;let length = e.length_m!
                seeds[e.from] = length*room.fraction;seeds[e.to] = length*(1-room.fraction)
                ranges[e.id] = [max(0,room.fraction-maxWalkDistance/length)...min(1,room.fraction+maxWalkDistance/length)]
            }
        }
        let local = walks.filter { graph.node($0.from)?.floor_id == floorID }
        var adjacent:[String:[(String,Double)]] = [:]
        for e in local {
            adjacent[e.from,default:[]].append((e.to,e.length_m!));adjacent[e.to,default:[]].append((e.from,e.length_m!))
        }
        var distances = seeds,visited = Set<String>()
        while let next = distances.filter({ !visited.contains($0.key) && $0.value <= maxWalkDistance }).min(by:{$0.value < $1.value}) {
            visited.insert(next.key)
            for (id,length) in adjacent[next.key] ?? [] {
                let d = next.value+length
                if d <= maxWalkDistance,d < distances[id,default:.infinity] { distances[id] = d }
            }
        }
        for e in local {
            let length = e.length_m!
            if let d = distances[e.from],d <= maxWalkDistance { ranges[e.id,default:[]].append(0...min(1,(maxWalkDistance-d)/length)) }
            if let d = distances[e.to],d <= maxWalkDistance { ranges[e.id,default:[]].append(max(0,1-(maxWalkDistance-d)/length)...1) }
        }
        guard !ranges.isEmpty else { throw CampusError.invalid("起始地附近没有已保存的可通行线路，请选附近区域或不知道起始地。") }
        let regions = Set(local.filter { ranges[$0.id] != nil }.compactMap(\.region_id))
        return CampusLocalizationScope(regionIDs:regions,edgeRanges:ranges)
    }
}

public enum CampusNavigationProgress {
    public static let passageRadius = 6.0
    public static func canConfirm(horizontalDistance:Double) -> Bool {
        horizontalDistance.isFinite && horizontalDistance >= 0 && horizontalDistance <= passageRadius
    }
}
