import Foundation

public struct ProbePoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }
    public var array: [Double] { [x, y, z] }
}

public enum RouteKind: String, CaseIterable {
    case arrow, straight, left, right
    public var title: String {
        switch self {
        case .arrow: return "单箭头"
        case .straight: return "直行"
        case .left: return "左转"
        case .right: return "右转"
        }
    }
}

public enum ProbeGeometry {
    // ARKit right-handed coordinates: +X right, +Y up, -Z forward.
    public static func route(_ kind: RouteKind, forward: Double, turn: Double) -> [ProbePoint] {
        let f = min(10, max(0.5, forward))
        let t = min(10, max(0.5, turn))
        let start = ProbePoint(0, 0, 0)
        switch kind {
        case .arrow: return [start, ProbePoint(0, 0, -0.7)]
        case .straight: return [start, ProbePoint(0, 0, -f)]
        case .left: return [start, ProbePoint(0, 0, -f), ProbePoint(-t, 0, -f)]
        case .right: return [start, ProbePoint(0, 0, -f), ProbePoint(t, 0, -f)]
        }
    }

    public static func project(world: [Double], cameraToWorld: [[Double]],
                               fx: Double, fy: Double, cx: Double, cy: Double) -> [Double]? {
        guard world.count == 3, cameraToWorld.count == 4,
              cameraToWorld.allSatisfy({ $0.count == 4 }) else { return nil }
        // Inverse rigid transform, then OpenGL camera -> image optical coordinates.
        let d = (0..<3).map { world[$0] - cameraToWorld[$0][3] }
        let local = (0..<3).map { c in (0..<3).reduce(0.0) { $0 + cameraToWorld[$1][c] * d[$1] } }
        let depth = -local[2]
        guard depth > 0.001 else { return nil }
        return [fx * local[0] / depth + cx, fy * (-local[1]) / depth + cy]
    }
}

public final class BoundedTaskGate {
    private let lock = NSLock()
    private let capacity: Int
    private var count = 0
    private var rejected = 0
    public init(capacity: Int) { self.capacity = max(1, capacity) }
    public func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < capacity else { rejected += 1; return false }
        count += 1
        return true
    }
    public func release() {
        lock.lock(); defer { lock.unlock() }
        count = max(0, count - 1)
    }
    public var rejectedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return rejected
    }
}

public struct IntervalStatistics {
    private var values: [Double] = []
    public private(set) var samples = 0
    public private(set) var longFrames = 0
    public init() {}
    public mutating func add(seconds: Double) {
        guard seconds > 0, seconds.isFinite, (seconds * 1000).isFinite else { return }
        samples += 1
        if seconds > 0.1 { longFrames += 1 }
        if values.count == 20_000 { values.removeFirst() }
        values.append(seconds * 1000)
    }
    public var summary: [String: Double] {
        guard !values.isEmpty else { return [:] }
        let sorted = values.sorted()
        func percentile(_ p: Double) -> Double { sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
        return ["samples": Double(samples), "window_samples": Double(values.count),
                "p50_ms": percentile(0.50), "p95_ms": percentile(0.95),
                "long_frames_over_100ms": Double(longFrames)]
    }
}
