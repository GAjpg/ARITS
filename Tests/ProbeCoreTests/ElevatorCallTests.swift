import XCTest
@testable import ProbeCore

final class ElevatorCallTests:XCTestCase {
    private func context(revision:Int = 1,direction:ElevatorCallDirection = .up,floor:String = "2F",board:String = "board") -> ElevatorCallContext {
        .init(planRevision:revision,linkID:"link",groupID:"shaft",floorID:"floor-2",boardID:board,wireFloor:floor,direction:direction)
    }
    func testDirectionAndDeviceFollowCurrentLegRatherThanFinalDestination() throws {
        let f2 = LiDARCampusCatalog.Floor(name:"2F",level:2,id:"f2"),f3 = LiDARCampusCatalog.Floor(name:"3F",level:3,id:"f3")
        let building = LiDARCampusCatalog.Building(name:"B",floors:[f2,f3],id:"B"),catalog = LiDARCampusCatalog(buildings:[building])
        let placements = try ["a":LiDARMapPlacement(mapID:"a",building:building,floor:f2,region:"a"),"b":LiDARMapPlacement(mapID:"b",building:building,floor:f3,region:"b")]
        var link = LiDARMapLink(kind:.elevator,a:.init(map:"a",node:"lift"),b:.init(map:"b",node:"lift"),groupID:"shaft")
        XCTAssertEqual(ElevatorCallPlanning.direction(for:link,traversal:.aToB,placements:placements,catalog:catalog),.up)
        XCTAssertEqual(ElevatorCallPlanning.direction(for:link,traversal:.bToA,placements:placements,catalog:catalog),.down)
        var bindings = LiDARCampusBindings()
        XCTAssertNil(ElevatorCallPlanning.target(for:link,traversal:.aToB,placements:placements,catalog:catalog,bindings:bindings))
        bindings.elevator_devices = [.init(groupID:"shaft",buildingID:"B",floorID:"f2",peripheralName:"ELEV-2F",directions:[.up],id:"board")]
        let target = try XCTUnwrap(ElevatorCallPlanning.target(for:link,traversal:.aToB,placements:placements,catalog:catalog,bindings:bindings))
        XCTAssertEqual(target.floorID,"f2");XCTAssertEqual(target.wireFloor,"2F");XCTAssertEqual(target.context(planRevision:7).planRevision,7)
        var unknown = catalog;unknown.buildings[0].floors[0].level = nil
        XCTAssertNil(ElevatorCallPlanning.direction(for:link,traversal:.aToB,placements:placements,catalog:unknown))
        unknown.buildings[0].floors[0].level = 3
        XCTAssertNil(ElevatorCallPlanning.direction(for:link,traversal:.aToB,placements:placements,catalog:unknown))
        link.bidirectional = false
        XCTAssertNil(ElevatorCallPlanning.direction(for:link,traversal:.bToA,placements:placements,catalog:catalog))
        link.kind = .stairs
        XCTAssertNil(ElevatorCallPlanning.direction(for:link,traversal:.aToB,placements:placements,catalog:catalog))
    }
    func testOnePendingAndExactNotificationOnly() {
        var machine = ElevatorCallMachine(boardID:"board");let c = context()
        XCTAssertTrue(machine.begin(context:c,sentAt:10))
        XCTAssertFalse(machine.begin(context:context(direction:.down),sentAt:10.1))
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:10.1,context:c,source:.initialRead))
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:9.9,context:c,source:.notification))
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:10,context:c,source:.notification))
        for message in ["3F|OK:UP","2F|OK:DOWN","2F|READY","2F|OK:UP|junk","2F|OK:UP\n"] {
            XCTAssertFalse(machine.receive(message,receivedAt:11,context:c,source:.notification))
        }
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:11,context:context(revision:0),source:.notification))
        XCTAssertEqual(machine.phase,.pending)
        XCTAssertTrue(machine.receive("2F|OK:UP",receivedAt:11.3,context:c,source:.notification))
        XCTAssertEqual(machine.phase,.confirmed)
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:11.4,context:c,source:.notification))
    }
    func testTimeoutDoesNotRetryOrMarkFailedAndLateAckIgnored() {
        var machine = ElevatorCallMachine(boardID:"board");let c = context()
        XCTAssertTrue(machine.begin(context:c,sentAt:10));let id = machine.request?.id
        XCTAssertFalse(machine.expire(now:12.99));XCTAssertTrue(machine.expire(now:13))
        XCTAssertEqual(machine.phase,.unconfirmed);XCTAssertEqual(machine.reason,.timedOut);XCTAssertEqual(machine.request?.id,id)
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:13.1,context:c,source:.notification))
        var exact = ElevatorCallMachine(boardID:"board")
        XCTAssertTrue(exact.begin(context:c,sentAt:10))
        XCTAssertFalse(exact.receive("2F|OK:UP",receivedAt:13,context:c,source:.notification));XCTAssertEqual(exact.phase,.unconfirmed)
    }
    func testContextChangeInvalidatesLocallyAndOtherBoardCannotBegin() {
        var machine = ElevatorCallMachine(boardID:"board");let c = context()
        XCTAssertFalse(machine.begin(context:context(board:"other"),sentAt:1))
        XCTAssertTrue(machine.begin(context:c,sentAt:1));XCTAssertFalse(machine.invalidate(ifContextDiffersFrom:c))
        XCTAssertTrue(machine.invalidate(ifContextDiffersFrom:context(revision:2)))
        XCTAssertEqual(machine.reason,.contextChanged);XCTAssertEqual(machine.phase,.unconfirmed)
        XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:2,context:c,source:.notification))
        XCTAssertTrue(machine.begin(context:context(revision:2),sentAt:3));machine.fail(.writeFailed)
        XCTAssertEqual(machine.phase,.failed);XCTAssertFalse(machine.receive("2F|OK:UP",receivedAt:4,context:context(revision:2),source:.notification))
    }
    func testMissingIdentityAndInvalidTimesCannotSend() {
        var machine = ElevatorCallMachine(boardID:"board")
        for now in [Double.nan,.infinity,-1] { XCTAssertFalse(machine.begin(context:context(),sentAt:now)) }
        XCTAssertFalse(machine.begin(context:context(revision:-1),sentAt:1))
        XCTAssertNil(ElevatorCallPlanning.wireFloor(advertisedName:"Nearby Elevator"))
        XCTAssertNil(ElevatorCallPlanning.wireFloor(advertisedName:"ELEV-2F|OK"))
    }
}
