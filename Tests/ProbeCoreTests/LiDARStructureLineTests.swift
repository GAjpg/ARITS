import XCTest
@testable import ProbeCore

final class LiDARStructureLineTests:XCTestCase {
    /// Floor plus two walls meeting at the origin: x = 0 (z 0…6) and z = 0 (x 0…8), with jitter.
    private func corner(dx:Double = 0) -> [ProbePoint] {
        var p = [ProbePoint](),i = 0.0
        for x in stride(from:0.0,to:8,by:0.1) { for z in stride(from:0.0,to:6,by:0.1) { p.append(ProbePoint(x+dx,-1.5,z)) } }
        for y in stride(from:-1.5,to:1.0,by:0.05) {
            for z in stride(from:0.0,to:6,by:0.05) { i += 1;p.append(ProbePoint(dx+sin(i)*0.01,y,z)) }
            for x in stride(from:0.0,to:8,by:0.05) { i += 1;p.append(ProbePoint(x+dx,y,cos(i)*0.01)) }
        }
        return p
    }
    func testWallFeetAndCornerAreFoundWithCentimetreAgreement() throws {
        let lines = LiDARStructureLines.extract(corner(),floorY:-1.5)
        let feet = lines.filter { $0.kind == "wall_foot" }
        XCTAssertTrue(feet.contains { abs($0.a.x) < 0.02 && abs($0.b.x) < 0.02 && $0.length > 5 },"\(feet)")
        XCTAssertTrue(feet.contains { abs($0.a.z) < 0.02 && abs($0.b.z) < 0.02 && $0.length > 7 },"\(feet)")
        let c = try XCTUnwrap(lines.first { $0.kind == "corner" })
        XCTAssertLessThan(hypot(c.a.x,c.a.z),0.05)
    }
    func testComparisonReportsShift() {
        let map = LiDARStructureLines.extract(corner(),floorY:-1.5),live = LiDARStructureLines.extract(corner(dx:0.05),floorY:-1.5)
        let c = LiDARStructureLines.compare(map:map,live:live)
        XCTAssertGreaterThanOrEqual(c.matched,1)
        // Only the x = 0 wall moves; the z = 0 wall slides along itself and stays at offset 0.
        let x0 = LiDARStructureLines.compare(map:map.filter { abs($0.a.x-$0.b.x) < 0.1 },live:live.filter { abs($0.a.x-$0.b.x) < 0.1 })
        XCTAssertEqual(x0.median_offset_m ?? 0,0.05,accuracy:0.015)
        XCTAssertEqual(LiDARStructureLines.compare(map:map,live:[]).matched,0)
    }
}
