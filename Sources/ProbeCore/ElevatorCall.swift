import Foundation

public enum ElevatorCallDirection: String, Codable, Sendable {
    case up, down
    public var command: String { rawValue.uppercased() }
}
public enum ElevatorTraversal: Sendable { case aToB, bToA }

public struct ElevatorCallTarget {
    public let linkID: String, groupID: String, floorID: String, wireFloor: String
    public let direction: ElevatorCallDirection
    public let device: LiDARCampusBindings.ElevatorDevice
    public func context(planRevision: Int) -> ElevatorCallContext {
        .init(planRevision:planRevision,linkID:linkID,groupID:groupID,floorID:floorID,
              boardID:device.id,wireFloor:wireFloor,direction:direction)
    }
}
public enum ElevatorCallPlanning {
    public static func direction(for link: LiDARMapLink, traversal: ElevatorTraversal,
                                 placements: [String:LiDARMapPlacement], catalog: LiDARCampusCatalog) -> ElevatorCallDirection? {
        guard link.enabled,link.kind == .elevator else { return nil }
        if case .bToA = traversal, !link.bidirectional { return nil }
        let from = traversal == .aToB ? link.a : link.b, to = traversal == .aToB ? link.b : link.a
        guard let a = placements[from.map_id],let b = placements[to.map_id],a.map_id == from.map_id,b.map_id == to.map_id,
              a.building_id == b.building_id,let building = catalog.building(a.building_id),
              let start = building.floors.first(where: { $0.id == a.floor_id })?.level,
              let end = building.floors.first(where: { $0.id == b.floor_id })?.level,start != end else { return nil }
        return end > start ? .up : .down
    }
    /// No binding, missing level, unsupported direction/name, or wrong building means no call target.
    public static func target(for link: LiDARMapLink, traversal: ElevatorTraversal,
                              placements: [String:LiDARMapPlacement], catalog: LiDARCampusCatalog,
                              bindings: LiDARCampusBindings) -> ElevatorCallTarget? {
        let from = traversal == .aToB ? link.a : link.b
        guard let direction = direction(for:link,traversal:traversal,placements:placements,catalog:catalog),
              let group = link.group_id,!group.isEmpty,let p = placements[from.map_id],
              let device = bindings.device(group:group,floor:p.floor_id),device.building_id == p.building_id,
              device.directions.contains(where: { $0.rawValue == direction.rawValue }),
              let floor = wireFloor(advertisedName:device.peripheral_name) else { return nil }
        return .init(linkID:link.id,groupID:group,floorID:p.floor_id,wireFloor:floor,direction:direction,device:device)
    }
    /// Firmware v5 uses ELEV-2F / ELEV-3F; do not infer a catalog UUID from RSSI or a floor name.
    public static func wireFloor(advertisedName: String) -> String? {
        guard advertisedName.hasPrefix("ELEV-") else { return nil }
        let value = String(advertisedName.dropFirst(5))
        guard !value.isEmpty,value.utf8.count <= 20,value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return value
    }
}
public struct ElevatorCallContext: Equatable, Sendable {
    public let planRevision: Int
    public let linkID: String, groupID: String, floorID: String, boardID: String, wireFloor: String
    public let direction: ElevatorCallDirection
    public init(planRevision:Int,linkID:String,groupID:String,floorID:String,boardID:String,wireFloor:String,direction:ElevatorCallDirection) {
        self.planRevision = planRevision;self.linkID = linkID;self.groupID = groupID;self.floorID = floorID
        self.boardID = boardID;self.wireFloor = wireFloor;self.direction = direction
    }
    public var valid: Bool {
        planRevision >= 0 && [linkID,groupID,floorID,boardID,wireFloor].allSatisfy { !$0.isEmpty && $0.utf8.count <= 160 }
        && !wireFloor.contains("|") && !wireFloor.contains("\n")
    }
}
public struct ElevatorCallRequest: Equatable, Sendable {
    public let id: UUID
    public let context: ElevatorCallContext
    /// Monotonic seconds in the caller's clock; never mix Date and AR timestamps.
    public let sentAt: TimeInterval
}
public enum ElevatorCallPhase: String, Sendable { case idle, pending, confirmed, unconfirmed, failed }
public enum ElevatorCallReason: String, Sendable {
    case timedOut, contextChanged, disconnected, writeFailed, bluetoothUnavailable, stopped, deviceExpired
}
public enum ElevatorReceiptSource: Sendable { case notification, initialRead }

/// One machine per bound board, no retries or radio side effects.
/// A matching OK is device feedback, not elevator arrival. Firmware has no request id and broadcasts
/// receipts: a matching same-direction action by another client cannot be distinguished on this wire protocol.
public struct ElevatorCallMachine: Sendable {
    public let boardID: String
    public let timeout: TimeInterval
    public private(set) var phase: ElevatorCallPhase = .idle
    public private(set) var request: ElevatorCallRequest?
    public private(set) var reason: ElevatorCallReason?
    public init(boardID: String, timeout: TimeInterval = 3) {
        self.boardID = boardID;self.timeout = timeout.isFinite && timeout > 0 ? timeout : 3
    }
    @discardableResult public mutating func begin(context: ElevatorCallContext, sentAt: TimeInterval) -> Bool {
        guard phase != .pending,context.valid,context.boardID == boardID,sentAt.isFinite,sentAt >= 0 else { return false }
        request = .init(id:UUID(),context:context,sentAt:sentAt);phase = .pending;reason = nil;return true
    }
    @discardableResult public mutating func expire(now: TimeInterval) -> Bool {
        guard phase == .pending,let request,now.isFinite,now-request.sentAt >= timeout else { return false }
        phase = .unconfirmed;reason = .timedOut;return true
    }
    /// Historical reads and receipts outside the exact context/window never confirm a request.
    @discardableResult public mutating func receive(_ text: String, receivedAt: TimeInterval,
                                                    context: ElevatorCallContext, source: ElevatorReceiptSource) -> Bool {
        guard source == .notification,phase == .pending,let request,request.context == context,
              receivedAt.isFinite,receivedAt > request.sentAt else { return false }
        if expire(now:receivedAt) { return false }
        guard text.utf8.count <= 80 else { return false }
        let fields = text.split(separator:"|",omittingEmptySubsequences:false)
        guard fields.count == 2,fields[0] == Substring(context.wireFloor),fields[1] == Substring("OK:"+context.direction.command) else { return false }
        phase = .confirmed;reason = nil;return true
    }
    /// Only invalidates local state; a command already sent to a physical button cannot be withdrawn.
    @discardableResult public mutating func invalidate(ifContextDiffersFrom context: ElevatorCallContext?) -> Bool {
        guard let request,request.context != context else { return false }
        phase = .unconfirmed;reason = .contextChanged;return true
    }
    public mutating func fail(_ reason: ElevatorCallReason) {
        guard phase == .pending else { return };phase = .failed;self.reason = reason
    }
}
