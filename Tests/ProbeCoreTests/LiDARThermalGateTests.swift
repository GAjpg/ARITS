import XCTest
@testable import ProbeCore
final class LiDARThermalGateTests:XCTestCase {
    func testSeriousOnlyThrottlesAndDoesNotPause() {
        var gate = LiDARThermalCaptureGate(cooldownSeconds:15)
        gate.update(rawState:2,now:10)
        XCTAssertFalse(gate.paused);XCTAssertTrue(gate.throttled)
        gate.update(rawState:1,now:20);XCTAssertFalse(gate.throttled)
    }
    func testCoolingNeverAutomaticallyResumesAndRequiresValidTracking() {
        var gate = LiDARThermalCaptureGate(cooldownSeconds:15)
        gate.update(rawState:3,now:10);XCTAssertTrue(gate.paused)
        gate.update(rawState:2,now:20)
        XCTAssertFalse(gate.resume(now:34,trackingValid:true))
        XCTAssertFalse(gate.resume(now:36,trackingValid:false))
        XCTAssertTrue(gate.paused)
        XCTAssertTrue(gate.resume(now:36,trackingValid:true))
        XCTAssertFalse(gate.paused);XCTAssertTrue(gate.throttled)
    }
    func testReheatingRestartsCooldownAndCriticalCannotBeResumed() {
        var gate = LiDARThermalCaptureGate(cooldownSeconds:15)
        gate.update(rawState:3,now:0)
        XCTAssertFalse(gate.resume(now:100,trackingValid:true))
        gate.update(rawState:0,now:101)
        gate.update(rawState:3,now:110)
        gate.update(rawState:0,now:111)
        XCTAssertFalse(gate.resume(now:120,trackingValid:true))
        XCTAssertTrue(gate.resume(now:126,trackingValid:true))
    }
}
