import XCTest
@testable import ProbeCore

final class CampusFeaturePointTests:XCTestCase {
    private let region = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let fixtureHash = String(repeating:"a",count:64)
    private func cloud(_ points:[ProbePoint],saved:Bool = true) -> CampusFeaturePointCloud {
        CampusFeaturePointCloud(regionID:region,date:"2026-10-11T10:00:00Z",source:saved ? .savedMap : .sessionPreview,mapHash:saved ? fixtureHash : nil,points:points)
    }
    func testDensityProjectsDifferentHeightsAndFloorsNegativeCoordinates() throws {
        let c = cloud([ProbePoint(-0.1,0,-0.1),ProbePoint(-0.9,3,-0.7),ProbePoint(0,10,0),ProbePoint(1,1,0)])
        try c.validate(regionID:region,mapHash:fixtureHash)
        XCTAssertEqual(c.density(),[.init(x:-1,z:-1,count:2),.init(x:0,z:0,count:1),.init(x:1,z:0,count:1)])
        XCTAssertEqual(c.count(x:-0.5,z:-0.5),2)
        XCTAssertEqual(c.count(x:0.999,z:0),1)
        XCTAssertEqual(c.count(x:2,z:0),0)
        XCTAssertTrue(c.density(cellSize:0).isEmpty)
    }
    func testCloudRejectsWrongRegionStaleMapAndInvalidCoordinates() throws {
        let valid = cloud([ProbePoint(1,2,3)])
        XCTAssertThrowsError(try valid.validate(regionID:UUID().uuidString,mapHash:fixtureHash))
        XCTAssertThrowsError(try valid.validate(regionID:region,mapHash:String(repeating:"b",count:64)))
        XCTAssertThrowsError(try cloud([ProbePoint(.nan,0,0)]).validate(regionID:region))
        XCTAssertThrowsError(try cloud([ProbePoint(0,.infinity,0)]).validate(regionID:region))
        XCTAssertThrowsError(try cloud([ProbePoint(20_000,0,0)]).validate(regionID:region))
        var malformed = valid;malformed.source_point_count = 0
        XCTAssertThrowsError(try malformed.validate(regionID:region))
    }
    func testSavedAndUnsavedCloudsRoundTripAndRemainDistinct() throws {
        for saved in [true,false] {
            let c = cloud([ProbePoint(1,2,3)],saved:saved)
            let decoded = try JSONDecoder().decode(CampusFeaturePointCloud.self,from:JSONEncoder().encode(c))
            XCTAssertEqual(decoded,c);try decoded.validate(regionID:region)
        }
        var preview = cloud([],saved:false);preview.world_map_sha256 = fixtureHash
        XCTAssertThrowsError(try preview.validate(regionID:region))
    }
    func testLargeCloudSamplingPreservesExtentAndOriginalCount() throws {
        let points = (0..<50_123).map { ProbePoint(Double($0)/10,0,0) }
        let c = cloud(points);try c.validate(regionID:region)
        XCTAssertEqual(c.source_point_count,50_123);XCTAssertEqual(c.points.count,50_000)
        XCTAssertEqual(c.points.first,points.first);XCTAssertEqual(c.points.last,points.last)
    }
    func testCandidateLayersTransformToCommonFrameAndVisibilityChangesDensity() throws {
        let a = cloud([ProbePoint(0.1,0,0.1),ProbePoint(2.1,0,0.1)])
        var transform = CampusMapGeometry.identity;transform[0][3] = 10
        let b = CampusFeatureDistribution.transformed(cloud([ProbePoint(-9.8,1,0.1)]),by:transform)
        let layers = [CampusFeatureLayer(id:"a",name:"原图",cloud:a),CampusFeatureLayer(id:"b",name:"补采",cloud:b)]
        let all = try XCTUnwrap(CampusFeatureDistribution.combined(layers));try all.validate(regionID:region)
        XCTAssertEqual(all.source,.candidateOverlay);XCTAssertEqual(all.count(x:0,z:0),2)
        XCTAssertEqual(CampusFeatureDistribution.combined([layers[0]])?.count(x:0,z:0),1)
        XCTAssertNil(CampusFeatureDistribution.combined([]))
        var foreign = a;foreign.region_id = UUID().uuidString
        XCTAssertNil(CampusFeatureDistribution.combined([layers[0],CampusFeatureLayer(id:"c",name:"其他区域",cloud:foreign)]))
        XCTAssertEqual(a.points,[ProbePoint(0.1,0,0.1),ProbePoint(2.1,0,0.1)])
    }
    func testLayerSamplingBoundsWorkAndIncludesEachMap() throws {
        let layers = (0..<3).map { index in CampusFeatureLayer(id:String(index),name:String(index),cloud:cloud((0..<30_000).map { ProbePoint(Double($0)/10,Double(index),0) })) }
        let all = try XCTUnwrap(CampusFeatureDistribution.combined(layers))
        XCTAssertEqual(all.source_point_count,90_000);XCTAssertEqual(all.points.count,50_000)
        XCTAssertEqual(Set(all.points.map(\.y)),[0,1,2])
        XCTAssertEqual(CampusFeatureDistribution.sampledLayers(layers,budget:2).reduce(0) { $0+$1.cloud.points.count },2)
        XCTAssertTrue(CampusFeatureDistribution.sampledLayers(layers,budget:0).isEmpty)
    }
    func testFeatureDerivativeTravelsWithFullAndRegionBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:source.appendingPathComponent("references"),withIntermediateDirectories:true)
        var g = CampusGraph(name:"合成点云测试")
        let floor = CampusFloor(name:"一楼");g.floors = [floor]
        var r = CampusRegion(floorID:floor.id,name:"测试区域");r.map_saved = true;g.regions = [r]
        for x in [0.0,2] {
            let n = CampusNode(floorID:floor.id,name:"测试节点",kind:.waypoint);g.nodes.append(n)
            g.bindings.append(CampusBinding(regionID:r.id,nodeID:n.id,anchorID:UUID().uuidString,transform:[[1,0,0,x],[0,1,0,0],[0,0,1,0],[0,0,0,1]]))
            try Data("synthetic-jpeg".utf8).write(to:source.appendingPathComponent("references/\(n.id).jpg"))
            try CampusFiles.encode(["synthetic_fixture":true],to:source.appendingPathComponent("references/\(n.id).json"))
        }
        try g.connect(g.nodes[0].id,g.nodes[1].id,regionID:r.id)
        let map = source.appendingPathComponent("environment.arworldmap")
        try Data("synthetic-map-not-for-AR".utf8).write(to:map)
        let c = CampusFeaturePointCloud(regionID:r.id,date:"2026-10-11T10:00:00Z",source:.savedMap,mapHash:try CampusFiles.hash(map),points:[ProbePoint(0,1,0),ProbePoint(2,2,1)])
        try CampusFiles.encode(c,to:source.appendingPathComponent("feature-points.json"))
        try CampusFiles.encode(CampusRegionSnapshot(graph:g,region:r,sessionID:UUID().uuidString,features:2),to:source.appendingPathComponent("region.json"))
        try CampusFiles.manifest(source)
        let library = CampusLibrary(root:root.appendingPathComponent("library"))
        let saved = try library.save(g,regionSource:source,regionID:r.id)
        for single in [false,true] {
            let zip = root.appendingPathComponent(single ? "region.zip" : "full.zip")
            try library.export(saved.building_id,destination:zip,regionID:single ? r.id : nil)
            let imported = try library.importBackup(zip)
            let directory = try library.regionDirectory(buildingID:imported.building_id,regionID:r.id)
            let decoded = try JSONDecoder().decode(CampusFeaturePointCloud.self,from:Data(contentsOf:directory.appendingPathComponent("feature-points.json")))
            XCTAssertEqual(decoded,c);try decoded.validate(regionID:r.id,mapHash:CampusFiles.hash(directory.appendingPathComponent("environment.arworldmap")))
        }
    }
}
