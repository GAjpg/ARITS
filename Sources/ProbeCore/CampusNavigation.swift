import Foundation

public struct CampusRoom: Codable, Equatable {
    public enum Side: String, Codable { case left, right
        // Keep the old wire values so existing backups retain their physical side.
        public var title: String { self == .left ? "黄侧" : "蓝侧" }
        public var opposite: Side { self == .left ? .right : .left }
    }
    public var id: String
    public var name: String
    public var edge_id: String
    public var fraction: Double
    public var side: Side // Relative to the stored edge's from -> to direction.
    public init(name:String,edgeID:String,fraction:Double,side:Side,id:String = UUID().uuidString) {
        self.id = id; self.name = name; edge_id = edgeID; self.fraction = fraction; self.side = side
    }
}
public struct CampusDestination: Codable, Equatable {
    public enum Kind: String, Codable { case node, room }
    public var kind: Kind
    public var id: String
    /// UI room groups resolve to the shortest reachable entrance after actual localization.
    /// nil preserves exact room-ID requests from older callers and backups.
    public var nearest_same_name:Bool?
    public init(nodeID:String) { kind = .node; id = nodeID }
    public init(roomID:String,nearestSameName:Bool = false) { kind = .room; id = roomID;nearest_same_name = nearestSameName ? true : nil }
    public func title(in graph:CampusGraph) -> String {
        if kind == .node, let n = graph.node(id) { return graph.title(n) }
        if kind == .room, let r = graph.room(id) { return graph.title(r) }
        return "未知目的地"
    }
}
public struct CampusRoutePosition: Codable, Equatable {
    public var region_id: String
    public var edge_id: String
    public var fraction: Double
    public init(regionID:String,edgeID:String,fraction:Double) { region_id = regionID; edge_id = edgeID; self.fraction = fraction }
}
public struct CampusLocatedPosition: Equatable {
    public var position: CampusRoutePosition
    public var point: [Double]
    public var distance_m: Double
}
public enum CampusPositionLocator {
    public static func project(_ point:[Double],a:[Double],b:[Double]) throws -> (fraction:Double,point:[Double],distance:Double) {
        guard point.count == 3, a.count == 3, b.count == 3, (point+a+b).allSatisfy(\.isFinite) else { throw CampusError.invalid("当前位置坐标无效。") }
        let dx = b[0]-a[0], dz = b[2]-a[2], square = dx*dx+dz*dz
        guard square > 0.0001 else { throw CampusError.invalid("连接太短，不能定位到线路。") }
        let t = min(1,max(0,((point[0]-a[0])*dx+(point[2]-a[2])*dz)/square))
        let projected = (0..<3).map { a[$0]+t*(b[$0]-a[$0]) }
        return (t,projected,hypot(point[0]-projected[0],point[2]-projected[2]))
    }
    // nil permits guidance back to the network; it does not certify AR localization.
    public static func locate(graph:CampusGraph,regionID:String,point:[Double],previousEdgeID:String? = nil,maxDistance:Double? = 2.5,allowedRanges:[String:[ClosedRange<Double>]]? = nil) throws -> CampusLocatedPosition {
        guard point.count == 3,point.allSatisfy(\.isFinite),maxDistance == nil || (maxDistance!.isFinite && maxDistance! >= 0) else { throw CampusError.invalid("当前位置或线路距离设置无效。") }
        var candidates: [CampusLocatedPosition] = []
        for e in graph.edges where e.kind == .walk && e.region_id == regionID && e.enabled {
            guard let a = graph.binding(nodeID:e.from,regionID:regionID),let b = graph.binding(nodeID:e.to,regionID:regionID) else { continue }
            let p = try project(point,a:a.position,b:b.position)
            if let allowedRanges,!((allowedRanges[e.id] ?? []).contains { $0.contains(p.fraction) }) { continue }
            candidates.append(CampusLocatedPosition(position:CampusRoutePosition(regionID:regionID,edgeID:e.id,fraction:p.fraction),point:p.point,distance_m:p.distance))
        }
        guard let best = candidates.min(by:{ $0.distance_m == $1.distance_m ? $0.position.edge_id < $1.position.edge_id : $0.distance_m < $1.distance_m }) else { throw CampusError.invalid("当前环境或起始地范围内没有可用线路，请核对起始地。") }
        if let maxDistance,best.distance_m > maxDistance { throw CampusError.invalid("当前位置离已绘线路较远，请回到走廊或重新识别所在区域。") }
        if let previous = candidates.first(where:{ $0.position.edge_id == previousEdgeID }),previous.distance_m <= best.distance_m+0.20,maxDistance == nil || previous.distance_m <= maxDistance! { return previous }
        return best
    }
}

public enum CampusRouteAccess {
    public static let joinRadius = 2.5
    public static let transferRadius = 1.5
    public static func shouldReplan(closest:CampusLocatedPosition,plannedStart:CampusLocatedPosition?,edgeIDs:[String],routeProjection:ProbePoint?) -> Bool {
        if let routeProjection {
            return !edgeIDs.contains(closest.position.edge_id) || hypot(routeProjection.x-closest.point[0],routeProjection.z-closest.point[2]) > 1
        }
        guard let plannedStart else { return true }
        // An empty walking leg can mean "at the destination" or "at a map
        // handoff"; walking away along the same edge must revoke that plan too.
        return closest.position.edge_id != plannedStart.position.edge_id || hypot(closest.point[0]-plannedStart.point[0],closest.point[2]-plannedStart.point[2]) > 1
    }
    /// A short bearing indicator, not a traversable path through an unmapped room.
    public static func directionArrow(from:ProbePoint,to:ProbePoint) -> [ProbePoint] {
        guard (from.array+to.array).allSatisfy(\.isFinite) else { return [] }
        let dx = to.x-from.x,dz = to.z-from.z,length = hypot(dx,dz)
        guard length > 0.05 else { return [] }
        let start = min(0.35,length*0.2),end = min(1.5,length)
        return [ProbePoint(from.x+dx/length*start,to.y,from.z+dz/length*start),ProbePoint(from.x+dx/length*end,to.y,from.z+dz/length*end)]
    }
}
public struct CampusRoutePoint: Codable, Equatable {
    public var node_id: String
    public var region_id: String
    public var map_position: [Double]
    public var edge_id: String?
    public var fraction: Double?
}
public struct CampusPlanningRequest: Codable {
    public var graph: CampusGraph
    public var start: CampusRoutePosition
    public var destination: CampusDestination
    public init(graph:CampusGraph,start:CampusRoutePosition,destination:CampusDestination) { self.graph = graph; self.start = start; self.destination = destination }
}
public struct CampusNavigationPlan: Codable {
    public var path: CampusPath
    public var points: [CampusRoutePoint]
    public var destination: CampusDestination
    public var arrival_hint: String?
    public func point(nodeID:String,regionID:String) -> CampusRoutePoint? { points.first { $0.node_id == nodeID && $0.region_id == regionID } }
}
// The client uses this offline implementation. A later route-only service can
// implement the same request/result contract; no networking is needed now.
public protocol CampusRoutePlanning {
    func plan(_ request:CampusPlanningRequest) throws -> CampusNavigationPlan
}
public struct CampusOfflinePlanner: CampusRoutePlanning {
    public init() {}
    public func plan(_ request:CampusPlanningRequest) throws -> CampusNavigationPlan {
        let base = request.graph; try base.validate()
        guard let startEdge = base.edges.first(where:{ $0.id == request.start.edge_id && $0.kind == .walk && $0.enabled }),
              startEdge.region_id == request.start.region_id,base.region(request.start.region_id)?.map_saved == true,
              request.start.fraction.isFinite,(0...1).contains(request.start.fraction) else { throw CampusError.invalid("当前位置不在可通行线路上。") }
        if request.destination.kind == .room,request.destination.nearest_same_name == true {
            var reachable:[CampusNavigationPlan] = []
            for room in base.sameNameRooms(request.destination.id) {
                do { reachable.append(try plan(CampusPlanningRequest(graph:base,start:request.start,destination:CampusDestination(roomID:room.id)))) }
                catch CampusError.noRoute { continue }
            }
            guard let closest = reachable.min(by: { a,b in a.path.total_cost_m == b.path.total_cost_m ? a.destination.id < b.destination.id : a.path.total_cost_m < b.path.total_cost_m }) else { throw CampusError.noRoute }
            return closest
        }
        var graph = base; graph.rooms = []
        var additions: [String:[(Double,String,String)]] = [:]
        let startID = UUID().uuidString
        additions[startEdge.id] = [(request.start.fraction,startID,"当前位置")]
        var goalID = request.destination.id
        var room:CampusRoom?
        if request.destination.kind == .room {
            guard let r = base.room(goalID),let edge = base.edges.first(where:{$0.id == r.edge_id && $0.enabled}) else { throw CampusError.noRoute }
            room = r; additions[edge.id,default:[]].append((r.fraction,r.id,r.name))
        } else if base.node(goalID) == nil { throw CampusError.invalid("目的地不存在。") }
        var aliases:[String:String] = [:], originals:[String:String] = [:], virtual:[String:(String,Double)] = [:]
        for (edgeID, inserted) in additions {
            let e = base.edges.first { $0.id == edgeID }!, rid = e.region_id!
            let a = base.binding(nodeID:e.from,regionID:rid)!, b = base.binding(nodeID:e.to,regionID:rid)!
            var stops:[(Double,String)] = [(0,e.from)]
            for (t,id,name) in inserted.sorted(by:{$0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0}) {
                if t <= 1e-8 { aliases[id] = e.from; continue }
                if t >= 1-1e-8 { aliases[id] = e.to; continue }
                if let last = stops.last,abs(last.0-t) <= 1e-8 { aliases[id] = last.1; continue }
                let n = CampusNode(floorID:base.node(e.from)!.floor_id,name:name,kind:.waypoint,id:id)
                graph.nodes.append(n)
                var transform = a.anchor_to_map
                for j in 0..<3 { transform[j][3] = a.position[j]+t*(b.position[j]-a.position[j]) }
                graph.bindings.append(CampusBinding(regionID:rid,nodeID:id,anchorID:UUID().uuidString,transform:transform))
                virtual[id] = (e.id,t); stops.append((t,id))
            }
            stops.append((1,e.to)); graph.edges.removeAll { $0.id == e.id }
            for (first,last) in zip(stops,stops.dropFirst()) {
                var segment = CampusEdge(from:first.1,to:last.1,regionID:rid,length:e.length_m!*(last.0-first.0))
                segment.cost_m = e.cost_m*(last.0-first.0); segment.bidirectional = e.bidirectional
                originals[segment.id] = e.id; graph.edges.append(segment)
            }
        }
        let source = aliases[startID] ?? startID; goalID = aliases[goalID] ?? goalID
        var path = try CampusRouter.plan(graph:graph,from:source,to:goalID)
        path.edge_ids = path.edge_ids.map { originals[$0] ?? $0 }
        for i in path.legs.indices { path.legs[i].edge_ids = path.legs[i].edge_ids.map { originals[$0] ?? $0 } }
        let ids = Set(path.node_ids)
        let points = graph.bindings.filter { ids.contains($0.node_id) }.map { b in
            CampusRoutePoint(node_id:b.node_id,region_id:b.region_id,map_position:b.position,edge_id:virtual[b.node_id]?.0,fraction:virtual[b.node_id]?.1)
        }
        var hint = room.map { "已到 \($0.name) 附近，请核对门牌。" }
        if let room,let edge = base.edges.first(where:{$0.id == room.edge_id}),let rid = edge.region_id,
           let a = base.binding(nodeID:edge.from,regionID:rid),let b = base.binding(nodeID:edge.to,regionID:rid),
           let leg = path.legs.last,leg.kind == .walk,leg.region_id == rid,leg.edge_ids.last == edge.id,leg.node_ids.count >= 2,
           let end = points.first(where:{$0.node_id == leg.node_ids.last! && $0.region_id == rid}),
           let previous = points.first(where:{$0.node_id == leg.node_ids[leg.node_ids.count-2] && $0.region_id == rid}) {
            let dot = (end.map_position[0]-previous.map_position[0])*(b.position[0]-a.position[0])+(end.map_position[2]-previous.map_position[2])*(b.position[2]-a.position[2])
            if abs(dot) > 1e-6 { let side = dot > 0 ? room.side : room.side.opposite;hint = "\(room.name) 在行进方向的\(side == .left ? "左侧" : "右侧")，请核对门牌。" }
        }
        return CampusNavigationPlan(path:path,points:points,destination:request.destination,arrival_hint:hint)
    }
}
