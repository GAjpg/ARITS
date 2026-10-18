import XCTest
@testable import ProbeCore

final class PhotoGeometryTests: XCTestCase {
    private let identity = [[1.0,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    private var geometry: PhotoGroundGeometry {
        var camera = identity; camera[1][3] = 1.5
        return PhotoGroundGeometry(width: 1920, height: 1440, fx: 1000, fy: 1000, cx: 960, cy: 720,
            cameraToSession: camera, planeToSession: identity,
            boundaryXZ: [[-2,-6],[2,-6],[2,0],[-2,0]])
    }
    func testPortraitRotationIsInvertibleAndNotMirrored() {
        XCTAssertEqual(PhotoGeometry.portraitPoint(raw: [0,0], width: 1920, height: 1440), [1,0])
        XCTAssertEqual(PhotoGeometry.portraitPoint(raw: [1920,1440], width: 1920, height: 1440), [0,1])
        let raw = [200.0, 1100]
        let portrait = PhotoGeometry.portraitPoint(raw: raw, width: 1920, height: 1440)
        let restored = PhotoGeometry.rawPoint(portrait: portrait, width: 1920, height: 1440)
        XCTAssertEqual(restored[0], raw[0], accuracy: 1e-9); XCTAssertEqual(restored[1], raw[1], accuracy: 1e-9)
    }
    func testFloorBindingMatchesIndependentlySpecifiedGroundPoint() throws {
        let point = try PhotoGeometry.floorPoint(rawPixel: [960,1220], geometry: geometry)
        XCTAssertEqual(point.x, 0, accuracy: 1e-9); XCTAssertEqual(point.y, 0, accuracy: 1e-9)
        XCTAssertEqual(point.z, -3, accuracy: 1e-9)
    }
    func testTranslatedRotatedCameraAndPlaneUseCaptureCoordinates() throws {
        var g = geometry
        g.cameraToSession = [[0,0,1,5],[0,1,0,1.5],[-1,0,0,2],[0,0,0,1]]
        g.planeToSession = [[0,0,1,5],[0,1,0,0],[-1,0,0,2],[0,0,0,1]]
        let point = try PhotoGeometry.floorPoint(rawPixel: [960,1220], geometry: g)
        XCTAssertEqual(point.x, 2, accuracy: 1e-9); XCTAssertEqual(point.y, 0, accuracy: 1e-9)
        XCTAssertEqual(point.z, 2, accuracy: 1e-9)
    }
    func testUnsafeRaysAndOutsideScannedFloorAreRejected() {
        XCTAssertThrowsError(try PhotoGeometry.floorPoint(rawPixel: [960,720], geometry: geometry))
        XCTAssertThrowsError(try PhotoGeometry.floorPoint(rawPixel: [960,400], geometry: geometry))
        XCTAssertThrowsError(try PhotoGeometry.floorPoint(rawPixel: [960,850], geometry: geometry))
        var small = geometry; small.boundaryXZ = [[-1,-2],[1,-2],[1,0],[-1,0]]
        XCTAssertThrowsError(try PhotoGeometry.floorPoint(rawPixel: [960,1220], geometry: small))
        XCTAssertThrowsError(try PhotoGeometry.floorPoint(rawPixel: [1920,1220], geometry: geometry))
    }
    func testReprojectionReturnsOriginalSensorPixel() throws {
        let raw = [1160.0,1220]
        let ground = try PhotoGeometry.floorPoint(rawPixel: raw, geometry: geometry)
        let pixel = try XCTUnwrap(ProbeGeometry.project(world: ground.array, cameraToWorld: geometry.cameraToSession,
            fx: 1000, fy: 1000, cx: 960, cy: 720))
        XCTAssertEqual(pixel[0], raw[0], accuracy: 1e-9); XCTAssertEqual(pixel[1], raw[1], accuracy: 1e-9)
    }
    func testDelayedResultRequiresSameUninterruptedSessionAndRoute() {
        let context = PhotoRequestIdentity(session: "a", run: "one", trackingEpoch: 2, routeRevision: 3)
        func rejected(_ current: PhotoRequestIdentity, time: Double = 13, tracking: Bool = true, paused: Bool = false) -> Bool {
            PhotoRequestGuard.rejection(captured: context, current: current, captureTime: 10,
                currentTime: time, trackingNormal: tracking, paused: paused) != nil
        }
        XCTAssertFalse(rejected(context))
        var changed = context; changed.session = "b"; XCTAssertTrue(rejected(changed))
        changed = context; changed.run = "two"; XCTAssertTrue(rejected(changed))
        changed = context; changed.trackingEpoch += 1; XCTAssertTrue(rejected(changed))
        changed = context; changed.routeRevision += 1; XCTAssertTrue(rejected(changed))
        XCTAssertTrue(rejected(context, time: 101)); XCTAssertTrue(rejected(context, time: 9))
        XCTAssertTrue(rejected(context, tracking: false)); XCTAssertTrue(rejected(context, paused: true))
    }
}
