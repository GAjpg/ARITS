import Foundation

/// Shared presentation vocabulary. These values never assert a position or advance a leg.
public enum NavigationManeuver: String, Codable, CaseIterable, Sendable {
    case start, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn
    case enterIndoor, elevatorUp, elevatorDown, stairsUp, stairsDown, arrive, recover
    public var title: String {
        switch self {
        case .start: return "出发"
        case .straight: return "继续直行"
        case .slightLeft: return "稍向左转"
        case .left: return "左转"
        case .sharpLeft: return "向左急转"
        case .slightRight: return "稍向右转"
        case .right: return "右转"
        case .sharpRight: return "向右急转"
        case .uTurn: return "掉头"
        case .enterIndoor: return "进入室内"
        case .elevatorUp: return "乘电梯上楼"
        case .elevatorDown: return "乘电梯下楼"
        case .stairsUp: return "沿楼梯上楼"
        case .stairsDown: return "沿楼梯下楼"
        case .arrive: return "到达目的地"
        case .recover: return "缓慢观察周围"
        }
    }
}
public struct NavigationShellState: Equatable, Sendable {
    public enum Phase: String, Sendable { case preview, outdoor, indoorRecovery, indoor, transfer, arrived, paused }
    public struct Status: Equatable, Sendable {
        public enum Level: Sendable { case information, attention, error }
        public var title: String, detail: String?
        public var level: Level
        public init(_ title: String, detail: String? = nil, level: Level = .information) { self.title = title; self.detail = detail; self.level = level }
    }
    public var maneuver: NavigationManeuver
    public var maneuverDistanceM: Double?
    public var destination: String
    public var remainingDistanceM: Double?
    /// nil when an estimate is unavailable; never fabricate elevator waiting time.
    public var durationSeconds: Double?
    public var arrivalTime: Date?
    public var phase: Phase
    public var status: Status?
    public var floorLabel: String?
    public var actionTitle: String?
    /// Replaces the manoeuvre-derived instruction (e.g. "核对地上的路线").
    public var headline: String? = nil
    public init(maneuver: NavigationManeuver = .straight, maneuverDistanceM: Double? = nil, destination: String,
                remainingDistanceM: Double? = nil, durationSeconds: Double? = nil, arrivalTime: Date? = nil,
                phase: Phase, status: Status? = nil, floorLabel: String? = nil, actionTitle: String? = nil) {
        self.maneuver = maneuver; self.maneuverDistanceM = maneuverDistanceM; self.destination = destination
        self.remainingDistanceM = remainingDistanceM; self.durationSeconds = durationSeconds; self.arrivalTime = arrivalTime
        self.phase = phase; self.status = status; self.floorLabel = floorLabel; self.actionTitle = actionTitle
    }
    public var instruction: String {
        if let headline { return headline }
        guard maneuver != .recover, maneuver != .arrive, let d = maneuverDistanceM, d.isFinite, d > 3 else { return maneuver.title }
        return "\(Self.distance(d))后\(maneuver.title)"
    }
    public static func distance(_ metres: Double) -> String {
        guard metres.isFinite, metres >= 0 else { return "—" }
        if metres >= 1000 { return String(format:"%.1f 公里",metres/1000) }
        return String(format:"%.0f 米",metres)
    }
}

/// Metres and dimensionless fractions, shared by both renderers; no assumed map heading.
public struct NavigationArrowStyle: Equatable, Sendable {
    public var shaftWidthM: Double = 0.32
    public var headWidthM: Double = 0.72
    public var headLengthM: Double = 0.62
    public var outlineM: Double = 0.055
    public var spacingM: Double = 2.4
    public static let standard = NavigationArrowStyle()
    public init() {}
}

/// Arrival tolerances are independent of route rendering and never confirm a floor transfer.
public enum NavigationArrivalPolicy {
    public static let manualTransferRadiusM:Double = 15
    public static let transferRemainingM:Double = 5
    public static let transferOffsetM:Double = 5
    public static let outdoorRadiusM:Double = 15
    public static let outdoorAccuracyM:Double = 25
    private static func valid(_ value:Double) -> Bool { value.isFinite && value >= 0 }
    public static func offersTransferConfirmation(distanceM:Double) -> Bool {
        valid(distanceM) && distanceM <= manualTransferRadiusM
    }
    public static func reachedTransfer(remainingM:Double,offsetM:Double) -> Bool {
        valid(remainingM) && valid(offsetM) && remainingM <= transferRemainingM && offsetM <= transferOffsetM
    }
    public static func reachedOutdoorDoor(distanceM:Double,accuracyM:Double,preciseAuthorization:Bool,fresh:Bool) -> Bool {
        preciseAuthorization && fresh && valid(distanceM) && valid(accuracyM) && distanceM <= outdoorRadiusM && accuracyM <= outdoorAccuracyM
    }
}
