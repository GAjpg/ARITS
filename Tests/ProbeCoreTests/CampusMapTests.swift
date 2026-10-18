import XCTest
@testable import ProbeCore

final class CampusMapTests:XCTestCase {
    private func pose(_ p:[Double]) -> [[Double]] { var m = CampusMapGeometry.identity;for i in 0..<3 { m[i][3] = p[i] };return m }
    private func fixture() throws -> CampusGraph {
        var g = CampusGraph(name:"多图测试楼")
        let floor = CampusFloor(name:"一楼");g.floors = [floor]
        var a = CampusRegion(floorID:floor.id,name:"西小图"),b = CampusRegion(floorID:floor.id,name:"东小图")
        a.map_saved = true;b.map_saved = true;g.regions = [a,b]
        g.nodes = (0..<4).map { CampusNode(floorID:floor.id,name:"N\($0)",kind:.junction) }
        let global = [[-4.0,0,0],[0,0,0],[4,0,0],[10,0,0]]
        // East's independent frame is rotated 90 degrees and translated.
        let eastToWest:[[Double]] = [[0,0,-1,20],[0,1,0,2],[1,0,0,10],[0,0,0,1]]
        for i in [0,1,2] { g.bindings.append(CampusBinding(regionID:a.id,nodeID:g.nodes[i].id,anchorID:UUID().uuidString,transform:pose(global[i]))) }
        for i in [1,2,3] { g.bindings.append(CampusBinding(regionID:b.id,nodeID:g.nodes[i].id,anchorID:UUID().uuidString,transform:pose(CampusMapGeometry.point(global[i],through:CampusMapGeometry.inverse(eastToWest))))) }
        try g.connect(g.nodes[0].id,g.nodes[1].id,regionID:a.id)
        try g.connect(g.nodes[1].id,g.nodes[2].id,regionID:a.id)
        try g.connect(g.nodes[2].id,g.nodes[3].id,regionID:b.id)
        return g
    }
    private func temp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("campus-maps-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:u,withIntermediateDirectories:true);return u
    }
    private func source(_ g:CampusGraph,region:CampusRegion,in root:URL,bindings:[CampusBinding]? = nil,payload:String = "map-original") throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir.appendingPathComponent("references"),withIntermediateDirectories:true)
        var snapshot = CampusRegionSnapshot(graph:g,region:region,sessionID:UUID().uuidString,features:100)
        if let bindings { snapshot.bindings = bindings }
        try CampusFiles.encode(snapshot,to:dir.appendingPathComponent("region.json"))
        try Data(payload.utf8).write(to:dir.appendingPathComponent("environment.arworldmap"))
        for b in snapshot.bindings {
            try Data("photo".utf8).write(to:dir.appendingPathComponent("references/"+b.node_id+".jpg"))
            try CampusFiles.encode(["fixture":true],to:dir.appendingPathComponent("references/"+b.node_id+".json"))
        };try CampusFiles.manifest(dir);return dir
    }
    private func candidate(_ g:CampusGraph,_ r:CampusRegion,name:String = "测试候选",transform:[[Double]] = CampusMapGeometry.identity) -> CampusMapCandidate {
        CampusMapCandidate(regionID:r.id,name:name,date:g.updated_utc,transform:transform)
    }
    func testTwoSharedNodesRecoverYawTranslationAndVerticalOffset() throws {
        let g = try fixture(),transforms = CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[0].id)
        XCTAssertEqual(transforms.count,2)
        let mapped = CampusMapGeometry.navigationGraph(g,transforms:transforms)
        for index in [1,2] {
            let p = mapped.binding(nodeID:g.nodes[index].id,regionID:g.regions[1].id)!.position
            XCTAssertEqual(p[0],Double((index-1)*4),accuracy:1e-8);XCTAssertEqual(p[1],0,accuracy:1e-8);XCTAssertEqual(p[2],0,accuracy:1e-8)
        }
        XCTAssertEqual(mapped.binding(nodeID:g.nodes[3].id,regionID:g.regions[1].id)!.position[0],10,accuracy:1e-8)
        XCTAssertEqual(g.binding(nodeID:g.nodes[3].id,regionID:g.regions[1].id)!.position,[ -10, -2, 10 ])
    }
    func testSingleSharedNodeAndClosePairsCannotEnableContinuousTracking() throws {
        var g = try fixture();g.bindings.removeAll { $0.region_id == g.regions[1].id && $0.node_id == g.nodes[1].id }
        XCTAssertEqual(CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[0].id).count,1)
        let r = g.regions[0],n = g.nodes[0]
        let a = CampusBinding(regionID:r.id,nodeID:n.id,anchorID:UUID().uuidString,transform:pose([0,0,0]))
        let b = CampusBinding(regionID:r.id,nodeID:g.nodes[1].id,anchorID:UUID().uuidString,transform:pose([0.2,0,0]))
        XCTAssertThrowsError(try CampusMapGeometry.fit(source:[a,b],target:[a,b]))
    }
    func testThirdSharedNodeRejectsIncorrectBindingAndDoesNotSilentlyLink() throws {
        var g = try fixture()
        let r = g.regions[1],n = g.nodes[0]
        g.bindings.append(CampusBinding(regionID:r.id,nodeID:n.id,anchorID:UUID().uuidString,transform:pose([90,0,90])))
        XCTAssertEqual(CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[0].id).count,1)
    }
    func testPlanningAndNearestPositionAcrossIndependentFramesRemainMetric() throws {
        let g = try fixture(),t = CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[0].id)
        let location = try CampusMapGeometry.locate(graph:g,transforms:t,point:[8,0,0.3])
        XCTAssertEqual(location.position.region_id,g.regions[1].id);XCTAssertEqual(location.distance_m,0.3,accuracy:1e-8)
        XCTAssertEqual(location.position.fraction,2.0/3,accuracy:1e-8)
        let plan = try CampusOfflinePlanner().plan(CampusPlanningRequest(graph:CampusMapGeometry.navigationGraph(g,transforms:t),start:CampusRoutePosition(regionID:g.regions[0].id,edgeID:g.edges[0].id,fraction:0.5),destination:CampusDestination(nodeID:g.nodes[3].id)))
        XCTAssertEqual(plan.path.total_cost_m,12,accuracy:1e-8)
        let endpoint = plan.points.first(where: { $0.node_id == g.nodes[3].id })!.map_position
        for i in 0..<3 { XCTAssertEqual(endpoint[i],[10.0,0,0][i],accuracy:1e-8) }
        // Coordinate conversion must not mutate the stored regional geometry.
        XCTAssertNotEqual(g.bindings.last!.position,plan.points.last!.map_position)
    }
    func testRestrictedStartCannotJumpToAnotherConnectedRegion() throws {
        let g = try fixture(),t = CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[0].id)
        let scope = try CampusLocalizationScope.make(graph:g,start:.environment(regionID:g.regions[0].id,nodeID:nil))
        let p = try CampusMapGeometry.locate(graph:g,transforms:t,point:[8,0,0],allowedRanges:scope.edgeRanges)
        XCTAssertEqual(p.position.region_id,g.regions[0].id)
    }
    func testSupplementPreservesOriginalBytesDefaultAndAllGraphGeometry() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("CampusNetworks")),g = try fixture(),r = g.regions[0]
        let first = candidate(g,r),s1 = try source(g,region:r,in:root)
        let old = try l.saveCandidate(g,source:s1,candidate:first),path = try l.candidateDirectory(buildingID:g.building_id,candidateID:first.id),hash = try CampusFiles.hash(path.appendingPathComponent("environment.arworldmap"))
        let second = candidate(old,r,name:"白天补采"),s2 = try source(old,region:r,in:root,payload:"map-local-supplement")
        let new = try l.saveCandidate(old,source:s2,candidate:second)
        XCTAssertEqual(new.regions[0].default_map_id,first.id);XCTAssertEqual(new.map_candidates.count,2)
        XCTAssertTrue(new.map_candidates.allSatisfy(\.protected));XCTAssertEqual(new.bindings,old.bindings)
        XCTAssertEqual(try CampusFiles.hash(path.appendingPathComponent("environment.arworldmap")),hash)
        var current = new
        for _ in 0..<5 { current = try l.save(current) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:l.mapsDirectory(g.building_id),includingPropertiesForKeys:nil).count,2)
        _ = try l.pruneHistory()
        XCTAssertTrue(FileManager.default.fileExists(atPath:path.path))
        let currentDir = try l.directory(g.building_id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:currentDir.appendingPathComponent("regions"),includingPropertiesForKeys:nil).count,0)
    }
    func testLocalCandidateCanBindSubsetOfWholeRegionAndUseDifferentCoordinates() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        var transform = CampusMapGeometry.identity;transform[0][3] = 50;transform[2][3] = 8
        let subset = g.bindings.filter { $0.region_id == r.id }.suffix(2).map { b -> CampusBinding in var c = b;c.anchor_id = UUID().uuidString;c.anchor_to_map = CampusMapGeometry.multiply(CampusMapGeometry.inverse(transform),b.anchor_to_map);return c }
        let map = candidate(g,r,transform:transform),dir = try source(g,region:r,in:root,bindings:subset)
        let saved = try l.saveCandidate(g,source:dir,candidate:map)
        let snapshot = try l.verifyRegion(graph:saved,region:r,in:l.regionDirectory(buildingID:g.building_id,regionID:r.id))
        XCTAssertEqual(snapshot.bindings.count,2);XCTAssertEqual(saved.bindings,g.bindings)
        var wrong = map;wrong.id = UUID().uuidString;wrong.map_to_region = CampusMapGeometry.identity
        XCTAssertThrowsError(try l.saveCandidate(saved,source:dir,candidate:wrong));XCTAssertEqual(try l.load(g.building_id),saved)
    }
    func testConflictsAndCorruptSourcesCannotPublishCandidateOrChangeDefault() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],dir = try source(g,region:r,in:root)
        let saved = try l.saveCandidate(g,source:dir,candidate:candidate(g,r))
        let current = try l.save(saved),stale = candidate(saved,r)
        XCTAssertThrowsError(try l.saveCandidate(saved,source:dir,candidate:stale))
        XCTAssertFalse(FileManager.default.fileExists(atPath:try l.candidateDirectory(buildingID:g.building_id,candidateID:stale.id).path))
        try Data("corrupt".utf8).write(to:dir.appendingPathComponent("environment.arworldmap"))
        XCTAssertThrowsError(try l.saveCandidate(current,source:dir,candidate:candidate(g,r)));XCTAssertEqual(try l.load(g.building_id),current)
    }
    func testProtectedAndDefaultMapsCannotBeDeleted() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],first = candidate(g,r)
        var saved = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:first)
        var second = candidate(g,r);second.protected = false
        saved = try l.saveCandidate(saved,source:source(g,region:r,in:root),candidate:second)
        XCTAssertThrowsError(try l.deleteCandidate(buildingID:g.building_id,candidateID:first.id))
        try l.deleteCandidate(buildingID:g.building_id,candidateID:second.id)
        XCTAssertEqual(try l.load(g.building_id).map_candidates.map(\.id),[first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath:try l.candidateDirectory(buildingID:g.building_id,candidateID:second.id).path))
    }
    func testEveryCandidateSurvivesRegionBackupAndCollisionImport() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],first = candidate(g,r)
        let old = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:first)
        let saved = try l.saveCandidate(old,source:source(old,region:r,in:root,payload:"second"),candidate:candidate(g,r))
        let zip = root.appendingPathComponent("region.zip");try l.export(g.building_id,destination:zip,regionID:r.id)
        let copy = try l.importBackup(zip)
        XCTAssertNotEqual(copy.building_id,g.building_id);XCTAssertEqual(copy.map_candidates,saved.map_candidates)
        for m in copy.map_candidates {
            let dir = try l.candidateDirectory(buildingID:copy.building_id,candidateID:m.id)
            let snapshot = try l.verifyRegion(graph:copy,region:copy.regions[0],in:dir)
            XCTAssertEqual(snapshot.building_id,copy.building_id)
        };XCTAssertEqual(try l.load(g.building_id),saved)
    }
    func testOldBackupImportAddsCandidateWithoutReplacingCurrentNodesOrEdges() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        let old = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:candidate(g,r)),zip = root.appendingPathComponent("old.zip")
        try l.export(g.building_id,destination:zip,regionID:r.id)
        var renamed = old;renamed.nodes[0].name = "现用名字"
        let current = try l.save(renamed),new = try l.importCandidateBackup(zip,buildingID:g.building_id,regionID:r.id)
        XCTAssertEqual(new.nodes,current.nodes);XCTAssertEqual(new.edges,current.edges);XCTAssertEqual(new.bindings,current.bindings)
        XCTAssertEqual(new.map_candidates.count,2);XCTAssertEqual(new.regions[0].default_map_id,current.regions[0].default_map_id)
    }
    func testLegacyMigrationProtectsOriginalBeforeNewCandidateAndHistoryCleanup() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],version = UUID().uuidString
        let building = l.root.appendingPathComponent(g.building_id),dir = building.appendingPathComponent("versions/"+version)
        try FileManager.default.createDirectory(at:dir.appendingPathComponent("regions"),withIntermediateDirectories:true)
        try CampusFiles.encode(g,to:dir.appendingPathComponent("graph.json"))
        try FileManager.default.copyItem(at:source(g,region:r,in:root),to:dir.appendingPathComponent("regions/"+r.id))
        try CampusFiles.encode(["version_id":version],to:building.appendingPathComponent("current.json"))
        let new = try l.saveCandidate(g,source:source(g,region:r,in:root,payload:"new"),candidate:candidate(g,r))
        XCTAssertEqual(new.map_candidates.count,2)
        let baseline = new.map_candidates.first { $0.name == "原始地图（受保护）" }!
        XCTAssertEqual(new.regions[0].default_map_id,baseline.id)
        XCTAssertEqual(try Data(contentsOf:l.candidateDirectory(buildingID:g.building_id,candidateID:baseline.id).appendingPathComponent("environment.arworldmap")),Data("map-original".utf8))
        XCTAssertEqual(try l.prepareMaps(g.building_id).revision,new.revision)
    }
    func testCoverageRankingHonorsNearbyNodeVerificationAndDisabledCandidates() throws {
        var g = try fixture(),a = candidate(g,g.regions[0]),b = candidate(g,g.regions[0]),c = candidate(g,g.regions[0])
        a.verified = true;b.node_coverage[g.nodes[2].id] = 100;c.enabled = false
        g.regions[0].default_map_id = a.id;g.map_candidates = [a,b,c]
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id).map(\.id),[a.id,b.id])
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id,nearNodeID:g.nodes[2].id).map(\.id),[b.id,a.id])
    }
    func testThreeRegionalFramesComposeThroughOverlapWithoutDirectFirstThirdLink() throws {
        var g = try fixture(),c = CampusRegion(floorID:g.floors[0].id,name:"第三小图")
        c.map_saved = true;g.regions.append(c)
        let toWest:[[Double]] = [[0,0,1,-17],[0,1,0,1],[-1,0,0,12],[0,0,0,1]]
        for (i,x) in [(2,4.0),(3,10.0)] {
            let p = CampusMapGeometry.point([x,0,0],through:CampusMapGeometry.inverse(toWest))
            g.bindings.append(CampusBinding(regionID:c.id,nodeID:g.nodes[i].id,anchorID:UUID().uuidString,transform:pose(p)))
        }
        let connected = CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[0].id)
        XCTAssertEqual(connected.count,3)
        let p = CampusMapGeometry.point(g.bindings.last!.position,through:connected[c.id]!)
        for i in 0..<3 { XCTAssertEqual(p[i],[10.0,0,0][i],accuracy:1e-8) }
        let east = CampusMapGeometry.connectedTransforms(graph:g,activeRegionID:g.regions[1].id)
        let mapped = CampusMapGeometry.navigationGraph(g,transforms:east)
        let a = mapped.binding(nodeID:g.nodes[2].id,regionID:g.regions[0].id)!.position
        let b = mapped.binding(nodeID:g.nodes[2].id,regionID:g.regions[1].id)!.position
        for i in 0..<3 { XCTAssertEqual(a[i],b[i],accuracy:1e-8) }
    }
    func testSingleCandidateBackupIncludesSelectedFileAndMakesItDefaultOnlyInExport() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        let old = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:candidate(g,r))
        let second = candidate(g,r,name:"仅此候选"),subset = Array(g.bindings.filter { $0.region_id == r.id }.suffix(2))
        let saved = try l.saveCandidate(old,source:source(old,region:r,in:root,bindings:subset,payload:"partial-map"),candidate:second)
        let zip = root.appendingPathComponent("one.zip");try l.export(g.building_id,destination:zip,candidateID:second.id)
        let copy = try l.importBackup(zip)
        XCTAssertEqual(copy.map_candidates.count,1);XCTAssertEqual(copy.regions[0].default_map_id,second.id)
        XCTAssertEqual(copy.bindings,saved.bindings.filter { $0.region_id == r.id })
        let dir = try l.regionDirectory(buildingID:copy.building_id,regionID:r.id)
        let snapshot = try l.verifyRegion(graph:copy,region:copy.regions[0],in:dir)
        XCTAssertEqual(snapshot.bindings.count,2)
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("environment.arworldmap")),Data("partial-map".utf8))
        XCTAssertEqual(try l.load(g.building_id),saved)
    }
    func testLocalPriorityOutranksDefaultAndInheritedCoverageButRespectsExclusions() throws {
        var g = try fixture(),base = candidate(g,g.regions[0]),local = candidate(g,g.regions[0])
        let node = g.nodes[1].id,other = g.nodes[2].id
        base.node_coverage[node] = 10_000;base.verified = true
        local.preferred_node_ids = [node];local.node_coverage[other] = 10_000
        g.regions[0].default_map_id = base.id;g.map_candidates = [base,local];try g.validate()
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id,nearNodeID:node).first?.id,local.id)
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id,nearNodeID:other).first?.id,base.id)
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id).first?.id,base.id)
        g.map_candidates[1].preferred_node_ids = []
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id,nearNodeID:node).first?.id,base.id)
        g.map_candidates[1].preferred_node_ids = [node];g.map_candidates[1].enabled = false
        XCTAssertEqual(g.rankedMaps(regionID:g.regions[0].id,nearNodeID:node).map(\.id),[base.id])
    }
    func testLegacyCandidateDecodesWithoutPriorityAndNodeDeletionCleansAssignments() throws {
        var g = try fixture(),m = candidate(g,g.regions[0])
        let data = try JSONEncoder().encode(m)
        let old = try JSONDecoder().decode(CampusMapCandidate.self,from:data)
        XCTAssertNil(old.preferred_node_ids);XCTAssertNil(old.suggested_node_ids)
        m.preferred_node_ids = [g.nodes[1].id];m.suggested_node_ids = [g.nodes[1].id]
        g.map_candidates = [m];g.removeNode(g.nodes[1].id);try g.validate()
        XCTAssertEqual(g.map_candidates[0].preferred_node_ids,[])
        XCTAssertEqual(g.map_candidates[0].suggested_node_ids,[])
        m.preferred_node_ids = [UUID().uuidString];g.map_candidates = [m]
        XCTAssertThrowsError(try g.validate())
    }
    func testSupplementSuggestionsRequireRepeatedNearbyObservationsInSameHeightRange() throws {
        let g = try fixture(),bindings = g.bindings.filter { $0.region_id == g.regions[0].id }
        var coverage = CampusSupplementCoverage()
        for _ in 0..<3 { coverage.observe(bindings:bindings,position:[-4,1.5,0]) }
        XCTAssertTrue(coverage.suggestedNodeIDs().isEmpty)
        coverage.observe(bindings:bindings,position:[-4,1.5,0])
        XCTAssertEqual(Set(coverage.suggestedNodeIDs()),Set([g.nodes[0].id,g.nodes[1].id]))
        let old = coverage.observations
        coverage.observe(bindings:bindings,position:[0,8,0]);coverage.observe(bindings:bindings,position:[.nan,0,0]);coverage.observe(bindings:bindings,position:[0,0])
        XCTAssertEqual(coverage.observations,old)
    }
    func testPriorityEditingAndBackupDoNotModifyNativeMapAndImportRetainsHints() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        let m = candidate(g,r)
        var saved = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:m)
        let native = try l.candidateDirectory(buildingID:g.building_id,candidateID:m.id).appendingPathComponent("environment.arworldmap"),hash = try CampusFiles.hash(native)
        saved.map_candidates[0].preferred_node_ids = [g.nodes[1].id];saved.map_candidates[0].suggested_node_ids = [g.nodes[1].id,g.nodes[2].id]
        saved = try l.save(saved);XCTAssertEqual(try CampusFiles.hash(native),hash)
        let zip = root.appendingPathComponent("priority.zip");try l.export(g.building_id,destination:zip,candidateID:m.id)
        let copy = try l.importBackup(zip)
        XCTAssertEqual(copy.map_candidates[0].preferred_node_ids,[g.nodes[1].id])
        let imported = try l.importCandidateBackup(zip,buildingID:g.building_id,regionID:r.id)
        XCTAssertEqual(imported.map_candidates.last?.preferred_node_ids,[g.nodes[1].id])
        XCTAssertEqual(imported.map_candidates.last?.suggested_node_ids,[g.nodes[1].id,g.nodes[2].id])
        XCTAssertEqual(imported.regions[0].default_map_id,m.id)
        XCTAssertEqual(try CampusFiles.hash(native),hash)
    }
    func testInvalidFirstCandidateRollsBackItsNewDirectoryAndRetryCanSucceed() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],dir = try source(g,region:r,in:root)
        var wrong = candidate(g,r);wrong.map_to_region[0][3] = 10
        XCTAssertThrowsError(try l.saveCandidate(g,source:dir,candidate:wrong))
        XCTAssertFalse(FileManager.default.fileExists(atPath:l.root.appendingPathComponent(g.building_id).path))
        let saved = try l.saveCandidate(g,source:dir,candidate:candidate(g,r))
        XCTAssertEqual(saved.map_candidates.count,1);XCTAssertEqual(try l.load(g.building_id),saved)
    }
    func testCaptureWriteTargetCreatesOnceThenUpdatesAndCanStartWithExistingChild() throws {
        let g = try fixture(),sourceID = UUID().uuidString
        var create = CampusCaptureSaveTarget()
        XCTAssertTrue(create.createsSubenvironment);XCTAssertNil(create.replacementID)
        // Merely restoring a source (or a failed save) does not assign a write target.
        XCTAssertNotEqual(create.replacementID,sourceID)
        let childID = UUID().uuidString;create.didSave(childID)
        XCTAssertFalse(create.createsSubenvironment);XCTAssertEqual(create.replacementID,childID)
        create.didSave(childID);XCTAssertEqual(create.replacementID,childID)
        let update = CampusCaptureSaveTarget(replacing:g.nodes[0].id)
        XCTAssertFalse(update.createsSubenvironment);XCTAssertEqual(update.replacementID,g.nodes[0].id)
    }
    func testRepeatedReplacementRetainsIdentityOtherMapsAndDoesNotAccumulateNativeFiles() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        var base = candidate(g,r,name:"西口"),child = candidate(g,r,name:"活动室")
        base.verified = true;child.source_map_id = base.id;child.preferred_node_ids = [g.nodes[1].id]
        var current = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:base)
        current = try l.saveCandidate(current,source:source(current,region:r,in:root,payload:"child-initial"),candidate:child)
        let originalPath = try l.candidateDirectory(buildingID:g.building_id,candidateID:base.id)
        var previous = try l.candidateDirectory(buildingID:g.building_id,candidateID:child.id)
        for i in 0..<4 {
            var c = current.mapCandidate(child.id)!;c.name = "should not change";c.verified = true;c.lighting = .daylight
            c.world_map_sha256 = nil
            current = try l.saveCandidate(current,source:source(current,region:r,in:root,payload:"child-updated-\(i)"),candidate:c,replacing:true)
            let stored = current.mapCandidate(child.id)!,path = try l.candidateDirectory(buildingID:g.building_id,candidateID:child.id)
            XCTAssertEqual(stored.name,"活动室");XCTAssertEqual(stored.source_map_id,base.id)
            XCTAssertFalse(stored.verified);XCTAssertTrue(stored.protected);XCTAssertEqual(stored.lighting,.daylight)
            XCTAssertEqual(stored.preferred_node_ids,child.preferred_node_ids)
            XCTAssertEqual(current.regions[0].default_map_id,base.id);XCTAssertEqual(current.map_candidates.count,2)
            XCTAssertFalse(FileManager.default.fileExists(atPath:previous.path));previous = path
            XCTAssertEqual(try Data(contentsOf:path.appendingPathComponent("environment.arworldmap")),Data("child-updated-\(i)".utf8))
            _ = try l.verifyRegion(graph:current,region:r,in:path)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:l.mapsDirectory(g.building_id),includingPropertiesForKeys:nil).count,2)
        }
        XCTAssertEqual(try Data(contentsOf:originalPath.appendingPathComponent("environment.arworldmap")),Data("map-original".utf8))
        XCTAssertEqual(current.bindings,g.bindings);XCTAssertEqual(current.edges,g.edges)
    }
    func testProtectedDefaultReplacementResetsVerificationButKeepsDefaultAndName() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        var c = candidate(g,r,name:"默认子环境");c.verified = true
        let old = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:c)
        c.world_map_sha256 = nil;c.protected = false;c.enabled = false;c.name = "different"
        let new = try l.saveCandidate(old,source:source(old,region:r,in:root,payload:"new"),candidate:c,replacing:true)
        XCTAssertEqual(new.regions[0].default_map_id,c.id);XCTAssertEqual(new.map_candidates.count,1)
        XCTAssertEqual(new.mapCandidate(c.id)?.name,"默认子环境");XCTAssertEqual(new.mapCandidate(c.id)?.protected,true)
        XCTAssertEqual(new.mapCandidate(c.id)?.enabled,true);XCTAssertEqual(new.mapCandidate(c.id)?.verified,false)
    }
    func testFailedReplacementAndStaleWriterLeaveOriginalBytesAndGraphIntact() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],c = candidate(g,r)
        let old = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:c)
        let path = try l.candidateDirectory(buildingID:g.building_id,candidateID:c.id)
        var wrong = old.bindings.filter { $0.region_id == r.id }
        wrong[0].anchor_to_map[0][3] += 20
        let invalid = try source(old,region:r,in:root,bindings:wrong,payload:"incorrect-fit")
        XCTAssertThrowsError(try l.saveCandidate(old,source:invalid,candidate:c,replacing:true))
        XCTAssertEqual(try l.load(g.building_id),old)
        var stale = old;stale.revision -= 1
        XCTAssertThrowsError(try l.saveCandidate(stale,source:source(old,region:r,in:root,payload:"stale"),candidate:c,replacing:true))
        XCTAssertEqual(try Data(contentsOf:path.appendingPathComponent("environment.arworldmap")),Data("map-original".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:l.mapsDirectory(g.building_id),includingPropertiesForKeys:nil).count,1)
    }
    func testInterruptedReplacementCleanupBeforeAndAfterPublication() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0],c = candidate(g,r)
        let old = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:c)
        let maps = try l.mapsDirectory(g.building_id),journals = maps.deletingLastPathComponent().appendingPathComponent("map-updates")
        try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:true)
        let uncommitted = UUID().uuidString
        try FileManager.default.copyItem(at:maps.appendingPathComponent(c.id),to:maps.appendingPathComponent(uncommitted))
        try CampusFiles.encode(["old_file_id":c.id,"new_file_id":uncommitted],to:journals.appendingPathComponent(UUID().uuidString+".json"))
        _ = try l.prepareMaps(g.building_id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:maps.appendingPathComponent(uncommitted).path))
        let new = try l.saveCandidate(old,source:source(old,region:r,in:root,payload:"updated"),candidate:c,replacing:true)
        let fileID = new.mapCandidate(c.id)!.fileID
        // Simulate publication followed by a crash before retiring the old directory.
        try FileManager.default.copyItem(at:maps.appendingPathComponent(fileID),to:maps.appendingPathComponent(c.id))
        try CampusFiles.encode(["old_file_id":c.id,"new_file_id":fileID],to:journals.appendingPathComponent(UUID().uuidString+".json"))
        _ = try l.prepareMaps(g.building_id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:maps.appendingPathComponent(c.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:maps.appendingPathComponent(fileID).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at:journals,includingPropertiesForKeys:nil).count,0)
    }
    func testReplacementBackupsExportLatestBytesAndImportWithPortableLogicalIDs() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        var c = candidate(g,r);c.preferred_node_ids = [g.nodes[0].id]
        let first = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:c)
        let old = try l.saveCandidate(first,source:source(first,region:g.regions[1],in:root),candidate:candidate(first,g.regions[1]))
        let new = try l.saveCandidate(old,source:source(old,region:r,in:root,payload:"latest-map"),candidate:c,replacing:true)
        for selected in [nil,c.id] as [String?] {
            let zip = root.appendingPathComponent(UUID().uuidString+".zip")
            try l.export(g.building_id,destination:zip,candidateID:selected)
            let imported = try l.importBackup(zip),map = imported.mapCandidate(c.id)!
            XCTAssertNil(map.file_id);XCTAssertEqual(map.preferred_node_ids,c.preferred_node_ids)
            let dir = try l.candidateDirectory(buildingID:imported.building_id,candidateID:c.id)
            XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("environment.arworldmap")),Data("latest-map".utf8))
            _ = try l.verifyRegion(graph:imported,region:imported.regions[0],in:dir)
            let previousCount = try l.load(g.building_id).map_candidates.count
            let merged = try l.importCandidateBackup(zip,buildingID:g.building_id,regionID:r.id)
            XCTAssertEqual(merged.map_candidates.count,previousCount+1)
            XCTAssertEqual(merged.mapCandidate(c.id)?.world_map_sha256,new.mapCandidate(c.id)?.world_map_sha256)
        }
    }
    func testDeleteReplacedNonDefaultChildRemovesCurrentPhysicalFile() throws {
        let root = try temp();defer { try? FileManager.default.removeItem(at:root) }
        let l = CampusLibrary(root:root.appendingPathComponent("library")),g = try fixture(),r = g.regions[0]
        let base = candidate(g,r);var child = candidate(g,r);child.protected = false
        let a = try l.saveCandidate(g,source:source(g,region:r,in:root),candidate:base)
        let b = try l.saveCandidate(a,source:source(a,region:r,in:root),candidate:child)
        let c = try l.saveCandidate(b,source:source(b,region:r,in:root,payload:"updated-child"),candidate:child,replacing:true)
        let path = try l.candidateDirectory(buildingID:g.building_id,candidateID:child.id)
        XCTAssertNotNil(c.mapCandidate(child.id)?.file_id)
        try l.deleteCandidate(buildingID:g.building_id,candidateID:child.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:path.path));XCTAssertEqual(try l.load(g.building_id).map_candidates.count,1)
    }
    func testOnlyOrdinaryWaypointsHideNamesAndOtherKindsKeepNamesThroughRoundTrip() throws {
        var g = try fixture()
        let kinds:[CampusNodeKind] = [.waypoint,.junction,.stair,.room]
        let names = ["旧普通路点名","西口岔路口","东楼梯口","活动室"]
        for i in kinds.indices { g.nodes[i].kind = kinds[i];g.nodes[i].name = names[i] }
        try g.validate()
        XCTAssertNil(g.nodeMapLabel(g.nodes[0]));XCTAssertEqual(g.nodeLabel(g.nodes[0]),"路点 001")
        for i in 1..<4 {
            XCTAssertEqual(g.nodeMapLabel(g.nodes[i]),names[i]);XCTAssertTrue(g.title(g.nodes[i]).contains(names[i]))
            XCTAssertTrue(CampusDestination(nodeID:g.nodes[i].id).title(in:g).contains(names[i]))
        }
        let copy = try JSONDecoder().decode(CampusGraph.self,from:JSONEncoder().encode(g))
        XCTAssertEqual(copy.nodes.map(\.name),names);XCTAssertEqual(copy.bindings,g.bindings)
        XCTAssertTrue(CampusStartSelection.environment(regionID:g.regions[0].id,nodeID:g.nodes[1].id).title(in:g).contains("西口岔路口"))
    }
    func testEmptyNonWaypointNamesFrom072RemainEditableWithoutChangingBindings() throws {
        var g = try fixture();g.nodes[1].name = ""
        let bindings = g.bindings,edges = g.edges
        try g.validate();XCTAssertTrue(g.nodeMapLabel(g.nodes[1])?.hasPrefix("未命名岔路口") == true)
        g.nodes[1].name = "北岔路口";try g.validate()
        XCTAssertEqual(g.nodeMapLabel(g.nodes[1]),"北岔路口");XCTAssertEqual(g.bindings,bindings);XCTAssertEqual(g.edges,edges)
    }
    func testLightingPreferencePreservesLocalityAndKeepsOppositeLightingFallbacks() throws {
        var g = try fixture();let r = g.regions[0],node = g.nodes[1].id
        var day = candidate(g,r,name:"白天"),night = candidate(g,r,name:"夜间"),other = candidate(g,r,name:"其他光照")
        day.lighting = .daylight;night.lighting = .night
        for id in [day.id,night.id,other.id] { XCTAssertNotNil(UUID(uuidString:id)) }
        g.regions[0].default_map_id = night.id;g.map_candidates = [night,other,day]
        XCTAssertEqual(g.rankedMaps(regionID:r.id,preferredLighting:.daylight).map(\.id),[day.id,other.id,night.id])
        XCTAssertEqual(g.rankedMaps(regionID:r.id,preferredLighting:.night).map(\.id),[night.id,other.id,day.id])
        night.preferred_node_ids = [node];day.preferred_node_ids = [node]
        g.map_candidates = [night,other,day]
        XCTAssertEqual(g.rankedMaps(regionID:r.id,nearNodeID:node,preferredLighting:.daylight).first?.id,day.id)
        day.preferred_node_ids = [] // A daylight map from elsewhere must not outrank this location.
        g.map_candidates = [night,other,day]
        XCTAssertEqual(g.rankedMaps(regionID:r.id,nearNodeID:node,preferredLighting:.daylight).first?.id,night.id)
        day.enabled = false;g.map_candidates = [night,other,day]
        XCTAssertFalse(g.rankedMaps(regionID:r.id,preferredLighting:.daylight).contains { $0.id == day.id })
    }
    func testRoomGroupsAreLimitedToSameRegionAndPlanNearestEntranceFromActualPosition() throws {
        var g = try fixture();let west0 = g.edges[0],west1 = g.edges[1],east = g.edges[2]
        let a = CampusRoom(name:"活动室",edgeID:west0.id,fraction:0.2,side:.left)
        let b = CampusRoom(name:"活动室",edgeID:west1.id,fraction:0.8,side:.right)
        let other = CampusRoom(name:"活动室",edgeID:east.id,fraction:0.5,side:.left)
        g.rooms = [a,b,other]
        XCTAssertEqual(g.roomGroups.map(\.count),[2,1]);XCTAssertEqual(g.roomDestinations.count,2)
        let planner = CampusOfflinePlanner(),group = g.roomDestinations[0]
        let atWest = try planner.plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:g.regions[0].id,edgeID:west0.id,fraction:0.1),destination:group))
        let atEast = try planner.plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:g.regions[0].id,edgeID:west1.id,fraction:0.9),destination:group))
        XCTAssertEqual(atWest.destination.id,a.id);XCTAssertEqual(atEast.destination.id,b.id)
        XCTAssertNotEqual(atEast.destination.id,other.id);XCTAssertTrue(atEast.arrival_hint?.contains("左") == true)
        let exact = try planner.plan(CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:g.regions[0].id,edgeID:west1.id,fraction:0.9),destination:CampusDestination(roomID:a.id)))
        XCTAssertEqual(exact.destination.id,a.id)
    }
    func testNearestSameNameEntranceUsesWalkDistanceAndSkipsUnreachableEntrances() throws {
        var g = CampusGraph(name:"绕行测试"),f = CampusFloor(name:"一楼")
        var r = CampusRegion(floorID:f.id,name:"环境");r.map_saved = true;g.floors = [f];g.regions = [r]
        let coordinates:[[Double]] = [[0,0,0],[0,0,10],[1,0,10],[1,0,0],[5,0,0],[6,0,0]]
        g.nodes = coordinates.map { _ in CampusNode(floorID:f.id,name:"",kind:.waypoint) }
        g.bindings = coordinates.enumerated().map { i,p in CampusBinding(regionID:r.id,nodeID:g.nodes[i].id,anchorID:UUID().uuidString,transform:pose(p)) }
        for (a,b) in [(0,1),(1,2),(2,3),(4,5)] { try g.connect(g.nodes[a].id,g.nodes[b].id,regionID:r.id) }
        let disconnected = CampusRoom(name:"出口",edgeID:g.edges[3].id,fraction:0.5,side:.left)
        let physicallyNear = CampusRoom(name:"出口",edgeID:g.edges[2].id,fraction:0.99,side:.left)
        let walkNear = CampusRoom(name:"出口",edgeID:g.edges[0].id,fraction:0.2,side:.left)
        g.rooms = [disconnected,physicallyNear,walkNear]
        let request = CampusPlanningRequest(graph:g,start:CampusRoutePosition(regionID:r.id,edgeID:g.edges[0].id,fraction:0),destination:g.roomDestinations[0])
        let plan = try CampusOfflinePlanner().plan(request)
        XCTAssertEqual(plan.destination.id,walkNear.id);XCTAssertEqual(plan.path.total_cost_m,2,accuracy:1e-8)
        let decoded = try JSONDecoder().decode(CampusPlanningRequest.self,from:JSONEncoder().encode(request))
        XCTAssertEqual(decoded.destination.nearest_same_name,true)
        let legacy = try JSONDecoder().decode(CampusDestination.self,from:Data("{\"kind\":\"room\",\"id\":\"\(walkNear.id)\"}".utf8))
        XCTAssertNil(legacy.nearest_same_name)
    }

}
