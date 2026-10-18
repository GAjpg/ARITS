import XCTest
@testable import ProbeCore
final class LiDARCaptureBudgetTests:XCTestCase {
    func testFullCloudReportsNewCoverageButStillUpdatesExistingCells() {
        var cloud = [LiDARVoxelKey:ProbePoint]()
        let a = ProbePoint(0.01,0,0),b = ProbePoint(1,0,0),c = ProbePoint(4,0,0)
        let first = LiDARCaptureBudget.ingest([a,b],into:&cloud,limit:2)
        XCTAssertEqual(first.addedVoxels,2);XCTAssertEqual(first.rejectedSamples,0)
        let updated = ProbePoint(0.02,0,0)
        let batch = LiDARCaptureBudget.ingest([updated,c,c],into:&cloud,limit:2)
        XCTAssertEqual(cloud.count,2)
        XCTAssertEqual(cloud[LiDARVoxelKey(a,size:0.1)],updated)
        XCTAssertEqual(batch.rejectedSamples,2)
        XCTAssertEqual(batch.rejectedVoxels,1)
        XCTAssertEqual(batch.rejectedByBlock,["2,0":1])
        XCTAssertNil(cloud[LiDARVoxelKey(c,size:0.1)])
    }
}
