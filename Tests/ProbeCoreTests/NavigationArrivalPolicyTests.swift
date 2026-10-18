import XCTest
@testable import ProbeCore

final class NavigationArrivalPolicyTests:XCTestCase {
    func testTransferManualConfirmationIncludes15MetreBoundary() {
        XCTAssertTrue(NavigationArrivalPolicy.offersTransferConfirmation(distanceM:0))
        XCTAssertTrue(NavigationArrivalPolicy.offersTransferConfirmation(distanceM:15))
        XCTAssertFalse(NavigationArrivalPolicy.offersTransferConfirmation(distanceM:15.01))
        for distance in [-1,Double.nan,Double.infinity] {
            XCTAssertFalse(NavigationArrivalPolicy.offersTransferConfirmation(distanceM:distance))
        }
    }
    func testManualOfferDoesNotImplyAutomaticTransferArrival() {
        XCTAssertTrue(NavigationArrivalPolicy.offersTransferConfirmation(distanceM:12))
        XCTAssertFalse(NavigationArrivalPolicy.reachedTransfer(remainingM:12,offsetM:1))
        XCTAssertTrue(NavigationArrivalPolicy.reachedTransfer(remainingM:5,offsetM:5))
        XCTAssertFalse(NavigationArrivalPolicy.reachedTransfer(remainingM:5.01,offsetM:1))
        XCTAssertFalse(NavigationArrivalPolicy.reachedTransfer(remainingM:1,offsetM:5.01))
        XCTAssertFalse(NavigationArrivalPolicy.reachedTransfer(remainingM:.nan,offsetM:1))
        XCTAssertFalse(NavigationArrivalPolicy.reachedTransfer(remainingM:1,offsetM:-1))
    }
    func testOutdoorDoorArrivalWidensDistanceButRequiresUsableLiveLocation() {
        XCTAssertTrue(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:15,accuracyM:25,preciseAuthorization:true,fresh:true))
        XCTAssertFalse(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:15.01,accuracyM:6,preciseAuthorization:true,fresh:true))
        XCTAssertFalse(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:8,accuracyM:25.01,preciseAuthorization:true,fresh:true))
        XCTAssertFalse(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:8,accuracyM:6,preciseAuthorization:false,fresh:true))
        XCTAssertFalse(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:8,accuracyM:6,preciseAuthorization:true,fresh:false))
        XCTAssertFalse(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:8,accuracyM:.nan,preciseAuthorization:true,fresh:true))
        XCTAssertFalse(NavigationArrivalPolicy.reachedOutdoorDoor(distanceM:-1,accuracyM:6,preciseAuthorization:true,fresh:true))
    }
}
