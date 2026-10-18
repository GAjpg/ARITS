import Foundation

public struct OutdoorRouteStep: Equatable, Sendable {
    public let maneuver: NavigationManeuver
    public let pointIndex: Int
    public let distanceFromStartM: Double
}
public struct OutdoorRoute: Sendable {
    public let buildingID: String
    public let entrance: OutdoorEntrance
    public let nodeIndices: [Int]
    public let points: [OutdoorCoordinate]
    public let cumulativeM: [Double]
    public let steps: [OutdoorRouteStep]
    public let selectionScore: Double
    public let accessDistanceM: Double
    public var lengthM: Double { cumulativeM.last ?? 0 }
    public func projection(_ p:OutdoorCoordinate) -> (alongM:Double,lateralM:Double,point:OutdoorCoordinate) {
        guard let first = points.first else { return (0,.infinity,p) }
        let f = OutdoorLocalFrame(origin:first)
        var best = (alongM:0.0,lateralM:Double.infinity,point:first)
        if points.count == 1 { return (0,f.distance(first,p),first) }
        for i in 0..<(points.count-1) {
            let q = f.project(p,from:points[i],to:points[i+1])
            if q.distanceM < best.lateralM { best = (cumulativeM[i]+q.fraction*(cumulativeM[i+1]-cumulativeM[i]),q.distanceM,q.point) }
        }
        return best
    }
    /// Project only into the clipped arc interval around the last accepted progress.
    /// Invalid input returns nil, never an implicit global rematch. Reset hint for a new route.
    public func projection(_ p:OutdoorCoordinate,near alongHintM:Double,window:Double) -> (alongM:Double,lateralM:Double,point:OutdoorCoordinate)? {
        guard p.isValid,alongHintM.isFinite,window.isFinite,window >= 0,alongHintM >= 0,alongHintM <= lengthM,
              let first = points.first,points.count == cumulativeM.count else { return nil }
        let lower = max(0,alongHintM-window),upper = min(lengthM,alongHintM+window),f = OutdoorLocalFrame(origin:first)
        if points.count == 1 { return (0,f.distance(first,p),first) }
        var best:(alongM:Double,lateralM:Double,point:OutdoorCoordinate)?
        for i in 0..<(points.count-1) {
            let lo = max(lower,cumulativeM[i]),hi = min(upper,cumulativeM[i+1])
            guard hi >= lo else { continue }
            let span = cumulativeM[i+1]-cumulativeM[i]
            func at(_ distance:Double) -> OutdoorCoordinate {
                let t = span > 0 ? (distance-cumulativeM[i])/span : 0
                return .init(latitude:points[i].latitude+(points[i+1].latitude-points[i].latitude)*t,
                             longitude:points[i].longitude+(points[i+1].longitude-points[i].longitude)*t)
            }
            let q = f.project(p,from:at(lo),to:at(hi)),along = lo+q.fraction*(hi-lo)
            if let old = best {
                if q.distanceM < old.lateralM-1e-8 || (abs(q.distanceM-old.lateralM) <= 1e-8 && abs(along-alongHintM) < abs(old.alongM-alongHintM)) { best = (along,q.distanceM,q.point) }
            } else { best = (along,q.distanceM,q.point) }
        }
        return best
    }
    public func point(at distance:Double) -> OutdoorCoordinate? {
        guard let first = points.first else { return nil }
        if distance <= 0 { return first }
        for i in 1..<points.count where cumulativeM[i] >= distance {
            let t = (distance-cumulativeM[i-1])/max(1e-9,cumulativeM[i]-cumulativeM[i-1])
            return .init(latitude:points[i-1].latitude+(points[i].latitude-points[i-1].latitude)*t,
                         longitude:points[i-1].longitude+(points[i].longitude-points[i-1].longitude)*t)
        }
        return points.last
    }
}

public enum OutdoorPlanFailure: String, Codable, Sendable {
    case invalidInput = "invalid_input", unknownBuilding = "unknown_building", noEntrances = "no_entrances"
    case noCandidateEdges = "no_candidate_edges", startTooFar = "start_too_far", startBlocked = "start_blocked"
    case entranceNoAccess = "entrance_no_access", disconnected
}
public struct OutdoorPlanResult: Sendable {
    public let route: OutdoorRoute?
    public let failure: OutdoorPlanFailure?
    /// Nearest edge before footprint filtering, nil when input is invalid or no edges exist.
    public let nearestStartDistanceM: Double?
    /// All start edges inside the radius, before footprint filtering. Never truncated.
    public let startCandidateCount: Int
    /// Fixed door anchors plus visible coordinate-door edge anchors. Never truncated.
    public let entranceCandidateCount: Int
    public let attemptedStartCandidates: Int
}

/// A* over validated campus data. Search lengths are metric, edge costs include road factors.
public final class OutdoorRouter {
    public struct GraphPath: Sendable {
        public let nodes:[Int]
        public let edgeIndices:[Int]
        public let cost:Double
    }
    private let campus:OutdoorCampus
    private let frame:OutdoorLocalFrame
    private let adjacency:[[(node:Int,edge:Int)]]
    private let heuristicScale:Double
    private let componentIDs:[Int]
    public init(campus:OutdoorCampus) {
        self.campus = campus;frame = campus.frame
        var adj = [[(node:Int,edge:Int)]](repeating:[],count:campus.graph.nodes.count), scale = 1.0
        for (i,e) in campus.graph.edges.enumerated() {
            adj[e.from].append((e.to,i));adj[e.to].append((e.from,i))
            let physical = frame.distance(campus.graph.nodes[e.from],campus.graph.nodes[e.to])
            if physical > 0 { scale = min(scale,e.cost/physical) }
        }
        adjacency = adj;heuristicScale = max(0,scale)
        var components = [Int](repeating:-1,count:adj.count),nextID = 0
        for root in adj.indices where components[root] == -1 {
            var pending = [root];components[root] = nextID
            while let u = pending.popLast() {
                for v in adj[u] where components[v.node] == -1 { components[v.node] = nextID;pending.append(v.node) }
            }
            nextID += 1
        }
        componentIDs = components
    }
    public func routeNodes(from:Int,to:Int) -> GraphPath? {
        guard adjacency.indices.contains(from),adjacency.indices.contains(to) else { return nil }
        var costs = [Double](repeating:.infinity,count:adjacency.count)
        var previous = [Int](repeating:-1,count:adjacency.count), edges = previous
        var queue = OutdoorMinHeap();costs[from] = 0
        queue.push(node:from,priority:0,cost:0)
        while let item = queue.pop() {
            let u = item.node
            if item.cost > costs[u]+1e-9 { continue }
            if u == to { break }
            for next in adjacency[u] {
                let cost = costs[u]+campus.graph.edges[next.edge].cost
                if cost+1e-9 < costs[next.node] {
                    costs[next.node] = cost;previous[next.node] = u;edges[next.node] = next.edge
                    let h = frame.distance(campus.graph.nodes[next.node],campus.graph.nodes[to])*heuristicScale
                    queue.push(node:next.node,priority:cost+h,cost:cost)
                }
            }
        }
        guard costs[to].isFinite else { return nil }
        var nodes = [to], edgeIDs = [Int](), cursor = to
        while cursor != from {
            guard previous[cursor] >= 0 else { return nil }
            edgeIDs.append(edges[cursor]);cursor = previous[cursor];nodes.append(cursor)
        }
        return .init(nodes:nodes.reversed(),edgeIndices:edgeIDs.reversed(),cost:costs[to])
    }
    private struct Snap {
        let edge: Int
        let point: OutdoorCoordinate
        let distance: Double
        let fraction: Double
    }
    /// A supplied entrance list is authoritative. A binding may use nodeIndex=-1 when it only
    /// knows a verified physical door coordinate; connect it to a visible graph edge within 20 m.
    /// This is an outdoor access segment, not a guarantee that an unrecorded path is open.
    public func plan(from:OutdoorCoordinate,buildingID:String,entrances:[OutdoorEntrance]? = nil,
                     maximumSnapM:Double = 80,directnessWeight:Double = 0.6,
                     maximumEntranceSnapM:Double = 20) -> OutdoorRoute? {
        guard from.isValid,maximumSnapM.isFinite,maximumSnapM >= 0,directnessWeight.isFinite,directnessWeight >= 0,
              maximumEntranceSnapM.isFinite,maximumEntranceSnapM >= 0,
              let building = campus.building(id:buildingID) else { return nil }
        let doors = entrances ?? building.entrances
        if doors.contains(where: { $0.accessPath != nil }) {
            return planDetailed(from:from,buildingID:buildingID,entrances:doors,maximumSnapM:maximumSnapM,
                                directnessWeight:directnessWeight,maximumEntranceSnapM:maximumEntranceSnapM).route
        }
        func projections(_ coordinate:OutdoorCoordinate, limit:Double) -> [Snap] {
            campus.graph.edges.enumerated().compactMap { i,e in
                let p = frame.project(coordinate,from:campus.graph.nodes[e.from],to:campus.graph.nodes[e.to])
                return p.distanceM <= limit ? Snap(edge:i,point:p.point,distance:p.distanceM,fraction:p.fraction) : nil
            }.sorted { $0.distance < $1.distance }
        }
        guard let snap = projections(from,limit:maximumSnapM).first else { return nil }
        let edge = campus.graph.edges[snap.edge]
        var best:OutdoorRoute?
        func consider(_ points:[OutdoorCoordinate], nodes:[Int], door:OutdoorEntrance, networkDistance:Double, networkCost:Double, doorAccess:Double) {
            let points = points.enumerated().compactMap { i,p in i == 0 || frame.distance(points[i-1],p)>0.001 ? p : nil }
            var cum = [0.0]
            for i in 1..<points.count { cum.append(cum[i-1]+frame.distance(points[i-1],points[i])) }
            let score = snap.distance+doorAccess+networkCost+directnessWeight*networkDistance
            if score < (best?.selectionScore ?? .infinity) {
                best = .init(buildingID:buildingID,entrance:door,nodeIndices:nodes,points:points,cumulativeM:cum,
                             steps:makeSteps(points,cumulative:cum),selectionScore:score,accessDistanceM:snap.distance)
            }
        }
        for door in doors where door.coordinate.isValid {
            let doorSnap:Snap?
            if campus.graph.nodes.indices.contains(door.nodeIndex) { doorSnap = nil }
            else if door.nodeIndex == -1 {
                guard let visible = projections(door.coordinate,limit:maximumEntranceSnapM).first(where: {
                    connectorIsClear(from:$0.point,to:door.coordinate,targetBuildingID:buildingID)
                }) else { continue }
                doorSnap = visible
            } else { continue }
            let ends = doorSnap.map { [campus.graph.edges[$0.edge].from,campus.graph.edges[$0.edge].to] } ?? [door.nodeIndex]
            for start in [edge.from,edge.to] {
                let startFraction = start == edge.from ? snap.fraction : 1-snap.fraction
                for end in ends {
                    guard let path = routeNodes(from:start,to:end) else { continue }
                    var points = [from,snap.point]+path.nodes.map { campus.graph.nodes[$0] }
                    var distance = frame.distance(snap.point,campus.graph.nodes[start])
                    var cost = edge.cost*startFraction
                    distance += path.nodes.indices.dropFirst().reduce(0.0) { $0+frame.distance(campus.graph.nodes[path.nodes[$1-1]],campus.graph.nodes[path.nodes[$1]]) }
                    cost += path.cost
                    if let d = doorSnap {
                        let e = campus.graph.edges[d.edge]
                        distance += frame.distance(campus.graph.nodes[end],d.point)
                        cost += e.cost*(end == e.from ? d.fraction : 1-d.fraction)
                        points.append(d.point)
                    }
                    points.append(door.coordinate)
                    let doorAccess = doorSnap?.distance ?? frame.distance(campus.graph.nodes[end],door.coordinate)
                    consider(points,nodes:path.nodes,door:door,networkDistance:distance,networkCost:cost,doorAccess:doorAccess)
                }
            }
            // Splitting both ends of the same edge must not force a detour via either endpoint.
            if let d = doorSnap, d.edge == snap.edge {
                consider([from,snap.point,d.point,door.coordinate],nodes:[],door:door,
                         networkDistance:frame.distance(snap.point,d.point),networkCost:edge.cost*abs(d.fraction-snap.fraction),doorAccess:d.distance)
            }
        }
        return best
    }
    /// Explicit multi-access planner. Old plan remains unchanged for existing callers.
    /// Try start edges in distance order and each door's closest visible edge in that component.
    /// Both off-graph access segments are footprint checked; unrecorded access still needs verification.
    public func planDetailed(from:OutdoorCoordinate,buildingID:String,entrances:[OutdoorEntrance]? = nil,
                             maximumSnapM:Double = 80,directnessWeight:Double = 0.6,
                             maximumEntranceSnapM:Double = 20) -> OutdoorPlanResult {
        var nearest:Double?,startCount = 0,doorCount = 0,attempted = 0
        func outcome(_ route:OutdoorRoute? = nil,_ failure:OutdoorPlanFailure? = nil) -> OutdoorPlanResult {
            .init(route:route,failure:failure,nearestStartDistanceM:nearest,startCandidateCount:startCount,
                  entranceCandidateCount:doorCount,attemptedStartCandidates:attempted)
        }
        guard from.isValid,maximumSnapM.isFinite,maximumSnapM >= 0,directnessWeight.isFinite,directnessWeight >= 0,
              maximumEntranceSnapM.isFinite,maximumEntranceSnapM >= 0 else { return outcome(nil,.invalidInput) }
        guard let building = campus.building(id:buildingID) else { return outcome(nil,.unknownBuilding) }
        let doors = entrances ?? building.entrances
        guard !doors.isEmpty else { return outcome(nil,.noEntrances) }
        guard !campus.graph.edges.isEmpty else { return outcome(nil,.noCandidateEdges) }
        func projections(_ coordinate:OutdoorCoordinate) -> [Snap] {
            campus.graph.edges.enumerated().map { i,e in
                let p = frame.project(coordinate,from:campus.graph.nodes[e.from],to:campus.graph.nodes[e.to])
                return Snap(edge:i,point:p.point,distance:p.distanceM,fraction:p.fraction)
            }.sorted { $0.distance == $1.distance ? $0.edge < $1.edge : $0.distance < $1.distance }
        }
        let allStarts = projections(from);nearest = allStarts.first?.distance
        let starts = allStarts.filter { $0.distance <= maximumSnapM };startCount = starts.count
        guard !starts.isEmpty else { return outcome(nil,.startTooFar) }
        let access:[(door:OutdoorEntrance,anchors:[(node:Int,snap:Snap?)],tail:[OutdoorCoordinate],tailLength:Double)] = doors.compactMap { door in
            guard door.coordinate.isValid else { return nil }
            if let manual = door.accessPath {
                guard manual.count >= 2,manual.count <= 2048,manual.allSatisfy(\.isValid),manual.first == door.coordinate,let end = manual.last else { return nil }
                let candidates = projections(end).filter { $0.distance <= 3+1e-6 }
                guard !candidates.isEmpty else { return nil }
                doorCount += candidates.count
                let anchors = candidates.flatMap { d in [(campus.graph.edges[d.edge].from,Optional(d)),(campus.graph.edges[d.edge].to,Optional(d))] }
                let length = zip(manual,manual.dropFirst()).reduce(0.0) { $0+frame.distance($1.0,$1.1) }
                return (door,anchors,Array(manual.reversed()),length)
            }
            if campus.graph.nodes.indices.contains(door.nodeIndex) {
                guard connectorIsClear(from:campus.graph.nodes[door.nodeIndex],to:door.coordinate,targetBuildingID:buildingID) else { return nil }
                doorCount += 1
                return (door,[(door.nodeIndex,nil)],[door.coordinate],0)
            }
            guard door.nodeIndex == -1 else { return nil }
            let visible = projections(door.coordinate).filter {
                $0.distance <= maximumEntranceSnapM && connectorIsClear(from:$0.point,to:door.coordinate,targetBuildingID:buildingID)
            }
            guard !visible.isEmpty else { return nil }
            doorCount += visible.count
            return (door,visible.flatMap { d in [(campus.graph.edges[d.edge].from,Optional(d)),(campus.graph.edges[d.edge].to,Optional(d))] },[door.coordinate],0)
        }
        var visibleStarts = 0
        for snap in starts {
            attempted += 1
            guard connectorIsClear(from:from,to:snap.point,targetBuildingID:nil,leaving:true) else { continue }
            visibleStarts += 1
            let edge = campus.graph.edges[snap.edge],component = componentIDs[edge.from]
            var best:OutdoorRoute?
            func consider(_ points:[OutdoorCoordinate], nodes:[Int], door:OutdoorEntrance, networkDistance:Double, networkCost:Double, doorAccess:Double) {
                let tailCount = door.accessPath?.count ?? 0
                let prefix = Array(points.dropLast(tailCount))
                var clean = prefix.enumerated().compactMap { i,p in i == 0 || frame.distance(prefix[i-1],p)>0.001 ? p : nil }
                if tailCount > 0 {
                    let tail = Array(points.suffix(tailCount))
                    if let a = clean.last,let b = tail.first,frame.distance(a,b) <= 0.001 { clean.removeLast() }
                    clean.append(contentsOf:tail)
                }
                let points = clean
                var cum = [0.0]
                for i in 1..<points.count { cum.append(cum[i-1]+frame.distance(points[i-1],points[i])) }
                let score = snap.distance+doorAccess+networkCost+directnessWeight*networkDistance
                if score < (best?.selectionScore ?? .infinity) {
                    best = .init(buildingID:buildingID,entrance:door,nodeIndices:nodes,points:points,cumulativeM:cum,
                                 steps:makeSteps(points,cumulative:cum),selectionScore:score,accessDistanceM:snap.distance)
                }
            }
            for (door,anchors,tail,tailLength) in access {
                let compatible = anchors.filter { componentIDs[$0.node] == component }
                guard let firstAnchor = compatible.first else { continue }
                let ends = compatible.filter { $0.snap?.edge == firstAnchor.snap?.edge }
                for start in [edge.from,edge.to] {
                    let startFraction = start == edge.from ? snap.fraction : 1-snap.fraction
                    for (end,doorSnap) in ends {
                        guard let path = routeNodes(from:start,to:end) else { continue }
                        var points = [from,snap.point]+path.nodes.map { campus.graph.nodes[$0] }
                        var distance = frame.distance(snap.point,campus.graph.nodes[start])
                        var cost = edge.cost*startFraction
                        distance += path.nodes.indices.dropFirst().reduce(0.0) { $0+frame.distance(campus.graph.nodes[path.nodes[$1-1]],campus.graph.nodes[path.nodes[$1]]) }
                        cost += path.cost
                        if let d = doorSnap {
                            let e = campus.graph.edges[d.edge]
                            distance += frame.distance(campus.graph.nodes[end],d.point)
                            cost += e.cost*(end == e.from ? d.fraction : 1-d.fraction)
                            points.append(d.point)
                        }
                        points.append(contentsOf:tail)
                        let doorAccess = (doorSnap?.distance ?? frame.distance(campus.graph.nodes[end],door.coordinate))+tailLength
                        consider(points,nodes:path.nodes,door:door,networkDistance:distance,networkCost:cost,doorAccess:doorAccess)
                    }
                }
                if let d = firstAnchor.snap,d.edge == snap.edge {
                    consider([from,snap.point,d.point]+tail,nodes:[],door:door,
                             networkDistance:frame.distance(snap.point,d.point),networkCost:edge.cost*abs(d.fraction-snap.fraction),doorAccess:d.distance+tailLength)
                }
            }
            if let best { return outcome(best) }
        }
        if visibleStarts == 0 { return outcome(nil,.startBlocked) }
        return outcome(nil,access.isEmpty ? .entranceNoAccess : .disconnected)
    }
    /// Test every polygon interval, so a thin footprint cannot slip between fixed sampling steps.
    /// Permit at most the final 2 m inside the destination footprint for facade/coordinate tolerance.
    /// `leaving`: a start inside a building (still indoors, or at its door) may walk out of it once.
    private func connectorIsClear(from a:OutdoorCoordinate,to b:OutdoorCoordinate,targetBuildingID:String?,leaving:Bool = false) -> Bool {
        let u = frame.local(a),v = frame.local(b),dx = v.east-u.east,dy = v.north-u.north
        let length = hypot(dx,dy)
        guard length > 1e-6 else { return true }
        for building in campus.buildings {
          for footprint in building.footprints {
            let ring = footprint.map { frame.local($0) }
            var cuts = [0.0,1.0]
            for i in ring.indices {
                let p = ring[i],q = ring[(i+1)%ring.count],ex = q.east-p.east,ey = q.north-p.north
                let cross = dx*ey-dy*ex
                if abs(cross) < 1e-10 { continue }
                let px = p.east-u.east,py = p.north-u.north
                let t = (px*ey-py*ex)/cross, s = (px*dy-py*dx)/cross
                if t > 0 && t < 1 && s >= 0 && s <= 1 { cuts.append(t) }
            }
            cuts.sort()
            for i in 1..<cuts.count where cuts[i]-cuts[i-1] > 1e-8 {
                let t = (cuts[i]+cuts[i-1])/2,x = u.east+t*dx,y = u.north+t*dy
                var inside = false
                for j in ring.indices {
                    let p = ring[j],q = ring[(j+1)%ring.count]
                    if (p.north > y) != (q.north > y), x < (q.east-p.east)*(y-p.north)/(q.north-p.north)+p.east { inside.toggle() }
                }
                if inside && leaving && cuts[i-1] < 1e-8 { continue }
                if inside && (building.id != targetBuildingID || (1-cuts[i-1])*length > 2+1e-6) { return false }
            }
          }
        }
        return true
    }
    private func makeSteps(_ p:[OutdoorCoordinate],cumulative:[Double]) -> [OutdoorRouteStep] {
        guard !p.isEmpty else { return [] }
        var steps = [OutdoorRouteStep(maneuver:.start,pointIndex:0,distanceFromStartM:0)]
        if p.count >= 3 {
            for i in 1..<(p.count-1) {
                var turn = frame.bearing(p[i],p[i+1])-frame.bearing(p[i-1],p[i])
                if turn > 180 { turn -= 360 };if turn <= -180 { turn += 360 }
                guard abs(turn) >= 30,cumulative[i]-(steps.last?.distanceFromStartM ?? 0)>=3 else { continue }
                let m:NavigationManeuver
                switch turn {
                case 150...180,-180 ... -150:m = .uTurn
                case 100..<150:m = .sharpRight
                case 45..<100:m = .right
                case 0..<45:m = .slightRight
                case -45..<0:m = .slightLeft
                case -100 ..< -45:m = .left
                default:m = .sharpLeft
                }
                steps.append(.init(maneuver:m,pointIndex:i,distanceFromStartM:cumulative[i]))
            }
        }
        steps.append(.init(maneuver:.arrive,pointIndex:p.count-1,distanceFromStartM:cumulative.last ?? 0))
        return steps
    }
}

private struct OutdoorMinHeap {
    struct Item { let node:Int;let priority:Double;let cost:Double }
    private var values = [Item]()
    mutating func push(node:Int,priority:Double,cost:Double) {
        values.append(.init(node:node,priority:priority,cost:cost));var i = values.count-1
        while i > 0 {
            let p = (i-1)/2
            if values[p].priority <= values[i].priority { break }
            values.swapAt(p,i);i = p
        }
    }
    mutating func pop() -> Item? {
        guard let first = values.first else { return nil }
        let last = values.removeLast()
        if !values.isEmpty {
            values[0] = last;var i = 0
            while true {
                let l = i*2+1,r = l+1
                guard l < values.count else { break }
                let j = r < values.count && values[r].priority < values[l].priority ? r : l
                if values[i].priority <= values[j].priority { break }
                values.swapAt(i,j);i = j
            }
        }
        return first
    }
}
