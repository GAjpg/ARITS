import XCTest
@testable import ProbeCore

final class CampusRouteGeometryTests:XCTestCase {
    func testWindowFollowsDistanceAroundCornerAndRetainsCorner() throws {
        let route = try CampusRouteGeometry(points:[ProbePoint(0,-1,0),ProbePoint(0,-1,-10),ProbePoint(-10,-1,-10)])
        let window = route.window(progress:8,ahead:6,behind:1)
        XCTAssertEqual(window,[ProbePoint(0,-1,-7),ProbePoint(0,-1,-10),ProbePoint(-4,-1,-10)])
        XCTAssertEqual(try CampusRouteGeometry(points:window).length,7,accuracy:1e-8)
    }
    func testWindowEndClampsToDestinationAndInterpolatesFloorHeight() throws {
        let route = try CampusRouteGeometry(points:[ProbePoint(0,-1,0),ProbePoint(10,-1.1,0)])
        let window = route.window(progress:8,ahead:20,behind:0)
        XCTAssertEqual(window.count,2);XCTAssertEqual(window[0].y,-1.08,accuracy:1e-8)
        XCTAssertEqual(window.last,ProbePoint(10,-1.1,0))
    }
    func testReverseNavigationExchangesLeftAndRight() throws {
        let points = [ProbePoint(0,0,0),ProbePoint(0,0,-10),ProbePoint(-10,0,-10)]
        XCTAssertEqual(try CampusRouteGeometry(points:points).turns.first?.direction,.left)
        XCTAssertEqual(try CampusRouteGeometry(points:points.reversed()).turns.first?.direction,.right)
    }
    func testNearbyTurnDoesNotAdvanceUntilOutgoingBranchEntered() throws {
        let route = try CampusRouteGeometry(points:[ProbePoint(0,0,0),ProbePoint(0,0,-10),ProbePoint(-10,0,-10)])
        for p in [ProbePoint(0,0,-6),ProbePoint(0.4,0,-9.7),ProbePoint(-0.5,0,-10)] {
            let position = try route.project(p)
            XCTAssertNotNil(route.nextTurn(progress:position.distance))
        }
        XCTAssertNil(route.nextTurn(progress:try route.project(ProbePoint(-1.1,0,-10)).distance))
        XCTAssertNotNil(route.nextTurn(progress:try route.project(ProbePoint(0,0,-9)).distance)) // Walking back restores the prompt.
    }
    func testOverlappingLaterLegCannotStealPosition() throws {
        let route = try CampusRouteGeometry(points:[ProbePoint(0,0,0),ProbePoint(0,0,-20),ProbePoint(1,0,-20),ProbePoint(1,0,0)])
        let result = try route.project(ProbePoint(0.9,0,-4),near:4)
        XCTAssertEqual(result.distance,4,accuracy:1e-8);XCTAssertEqual(result.offset,0.9,accuracy:1e-8)
    }
    func testOffRouteOffsetIsMeasuredRatherThanHiddenByProjection() throws {
        let route = try CampusRouteGeometry(points:[ProbePoint(0,0,0),ProbePoint(0,0,-20)])
        XCTAssertEqual(try route.project(ProbePoint(4,0,-8)).offset,4,accuracy:1e-8)
    }
    func testDegenerateRouteAndInvalidInputs() throws {
        let route = try CampusRouteGeometry(points:[ProbePoint(1,0,2),ProbePoint(1,0,2)])
        XCTAssertEqual(route.length,0);XCTAssertTrue(route.turns.isEmpty)
        XCTAssertEqual(try route.project(ProbePoint(1,0,3)).offset,1)
        XCTAssertThrowsError(try CampusRouteGeometry(points:[]))
        XCTAssertThrowsError(try CampusRouteGeometry(points:[ProbePoint(.nan,0,0)]))
        XCTAssertTrue(route.window(progress:.nan,ahead:20).isEmpty)
    }
    func testUnstableCandidateAndLostTrackingCannotAdvance() {
        var gate = CampusStableNavigationGate()
        XCTAssertFalse(gate.observe(key:"turn",time:0,valid:true))
        XCTAssertFalse(gate.observe(key:"end",time:0.2,valid:true))
        XCTAssertFalse(gate.observe(key:"turn",time:0.4,valid:true))
        XCTAssertFalse(gate.observe(key:"turn",time:0.6,valid:false))
        XCTAssertFalse(gate.observe(key:"turn",time:0.8,valid:true))
        XCTAssertFalse(gate.observe(key:"turn",time:1,valid:true))
        XCTAssertFalse(gate.observe(key:"turn",time:1.2,valid:true))
        XCTAssertTrue(gate.observe(key:"turn",time:1.41,valid:true))
    }
    func testBackgroundGapCannotCountAsStableArrivalTime() {
        var gate = CampusStableNavigationGate()
        XCTAssertFalse(gate.observe(key:"destination",time:0,valid:true,hold:1))
        XCTAssertFalse(gate.observe(key:"destination",time:2,valid:true,hold:1))
        for t in [2.2,2.4,2.6,2.8] { XCTAssertFalse(gate.observe(key:"destination",time:t,valid:true,hold:1)) }
        XCTAssertTrue(gate.observe(key:"destination",time:3.01,valid:true,hold:1))
    }
    func testReturnBearingIsShortAndUsesNetworkFloorInsteadOfPhoneHeight() {
        let arrow = CampusRouteAccess.directionArrow(from:ProbePoint(0,1.6,0),to:ProbePoint(6,-0.1,8))
        XCTAssertEqual(arrow.count,2)
        XCTAssertEqual(arrow[0].y,-0.1);XCTAssertEqual(arrow[1].y,-0.1)
        XCTAssertEqual(hypot(arrow[1].x,arrow[1].z),1.5,accuracy:1e-8)
        XCTAssertEqual(arrow[1].x/arrow[1].z,6.0/8,accuracy:1e-8)
        XCTAssertTrue(CampusRouteAccess.directionArrow(from:ProbePoint(0,1.6,0),to:ProbePoint(0,0,0)).isEmpty)
        XCTAssertTrue(CampusRouteAccess.directionArrow(from:ProbePoint(.nan,0,0),to:ProbePoint(1,0,0)).isEmpty)
    }
    func testMovingAwayFromZeroLengthPlanRevokesArrivalEvenOnSameEdge() {
        let start = CampusLocatedPosition(position:.init(regionID:"region",edgeID:"edge",fraction:1),point:[10,0,0],distance_m:6)
        var current = start;current.position.fraction = 0.7;current.point = [7,0,0];current.distance_m = 0
        XCTAssertFalse(CampusRouteAccess.shouldReplan(closest:start,plannedStart:start,edgeIDs:[],routeProjection:nil))
        XCTAssertTrue(CampusRouteAccess.shouldReplan(closest:current,plannedStart:start,edgeIDs:[],routeProjection:nil))
    }
    func testACloserBranchOrLaterLoopRequiresReplanningBeforeAdvancingOldCues() {
        let location = CampusLocatedPosition(position:.init(regionID:"region",edgeID:"other",fraction:0.5),point:[2,0,8],distance_m:0.1)
        XCTAssertTrue(CampusRouteAccess.shouldReplan(closest:location,plannedStart:nil,edgeIDs:["first"],routeProjection:ProbePoint(2,0,0)))
        XCTAssertFalse(CampusRouteAccess.shouldReplan(closest:location,plannedStart:nil,edgeIDs:["other"],routeProjection:ProbePoint(2,0,8)))
        XCTAssertTrue(CampusRouteAccess.shouldReplan(closest:location,plannedStart:nil,edgeIDs:["other"],routeProjection:ProbePoint(2,0,0)))
    }
    func testSharpTurnsJudgeWholeCornersAndDropGentleBends() throws {
        // A 45° bend: a turn vertex, but no corner arrow.
        let gentle = try CampusRouteGeometry(points:[ProbePoint(0,0,0),ProbePoint(0,0,-10),ProbePoint(7,0,-17)])
        XCTAssertEqual(gentle.turns.count,1);XCTAssertTrue(gentle.sharpTurns().isEmpty)
        // A right angle cut into two 45° vertices one metre apart counts as one corner.
        let corner = try CampusRouteGeometry(points:[ProbePoint(0,0,0),ProbePoint(0,0,-10),ProbePoint(0.7,0,-10.7),ProbePoint(10,0,-10.7)])
        let sharp = corner.sharpTurns()
        XCTAssertEqual(sharp.count,1);XCTAssertEqual(sharp.first?.direction,corner.turns.first?.direction)
    }
}
