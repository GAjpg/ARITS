import Foundation

public struct PhotoGroundGeometry {
    public var width: Double
    public var height: Double
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var cameraToSession: [[Double]]
    public var planeToSession: [[Double]]
    public var boundaryXZ: [[Double]]

    public init(width: Double, height: Double, fx: Double, fy: Double, cx: Double, cy: Double,
                cameraToSession: [[Double]], planeToSession: [[Double]], boundaryXZ: [[Double]]) {
        self.width = width; self.height = height; self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.cameraToSession = cameraToSession; self.planeToSession = planeToSession; self.boundaryXZ = boundaryXZ
    }
}

public enum PhotoGeometryError: Error, LocalizedError {
    case invalidPixel, invalidGeometry, shallowRay, behindCamera, tooFar, outsideFloor, pointsTooClose, pointsTooFar
    public var errorDescription: String? {
        switch self {
        case .invalidPixel: return "请点在照片内。"
        case .invalidGeometry: return "拍摄时的相机或地面信息不可用，请重新扫描并拍照。"
        case .shallowRay: return "这个点太靠近地平线，请选近处的地面。"
        case .behindCamera: return "这个点无法与所选地面相交，请确认点在地板上。"
        case .tooFar: return "所选地面点超过 8 米，请走近后重新拍照。"
        case .outsideFloor: return "这个点超出拍摄时已扫描的地面，请先扫描 A、B 周围再拍照。"
        case .pointsTooClose: return "两个地面点至少相隔 0.5 米，请重新选择方向点。"
        case .pointsTooFar: return "两个地面点间隔超过 10 米，请在短路线范围内重新选点。"
        }
    }
}

public enum PhotoGeometry {
    // Raw sensor image -> clockwise-rotated portrait preview, in normalized coordinates.
    public static func portraitPoint(raw: [Double], width: Double, height: Double) -> [Double] {
        [1 - raw[1] / height, raw[0] / width]
    }
    public static func rawPoint(portrait: [Double], width: Double, height: Double) -> [Double] {
        [portrait[1] * width, (1 - portrait[0]) * height]
    }

    public static func floorPoint(rawPixel: [Double], geometry g: PhotoGroundGeometry) throws -> ProbePoint {
        guard rawPixel.count == 2, rawPixel.allSatisfy({ $0.isFinite }),
              rawPixel[0] >= 0, rawPixel[0] < g.width, rawPixel[1] >= 0, rawPixel[1] < g.height else {
            throw PhotoGeometryError.invalidPixel
        }
        let camera = g.cameraToSession, plane = g.planeToSession
        guard matrixValid(camera), matrixValid(plane), g.fx.isFinite, g.fy.isFinite,
              g.fx > 0, g.fy > 0, g.cx.isFinite, g.cy.isFinite,
              g.boundaryXZ.count >= 3, g.boundaryXZ.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite } }) else {
            throw PhotoGeometryError.invalidGeometry
        }
        let origin = (0..<3).map { camera[$0][3] }
        let localRay = [(rawPixel[0] - g.cx) / g.fx, -(rawPixel[1] - g.cy) / g.fy, -1.0]
        let ray = (0..<3).map { r in (0..<3).reduce(0.0) { $0 + camera[r][$1] * localRay[$1] } }
        let normal = (0..<3).map { plane[$0][1] }
        let planeOrigin = (0..<3).map { plane[$0][3] }
        let normalLength = sqrt(dot(normal, normal)), rayLength = sqrt(dot(ray, ray))
        guard normalLength > 0.99, normal[1] / normalLength > 0.98 else { throw PhotoGeometryError.invalidGeometry }
        let denominator = dot(ray, normal)
        guard abs(denominator) / (normalLength * rayLength) >= 0.08 else { throw PhotoGeometryError.shallowRay }
        let parameter = dot(zip(planeOrigin, origin).map { $0.0 - $0.1 }, normal) / denominator
        guard parameter > 0 else { throw PhotoGeometryError.behindCamera }
        guard parameter * rayLength <= 8 else { throw PhotoGeometryError.tooFar }
        let point = zip(origin, ray).map { $0.0 + $0.1 * parameter }
        let delta = zip(point, planeOrigin).map { $0.0 - $0.1 }
        let local = (0..<3).map { c in (0..<3).reduce(0.0) { $0 + plane[$1][c] * delta[$1] } }
        guard contains([local[0], local[2]], polygon: g.boundaryXZ) else { throw PhotoGeometryError.outsideFloor }
        return ProbePoint(point[0], point[1], point[2])
    }

    public static func horizontalDistance(_ a: ProbePoint, _ b: ProbePoint) -> Double {
        hypot(a.x - b.x, a.z - b.z)
    }

    // A narrow edge tolerance prevents floating-point noise from rejecting a boundary point.
    private static func contains(_ p: [Double], polygon: [[Double]]) -> Bool {
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let dx = b[0] - a[0], dy = b[1] - a[1], length2 = dx * dx + dy * dy
            if length2 > 0 {
                let t = min(1, max(0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / length2))
                if hypot(p[0] - a[0] - t * dx, p[1] - a[1] - t * dy) <= 0.03 { return true }
            }
            if (a[1] > p[1]) != (b[1] > p[1]),
               p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0] { inside.toggle() }
        }
        return inside
    }
    private static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    private static func matrixValid(_ m: [[Double]]) -> Bool {
        m.count == 4 && m.allSatisfy { $0.count == 4 && $0.allSatisfy { $0.isFinite } }
    }
}

public struct PhotoRequestIdentity: Equatable {
    public var session: String
    public var run: String
    public var trackingEpoch: Int
    public var routeRevision: Int
    public init(session: String, run: String, trackingEpoch: Int, routeRevision: Int) {
        self.session = session; self.run = run; self.trackingEpoch = trackingEpoch; self.routeRevision = routeRevision
    }
}

public enum PhotoRequestGuard {
    public static func rejection(captured: PhotoRequestIdentity, current: PhotoRequestIdentity,
                                 captureTime: Double, currentTime: Double, trackingNormal: Bool, paused: Bool) -> String? {
        if paused { return "校准已暂停，保留已有路线。" }
        if captured.session != current.session || captured.run != current.run { return "会话或记录已改变，请重新拍照。" }
        if captured.trackingEpoch != current.trackingEpoch { return "拍照后发生过跟踪中断，请重新拍照。" }
        if captured.routeRevision != current.routeRevision { return "拍照后路线已改变，请重新拍照。" }
        if !trackingNormal { return "当前 AR 跟踪不可靠，请恢复后重新拍照。" }
        if !captureTime.isFinite || !currentTime.isFinite || currentTime < captureTime || currentTime - captureTime > 90 {
            return "照片已过期，请重新拍照。"
        }
        return nil
    }
}
