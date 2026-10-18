import XCTest
@testable import ProbeCore

final class LiDARMagneticTests:XCTestCase {
    /// Upright portrait phone at `p` whose optical axis has compass-style azimuth `a` (degrees).
    private func pose(_ a:Double,_ p:ProbePoint,pitch:Double = 0) -> [[Double]] {
        let r = a*Double.pi/180,c = cos(pitch),s = sin(pitch)
        let f = [sin(r)*c,s,-cos(r)*c]                         // forward
        let x = [0.0,-1.0,0.0]                                 // −X = device top = up (pitch kept small)
        let z = f.map { -$0 }
        let y = [z[1]*x[2]-z[2]*x[1],z[2]*x[0]-z[0]*x[2],z[0]*x[1]-z[1]*x[0]]
        return [[x[0],y[0],z[0],p.x],[x[1],y[1],z[1],p.y],[x[2],y[2],z[2],p.z],[0,0,0,1]]
    }
    private func yaw(_ deg:Double,_ t:ProbePoint) -> [[Double]] {
        let r = deg*Double.pi/180
        return [[cos(r),0,sin(r),t.x],[0,1,0,t.y],[-sin(r),0,cos(r),t.z],[0,0,0,1]]
    }
    private func inverse(_ m:[[Double]]) -> [[Double]] {
        let r = (0..<3).map { i in (0..<3).map { j in m[j][i] } }
        let t = (0..<3).map { i in -(0..<3).reduce(0) { $0+r[i][$1]*m[$1][3] } }
        return [r[0]+[t[0]],r[1]+[t[1]],r[2]+[t[2]],[0,0,0,1]]
    }
    private let fieldOffset = 173.0   // close to ±180 on purpose: the mean must wrap correctly
    /// Map walk along a corridor, turning around, with readings = map azimuth + field offset.
    private func mapSamples() -> [LiDARMagneticSample] {
        (0..<120).map { i in
            let a = (i < 60 ? 90.0 : -90.0)+sin(Double(i))*20,p = ProbePoint(Double(i%60)*0.2,0,0)
            return LiDARMagneticSample(timestamp:Double(i),heading:LiDARMagnetic.wrap(a+fieldOffset+sin(Double(i)*3)*3),accuracy:10,cameraToSession:pose(a,p))
        }
    }
    /// A query session whose coordinates relate to the map by `truth` (query → map).
    private func querySamples(_ truth:[[Double]]) -> [LiDARMagneticSample] {
        let back = inverse(truth)
        return (0..<20).map { i in
            let a = 40.0+Double(i)*4,mapPose = pose(a,ProbePoint(5+Double(i)*0.05,0,0))
            return LiDARMagneticSample(timestamp:Double(i),heading:LiDARMagnetic.wrap(a+fieldOffset+cos(Double(i))*2),accuracy:12,
                                       cameraToSession:CampusMapGeometry.multiply(back,mapPose))
        }
    }
    func testAzimuthNeedsUprightPhoneAndWrapsCorrectly() {
        XCTAssertEqual(LiDARMagnetic.cameraAzimuth(pose(30,ProbePoint(0,0,0)))!,30,accuracy:1e-9)
        XCTAssertNil(LiDARMagnetic.cameraAzimuth(pose(30,ProbePoint(0,0,0),pitch:-1.2)))   // looking at the floor
        let flat:[[Double]] = [[1,0,0,0],[0,0,1,0],[0,-1,0,0],[0,0,0,1]]
        XCTAssertNil(LiDARMagnetic.cameraAzimuth(flat))
        let o = LiDARMagnetic.offset([179,-179,178,-178])!
        XCTAssertEqual(abs(o.mean_deg),180,accuracy:0.6);XCTAssertLessThan(o.spread_deg,2.1)
    }
    func testCorrectTransformAgreesAndFlippedOneConflicts() {
        let reference = LiDARMagnetic.reference(mapSamples())
        XCTAssertFalse(reference.cells.isEmpty)
        let truth = yaw(70,ProbePoint(3,0.2,-2)),query = querySamples(truth)
        let good = LiDARMagnetic.check(query,transform:truth,reference:reference)
        XCTAssertEqual(good.status,"consistent");XCTAssertLessThan(abs(good.delta_deg!),8)
        // A 180° rival about the query camera centre: same place, facing the other way.
        let flip = CampusMapGeometry.multiply(truth,CampusMapGeometry.multiply(yaw(180,ProbePoint(0,0,0)),yaw(0,ProbePoint(0,0,0))))
        let bad = LiDARMagnetic.check(query,transform:flip,reference:reference)
        XCTAssertEqual(bad.status,"conflict");XCTAssertGreaterThan(abs(bad.delta_deg!),170)
    }
    func testScreenOnlyActsOnOppositeYawAndNeverRemovesEveryCandidate() {
        let reference = LiDARMagnetic.reference(mapSamples())
        let truth = yaw(70,ProbePoint(3,0.2,-2)),query = querySamples(truth)
        let flip = CampusMapGeometry.multiply(truth,yaw(180,ProbePoint(0,0,0)))
        let applied = LiDARMagnetic.screen(candidateTransforms:[flip,truth],decisionReasons:["opposite_yaw_mode"],query:query,reference:reference)
        XCTAssertTrue(applied.applied);XCTAssertEqual(applied.suppressed,[0]);XCTAssertEqual(applied.remaining,1)
        let other = LiDARMagnetic.screen(candidateTransforms:[flip,truth],decisionReasons:["below_gate"],query:query,reference:reference)
        XCTAssertFalse(other.applied);XCTAssertTrue(other.suppressed.isEmpty)
        let allBad = LiDARMagnetic.screen(candidateTransforms:[flip],decisionReasons:["opposite_yaw_mode"],query:query,reference:reference)
        XCTAssertFalse(allBad.applied);XCTAssertEqual(allBad.reason,"no_candidate_consistent")
    }
    func testYawPriorRecoversTransformYawAndGlobalFallback() throws {
        let reference = LiDARMagnetic.reference(mapSamples())
        let truth = yaw(70,ProbePoint(3,0.2,-2)),query = querySamples(truth)
        let prior = try XCTUnwrap(LiDARMagnetic.yawPrior(query:query,reference:reference))
        XCTAssertEqual(prior.scope,"global")
        XCTAssertLessThan(abs(LiDARMagnetic.wrap(prior.center-atan2(truth[0][2],truth[0][0])*180/Double.pi)),6)
        // Far from every cell: the local check falls back to the whole-map offset and says so.
        let far = CampusMapGeometry.multiply(yaw(0,ProbePoint(60,0,60)),truth)
        let check = LiDARMagnetic.check(query,transform:far,reference:reference)
        XCTAssertEqual(check.reference_scope,"global");XCTAssertEqual(check.status,"consistent")
        // A map whose cells disagree has no global offset.
        var split = reference;split.cells[0].offset.mean_deg += 90
        XCTAssertNil(split.global())
    }
    func testPhoneHeldTooLowIsReportedAsSuch() {
        let reference = LiDARMagnetic.reference(mapSamples())
        let truth = yaw(10,ProbePoint(0,0,0))
        let low = (0..<20).map { i in LiDARMagneticSample(timestamp:Double(i),heading:0,accuracy:10,cameraToSession:pose(Double(i),ProbePoint(5,0,0),pitch:-1.2)) }
        XCTAssertEqual(LiDARMagnetic.check(low,transform:truth,reference:reference).reason,"phone_not_upright")
    }
    func testThinOrNoisyEvidenceIsUnavailable() {
        let truth = yaw(10,ProbePoint(0,0,0))
        XCTAssertEqual(LiDARMagnetic.check(querySamples(truth),transform:truth,reference:nil).status,"unavailable")
        let reference = LiDARMagnetic.reference(mapSamples())
        var poor = querySamples(truth);for i in poor.indices { poor[i].heading_accuracy_deg = 40 }
        XCTAssertEqual(LiDARMagnetic.check(poor,transform:truth,reference:reference).reason,"too_few_query_samples")
        var scattered = querySamples(truth);for i in scattered.indices { scattered[i].magnetic_heading_deg = Double(i*37%360) }
        XCTAssertEqual(LiDARMagnetic.check(scattered,transform:truth,reference:reference).reason,"query_spread")
        let far = yaw(70,ProbePoint(200,0,200))
        XCTAssertEqual(LiDARMagnetic.check(querySamples(truth),transform:far,reference:reference).reference_scope,"global")
        var split = reference;split.cells[0].offset.mean_deg += 90
        XCTAssertEqual(LiDARMagnetic.check(querySamples(truth),transform:far,reference:split).reason,"no_reference_near_candidate")
    }
}

final class LiDAROverlayCheckTests:XCTestCase {
    func testDepthComparisonSeparatesContradictionFromOcclusion() {
        XCTAssertEqual(LiDAROverlayCheck.classify(expectedDepth:2.05,measuredDepth:2.0,confidence:2),.aligned)
        XCTAssertEqual(LiDAROverlayCheck.classify(expectedDepth:1.5,measuredDepth:2.0,confidence:2),.contradicted)
        XCTAssertEqual(LiDAROverlayCheck.classify(expectedDepth:2.6,measuredDepth:2.0,confidence:2),.occluded)
        XCTAssertEqual(LiDAROverlayCheck.classify(expectedDepth:2.0,measuredDepth:2.0,confidence:0),.unknown)
        XCTAssertEqual(LiDAROverlayCheck.classify(expectedDepth:2.0,measuredDepth:nil,confidence:2),.unknown)
        XCTAssertEqual(LiDAROverlayCheck.classify(expectedDepth:4.1,measuredDepth:4.0,confidence:1),.aligned)   // 3% at range
        var s = LiDAROverlayCheck.Summary()
        for _ in 0..<45 { s.add(.aligned) };for _ in 0..<4 { s.add(.contradicted) };s.add(.occluded)
        XCTAssertNil(s.alignedFraction)
        s.add(.contradicted);XCTAssertEqual(s.alignedFraction!,0.9,accuracy:1e-9)
    }
}

final class LiDARMagneticLogTests:XCTestCase {
    func testJSONLParsingKeepsValidPairsOfOneSession() throws {
        let pose:[[Double]] = [[0,0,1,0],[-1,0,0,0],[0,-1,0,0],[0,0,0,1]]
        func line(_ s:String,_ valid:Bool,_ pair:Bool) -> String {
            String(data:try! JSONSerialization.data(withJSONObject:["ar_session_id":s,"measurement_valid":valid,"camera_pairing_valid":pair,
                "magnetic_heading_deg":10.0,"heading_accuracy_deg":12.0,"camera_to_session":pose,"timestamp":1.0]),encoding:.utf8)!
        }
        let data = Data([line("A",true,true),line("A",false,true),line("A",true,false),line("B",true,true),"{broken"].joined(separator:"\n").utf8)
        XCTAssertEqual(LiDARMagnetic.samples(jsonl:data).count,2)
        XCTAssertEqual(LiDARMagnetic.samples(jsonl:data,sessionID:"A").count,1)
        let moved = LiDARMagnetic.moved(LiDARMagnetic.samples(jsonl:data,sessionID:"A"),by:[[1,0,0,5],[0,1,0,0],[0,0,1,0],[0,0,0,1]])
        XCTAssertEqual(moved[0].camera_to_session[0][3],5)
    }
    func testWallBlocksPoolingAcrossIt() {
        var points = [ProbePoint]()
        for x in stride(from:-3.0,through:3.0,by:0.1) { for z in stride(from:-3.0,through:3.0,by:0.1) { points.append(ProbePoint(x,-1.5,z)) } }
        for z in stride(from:-3.0,through:3.0,by:0.05) { for y in stride(from:-1.5,through:1.0,by:0.05) { points.append(ProbePoint(0.02,y,z)) } }
        let grid = LiDARStructureGrid(points:points)
        XCTAssertTrue(grid.crosses(from:ProbePoint(-1,-1.5,0),to:ProbePoint(1,-1.5,0)))
        XCTAssertFalse(grid.crosses(from:ProbePoint(-1,-1.5,-1),to:ProbePoint(-1,-1.5,1)))
        let off = LiDARMagnetic.Offset(mean_deg:10,spread_deg:2,p90_deg:4,count:20),other = LiDARMagnetic.Offset(mean_deg:80,spread_deg:2,p90_deg:4,count:20)
        let reference = LiDARMagnetic.Reference(cell_m:3,cells:[.init(x:-1.5,z:0,offset:off),.init(x:1.5,z:0,offset:other)])
        XCTAssertEqual(reference.local(at:ProbePoint(-1,-1.5,0),structure:grid)!.mean_deg,10,accuracy:1e-6)
        XCTAssertNil(reference.local(at:ProbePoint(-1,-1.5,0)))            // without walls the two sides disagree: refused, not averaged
    }
    func testOneCellOneVoteForLocalAndGlobal() {
        let big = LiDARMagnetic.Offset(mean_deg:0,spread_deg:0,p90_deg:0,count:100),odd = LiDARMagnetic.Offset(mean_deg:90,spread_deg:0,p90_deg:0,count:5)
        let r = LiDARMagnetic.Reference(cell_m:3,cells:[.init(x:0,z:0,offset:big),.init(x:3,z:0,offset:odd)])
        XCTAssertNil(r.local(at:ProbePoint(1.5,0,0)))
        XCTAssertNil(r.global())
        let ok = LiDARMagnetic.Reference(cell_m:3,cells:[.init(x:0,z:0,offset:big),.init(x:30,z:0,offset:.init(mean_deg:6,spread_deg:2,p90_deg:3,count:5))])
        XCTAssertEqual(ok.global()!.mean_deg,3,accuracy:0.01)
    }
}

final class LiDARRefreshPolicyTests:XCTestCase {
    private func result(_ t:[[Double]],status:String = "candidate_requires_review",reasons:[String] = [],complete:Bool = true) -> LiDARLocalizationResult {
        let c = LiDARLocalizationCandidate(transform_query_to_map:t,overlap:0.8,structural_overlap:0.8,rmse_m:0.05,geometry_score:0.8,quality_gate:true,mode_id:nil,free_space:nil)
        var r = LiDARLocalizationResult(session_id:"s",status:status,reason:"",candidates:[c],registration_seconds:0,map_points:1000,query_points:500,structural_constraint_ratio:0.3)
        r.search_complete = complete;r.decision_reasons = reasons;return r
    }
    private func pose(_ yawDeg:Double,_ x:Double,_ z:Double) -> [[Double]] {
        let r = yawDeg*Double.pi/180;return [[cos(r),0,sin(r),x],[0,1,0,0],[-sin(r),0,cos(r),z],[0,0,0,1]]
    }
    private func fit(_ before:Int,_ after:Int,common:Int = 200,cb:Int = 220,ca:Int = 210) -> LiDARAgreementPair {
        LiDARAgreementPair(common:common,comparableBefore:cb,comparableAfter:ca,alignedBefore:before,alignedAfter:after)
    }
    func testKeepMicroLargeLostIgnore() {
        let cur = pose(0,0,0),cam = ProbePoint(1,0,1)
        let d = { (r:LiDARLocalizationResult,g:LiDARAgreementPair?,blocked:Bool,so:Double) in LiDARRefreshPolicy.decide(r,current:cur,camera:cam,compass:nil,agreement:g,blocked:blocked,microSoFar:so) }
        XCTAssertEqual(d(result(pose(0.5,0.06,0)),fit(150,150),false,0).action,"keep")
        XCTAssertEqual(d(result(pose(0.5,0.12,0)),fit(150,150),false,0).action,"ignore")               // 12 cm: no longer "keep", but no better fit
        XCTAssertEqual(d(result(pose(2,0.3,0)),fit(120,160),false,0).action,"micro")
        XCTAssertEqual(d(result(pose(2,0.3,0)),fit(120,160,ca:150),false,0).reason,"no_better_agreement")   // evidence shrank
        XCTAssertEqual(d(result(pose(2,0.3,0)),fit(120,160,common:30),false,0).reason,"no_better_agreement") // too few common points
        XCTAssertEqual(d(result(pose(2,0.3,0)),fit(120,160),false,1.4).action,"large")                     // micro budget used up
        XCTAssertEqual(d(result(pose(0,1.2,0)),fit(120,130),false,0).action,"large")
        XCTAssertEqual(d(result(pose(0,1.2,0)),fit(130,120),false,0).action,"ignore")
        XCTAssertEqual(d(result(pose(0,4,0)),fit(130,120),true,0).action,"large")                         // blocked route: offered per setting
        XCTAssertEqual(d(result(pose(0,4,0),status:"ambiguous",reasons:["multiple_modes"]),fit(10,190),true,0).action,"lost")
        XCTAssertEqual(d(result(pose(0,4,0),status:"ambiguous",reasons:["multiple_modes"]),fit(10,190),false,0).action,"ignore")
        XCTAssertEqual(d(result(pose(0,1,0),reasons:["along_axis_spread"]),fit(10,190),false,0).reason,"not_unique_or_incomplete")
        XCTAssertEqual(d(result(pose(0,1,0),complete:false),fit(10,190),false,0).reason,"not_unique_or_incomplete")
        let conflict = LiDARMagnetic.Check(status:"conflict",delta_deg:170,query:nil,map:nil,reason:nil)
        XCTAssertEqual(LiDARRefreshPolicy.decide(result(pose(2,0.3,0)),current:cur,camera:cam,compass:conflict,agreement:fit(100,190),blocked:true).action,"lost")
    }
}
