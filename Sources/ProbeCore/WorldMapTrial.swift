import Foundation

// Portable route data is independent of Apple's opaque world-map archive.
public struct PortableRoute: Codable, Equatable {
    public struct Node: Codable, Equatable {
        public var id: String
        public var name: String
        public var position: ProbePoint
    }
    public struct Edge: Codable, Equatable {
        public var from: String
        public var to: String
        public var length_m: Double
    }
    public var schema_version = 1
    public var coordinate_system = "route_local_m_y_up_forward_minus_z"
    public var route_id: String
    public var name: String
    public var kind: String
    public var forward_m: Double
    public var turn_m: Double
    public var nodes: [Node]
    public var edges: [Edge]

    public init(id: String, name: String, kind: RouteKind, forward: Double, turn: Double) {
        route_id = id; self.name = name; self.kind = kind.rawValue
        forward_m = forward; turn_m = turn
        let points = ProbeGeometry.route(kind, forward: forward, turn: turn)
        let routeNodes = points.enumerated().map { i, point in
            Node(id: "N\(i)", name: i == 0 ? "起点 A" : i == 1 && points.count == 3 ? "转角 B" : "终点", position: point)
        }
        nodes = routeNodes
        edges = (0..<(points.count - 1)).map { i in
            Edge(from: routeNodes[i].id, to: routeNodes[i + 1].id,
                 length_m: hypot(points[i+1].x - points[i].x, points[i+1].z - points[i].z))
        }
    }
    public func validate() throws {
        guard schema_version == 1, coordinate_system == "route_local_m_y_up_forward_minus_z",
              UUID(uuidString: route_id) != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let routeKind = RouteKind(rawValue: kind), forward_m.isFinite, turn_m.isFinite,
              (0.5...10).contains(forward_m), (0.5...10).contains(turn_m) else { throw WorldMapDataError.invalidRoute }
        let expected = ProbeGeometry.route(routeKind, forward: forward_m, turn: turn_m)
        guard nodes.count == expected.count, Set(nodes.map(\.id)).count == nodes.count,
              edges.count == nodes.count - 1 else { throw WorldMapDataError.invalidRoute }
        for (i, node) in nodes.enumerated() {
            guard node.id == "N\(i)", !node.name.isEmpty,
                  zip(node.position.array, expected[i].array).allSatisfy({ $0.0.isFinite && abs($0.0 - $0.1) < 1e-6 }) else {
                throw WorldMapDataError.invalidRoute
            }
        }
        for (i, edge) in edges.enumerated() {
            let distance = hypot(expected[i+1].x - expected[i].x, expected[i+1].z - expected[i].z)
            guard edge.from == nodes[i].id, edge.to == nodes[i+1].id, edge.length_m.isFinite,
                  abs(edge.length_m - distance) < 1e-6 else { throw WorldMapDataError.invalidRoute }
        }
    }
}

public enum WorldMapDataError: Error, LocalizedError {
    case invalidRoute, invalidMetadata, corruptedPackage, missingAnchor
    public var errorDescription: String? {
        switch self {
        case .invalidRoute: return "地图中的路线数据不完整或不受此版本支持。"
        case .invalidMetadata: return "地图坐标信息无效，不能恢复路线。"
        case .corruptedPackage: return "地图文件不完整或校验不符，已拒绝加载。"
        case .missingAnchor: return "环境地图没有包含这条路线的起点锚点，请重新保存。"
        }
    }
}

public enum RigidMatrix {
    public static func valid(_ m: [[Double]]) -> Bool {
        guard m.count == 4, m.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }),
              (0..<4).allSatisfy({ abs(m[3][$0] - ($0 == 3 ? 1 : 0)) < 1e-4 }) else { return false }
        for a in 0..<3 { for b in 0..<3 {
            let dot = (0..<3).reduce(0.0) { $0 + m[$1][a] * m[$1][b] }
            if abs(dot - (a == b ? 1 : 0)) > 0.02 { return false }
        } }
        let det = m[0][0] * (m[1][1]*m[2][2] - m[1][2]*m[2][1])
            - m[0][1] * (m[1][0]*m[2][2] - m[1][2]*m[2][0])
            + m[0][2] * (m[1][0]*m[2][1] - m[1][1]*m[2][0])
        return abs(det - 1) < 0.02
    }
}

// "restored" is an SDK result, not a physical accuracy measurement.
public struct WorldMapRestoreGate {
    public enum State: String { case waiting, restored, timedOut, failed }
    public private(set) var state: State = .waiting
    public private(set) var healthyFrames = 0
    public private(set) var healthySeconds = 0.0
    public private(set) var restoreSeconds: Double?
    private var healthySince:Double?
    private var previousSample:Double?
    private var previousPosition:[Double]?
    public let startTime: Double
    public let timeout: Double
    public init(startTime: Double, timeout: Double = 60) { self.startTime = startTime; self.timeout = timeout }
    @discardableResult public mutating func observe(now: Double, trackingNormal: Bool, anchorObserved: Bool,
                                                    anchorPresent: Bool,sampleTime:Double? = nil,position:[Double]? = nil) -> Bool {
        guard state == .waiting else { return false }
        let elapsed = now - startTime
        guard elapsed.isFinite, elapsed >= 0 else { return false }
        if elapsed >= timeout { state = .timedOut; return false }
        let sample = sampleTime ?? now
        guard sample.isFinite,position == nil || (position!.count == 3 && position!.allSatisfy(\.isFinite)) else { resetProgress();previousSample = nil;previousPosition = nil;return false }
        if let previousSample {
            let dt = sample-previousSample
            if dt <= 0 || dt > 0.25 { resetProgress() }
            if dt > 0,dt <= 0.25,let old = previousPosition,let position {
                let jump = sqrt(zip(old,position).reduce(0.0) { $0+pow($1.0-$1.1,2) })
                if jump > 0.5 { resetProgress() }
            }
        }
        previousSample = sample;previousPosition = position
        if trackingNormal && anchorObserved && anchorPresent {
            if healthySince == nil { healthySince = sample }
            healthyFrames += 1;healthySeconds = max(0,sample-healthySince!)
        } else { resetProgress() }
        // Measure continuous frame time after tracking becomes healthy, not time
        // spent waiting for relocalization or processing queued callbacks.
        guard healthySeconds >= 2, healthyFrames >= 12 else { return false }
        state = .restored; restoreSeconds = elapsed; return true
    }
    private mutating func resetProgress() { healthyFrames = 0;healthySeconds = 0;healthySince = nil }
    public mutating func fail() { if state == .waiting { state = .failed;resetProgress() } }
}
