import Foundation

/// Distances follow the walkable polyline on the floor, rather than a camera-centred sphere.
public struct CampusRouteGeometry {
    public struct Projection {
        public let distance: Double
        public let offset: Double
        public let point: ProbePoint
    }
    public struct Turn: Equatable {
        public enum Direction: String { case left, right, turnBack }
        public let vertex: Int
        public let distance: Double
        public let direction: Direction
    }
    public let points: [ProbePoint]
    public let distances: [Double]
    public var length: Double { distances.last ?? 0 }
    public init(points: [ProbePoint]) throws {
        guard !points.isEmpty, points.allSatisfy({ $0.array.allSatisfy(\.isFinite) }) else {
            throw CampusError.invalid("路线坐标无效。")
        }
        self.points = points
        var sums = [0.0]
        for (a,b) in zip(points,points.dropFirst()) { sums.append(sums.last! + hypot(b.x-a.x,b.z-a.z)) }
        distances = sums
    }
    public func point(at distance: Double) -> ProbePoint {
        let d = min(length,max(0,distance.isFinite ? distance : 0))
        for i in 0..<max(0,points.count-1) where distances[i+1]-distances[i] > 1e-8 && d <= distances[i+1] {
            let t = (d-distances[i])/(distances[i+1]-distances[i]), a = points[i], b = points[i+1]
            return ProbePoint(a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t,a.z+(b.z-a.z)*t)
        }
        return points.last!
    }
    /// Optional continuity bounds prevent a nearby later leg of a loop stealing the current position.
    public func project(_ point: ProbePoint, near previous: Double? = nil) throws -> Projection {
        guard point.array.allSatisfy(\.isFinite), previous == nil || previous!.isFinite else {
            throw CampusError.invalid("当前位置坐标无效。")
        }
        let lower = previous.map { max(0,$0-6) } ?? 0, upper = previous.map { min(length,$0+8) } ?? length
        var candidates: [Projection] = []
        for i in 0..<max(0,points.count-1) {
            let size = distances[i+1]-distances[i]
            guard size > 1e-8, distances[i+1] >= lower, distances[i] <= upper else { continue }
            let a = points[i],b = points[i+1],dx = b.x-a.x,dz = b.z-a.z
            let t = ((point.x-a.x)*dx+(point.z-a.z)*dz)/(size*size)
            let lo = max(0,(lower-distances[i])/size),hi = min(1,(upper-distances[i])/size)
            let f = min(hi,max(lo,t)),p = ProbePoint(a.x+dx*f,a.y+(b.y-a.y)*f,a.z+dz*f)
            candidates.append(Projection(distance:distances[i]+size*f,offset:hypot(point.x-p.x,point.z-p.z),point:p))
        }
        guard let closest = candidates.min(by: { $0.offset < $1.offset }) else {
            let p = points[0];return Projection(distance:0,offset:hypot(point.x-p.x,point.z-p.z),point:p)
        }
        guard let previous else { return closest }
        return candidates.filter { $0.offset <= closest.offset+0.2 }.min {
            abs($0.distance-previous) < abs($1.distance-previous)
        } ?? closest
    }
    public func window(progress: Double, ahead: Double, behind: Double = 1) -> [ProbePoint] {
        guard progress.isFinite,ahead.isFinite,behind.isFinite,ahead > 0,behind >= 0 else { return [] }
        let from = max(0,min(length,progress)-behind),to = min(length,max(0,progress)+ahead)
        guard to > from else { return [point(at:from)] }
        var result = [point(at:from)]
        for i in points.indices where distances[i] > from+1e-6 && distances[i] < to-1e-6 {
            if hypot(result.last!.x-points[i].x,result.last!.z-points[i].z) > 1e-6 { result.append(points[i]) }
        }
        result.append(point(at:to));return result
    }
    public var turns: [Turn] {
        guard points.count >= 3 else { return [] }
        return (1..<points.count-1).compactMap { i in
            let a = points[i-1],b = points[i],c = points[i+1]
            let ix = b.x-a.x,iz = b.z-a.z,ox = c.x-b.x,oz = c.z-b.z
            guard hypot(ix,iz) >= 0.1,hypot(ox,oz) >= 0.1 else { return nil }
            let angle = atan2(ix*oz-iz*ox,ix*ox+iz*oz)
            guard abs(angle) >= .pi*35/180 else { return nil }
            return Turn(vertex:i,distance:distances[i],direction:abs(angle) >= .pi*150/180 ? .turnBack : angle < 0 ? .left : .right)
        }
    }
    /// Turns worth a floor arrow: vertices closer than `window` metres form one corner, whose net
    /// heading change (chord `window` m before to `window` m after) must reach `minimumDegrees`.
    /// A gentle bend, or a right angle drawn as two 45° vertices' worth of drift, is judged as a whole.
    public func sharpTurns(minimumDegrees: Double = 75, window: Double = 2.5) -> [Turn] {
        var groups: [[Turn]] = []
        for t in turns {
            if let last = groups.last?.last, t.distance-last.distance < window { groups[groups.count-1].append(t) } else { groups.append([t]) }
        }
        return groups.compactMap { g in
            let first = g[0].distance, last = g[g.count-1].distance
            let a = point(at:max(0,first-window)), b = point(at:first), c = point(at:last), d = point(at:min(length,last+window))
            let ix = b.x-a.x, iz = b.z-a.z, ox = d.x-c.x, oz = d.z-c.z
            guard hypot(ix,iz) >= 0.1, hypot(ox,oz) >= 0.1 else { return nil }
            let angle = atan2(ix*oz-iz*ox,ix*ox+iz*oz)
            guard abs(angle) >= .pi*minimumDegrees/180 else { return nil }
            let middle = g.min { abs($0.distance-(first+last)/2) < abs($1.distance-(first+last)/2) }!
            return Turn(vertex:middle.vertex,distance:middle.distance,direction:abs(angle) >= .pi*150/180 ? .turnBack : angle < 0 ? .left : .right)
        }
    }
    /// Keep the turn prompt until the user has entered its outgoing branch by one metre.
    public func nextTurn(progress: Double) -> Turn? { turns.first { $0.distance+1 > progress } }
}

/// A momentary approach, bad tracking, or a changing candidate cannot complete a navigation step.
public struct CampusStableNavigationGate {
    private var candidate: String?
    private var since: Double?
    private var previousTime: Double?
    public init() {}
    public mutating func reset() { candidate = nil; since = nil; previousTime = nil }
    public mutating func observe(key: String,time: Double,valid: Bool,hold: Double = 0.6) -> Bool {
        guard valid,time.isFinite,hold.isFinite,hold >= 0 else { reset();return false }
        if let previousTime,time < previousTime || time-previousTime > 0.5 { reset() }
        previousTime = time
        if candidate != key { candidate = key;since = time }
        return time-(since ?? time) >= hold
    }
}
