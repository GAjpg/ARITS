import XCTest
@testable import ProbeCore

final class LiDARQuickCorrectionTests:XCTestCase {
    private func wall(_ x0:Double,_ z0:Double,_ x1:Double,_ z1:Double) -> LiDARStructureLine {
        LiDARStructureLine(kind:"wall_foot",a:ProbePoint(x0,-1.5,z0),b:ProbePoint(x1,-1.5,z1),support:40,rms_m:0.02)
    }
    private func corner(_ x:Double,_ z:Double) -> LiDARStructureLine {
        LiDARStructureLine(kind:"corner",a:ProbePoint(x,-1.5,z),b:ProbePoint(x,0.5,z),support:40,rms_m:0.02)
    }
    /// Corridor along +x with walls at z = ±1, turning north at x = 20 (inner corner (19, 1)).
    private let map:[LiDARStructureLine] = [
        LiDARStructureLine(kind:"wall_foot",a:ProbePoint(0,-1.5,1),b:ProbePoint(19,-1.5,1),support:40,rms_m:0.02),
        LiDARStructureLine(kind:"wall_foot",a:ProbePoint(0,-1.5,-1),b:ProbePoint(21,-1.5,-1),support:40,rms_m:0.02),
        LiDARStructureLine(kind:"corner",a:ProbePoint(19,-1.5,1),b:ProbePoint(19,0.5,1),support:40,rms_m:0.02),
        LiDARStructureLine(kind:"corner",a:ProbePoint(21,-1.5,-1),b:ProbePoint(21,0.5,-1),support:40,rms_m:0.02)]
    private let p = ProbePoint(14,-1.5,0)
    /// What the person sees, drawn under a wrong alignment: rotated `deg` about p, then shifted.
    private func wrong(_ deg:Double,along:Double,lateral:Double) -> [[Double]] {
        let a = deg*Double.pi/180,c = cos(a),s = sin(a)
        return [[c,0,-s,p.x-c*p.x+s*p.z+along],[0,1,0,0],[s,0,c,p.z-s*p.x-c*p.z+lateral],[0,0,0,1]]
    }
    private func live(_ e:[[Double]],corner withCorner:Bool = true) -> [LiDARStructureLine] {
        ([wall(10,1,18,1),wall(10,-1,18,-1)]+(withCorner ? [corner(19,1)] : [])).map { $0.moved(e) }
    }
    func testCorridorAndCornerUndoTheMisalignment() throws {
        let e = wrong(3,along:0.4,lateral:0.5)
        let r = try XCTUnwrap(LiDARQuickCorrection.estimate(map:map,live:live(e),position:p,route:[ProbePoint(0,-1.5,0),ProbePoint(20,-1.5,0),ProbePoint(20,-1.5,10)]).result)
        XCTAssertEqual(r.kind,"corner");XCTAssertEqual(r.yaw_deg,-3,accuracy:0.3);XCTAssertEqual(r.corridor_width_m,2,accuracy:0.05)
        let fixed = CampusMapGeometry.multiply(r.correction,e)
        for q in [ProbePoint(19,-1.5,1),ProbePoint(12,-1.5,-1),ProbePoint(16,-1.5,1)] {
            let m = CampusMapGeometry.point([q.x,q.y,q.z],through:fixed)
            XCTAssertEqual(hypot(m[0]-q.x,m[2]-q.z),0,accuracy:0.08,"\(q)")
        }
    }
    func testWithoutATurnOnlyTheLateralAndYawAreFixed() throws {
        let e = wrong(-4,along:1.0,lateral:-0.6)
        let r = try XCTUnwrap(LiDARQuickCorrection.estimate(map:map,live:live(e,corner:false),position:p,route:[ProbePoint(0,-1.5,0),ProbePoint(30,-1.5,0)]).result)
        XCTAssertEqual(r.kind,"corridor");XCTAssertEqual(r.along_m,0);XCTAssertEqual(r.yaw_deg,4,accuracy:0.3)
        // The walls line up again; the along-corridor error remains (a corridor cannot show it).
        let m = CampusMapGeometry.point([16,-1.5,1],through:CampusMapGeometry.multiply(r.correction,e))
        XCTAssertEqual(m[2],1,accuracy:0.08)
    }
    func testNeedsRegularWallsOnBothSides() {
        let e = wrong(2,along:0,lateral:0.4)
        let oneSided = [wall(10,1,18,1)].map { $0.moved(e) }
        XCTAssertNil(LiDARQuickCorrection.estimate(map:map,live:oneSided+[wall(10,1.05,12,1.05)].map { $0.moved(e) },position:p,route:[]).result)
        // Ragged wall feet on one side (offsets 25 cm apart) are not "regular".
        let ragged = [wall(10,1,13,1),wall(13.5,1.25,17,1.25),wall(10,-1,18,-1)].map { $0.moved(e) }
        XCTAssertNil(LiDARQuickCorrection.estimate(map:map,live:ragged,position:p,route:[]).result)
    }
    func testRefusesLargeShiftsAndAmbiguousCorridors() {
        XCTAssertNil(LiDARQuickCorrection.estimate(map:map,live:live(wrong(0,along:0,lateral:1.9)),position:p,route:[]).result)
        XCTAssertNil(LiDARQuickCorrection.estimate(map:map,live:live(wrong(14,along:0,lateral:0)),position:p,route:[]).result)
        // A second, parallel corridor 0.8 m over: two different answers, so none.
        let doubled = map+[wall(0,1.8,19,1.8),wall(0,-0.2,21,-0.2)]
        XCTAssertEqual(LiDARQuickCorrection.estimate(map:doubled,live:live(wrong(0,along:0,lateral:0.3)),position:p,route:[]).reason,"ambiguous_map_corridor")
    }
}
