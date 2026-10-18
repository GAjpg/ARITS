import Foundation
#if !targetEnvironment(macCatalyst)
import ARKit
#endif

enum CampusFeatureStore {
    static let fileName = "feature-points.json"
    // Called on CampusApp.io. A native old map remains usable without this derivative.
    static func load(graph:CampusGraph,region:CampusRegion,candidateID:String? = nil) throws -> CampusFeaturePointCloud {
        let selectedID = candidateID ?? region.default_map_id
        let dir = try selectedID.map { try CampusApp.library.candidateDirectory(buildingID:graph.building_id,candidateID:$0) } ?? CampusApp.library.regionDirectory(buildingID:graph.building_id,regionID:region.id)
        let url = dir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath:url.path) {
            _ = try CampusApp.library.verifyRegion(graph:graph,region:region,in:dir)
            let bytes = try Data(contentsOf:url)
            guard bytes.count <= 16*1024*1024 else { throw CampusError.corrupt }
            let cloud = try JSONDecoder().decode(CampusFeaturePointCloud.self,from:bytes)
            guard cloud.source == .savedMap else { throw CampusError.corrupt }
            try cloud.validate(regionID:region.id,mapHash:CampusFiles.hash(dir.appendingPathComponent("environment.arworldmap")))
            return transformed(cloud,by:graph.mapCandidate(selectedID)?.map_to_region ?? CampusMapGeometry.identity)
        }
        #if !targetEnvironment(macCatalyst)
        let loaded = try CampusARStore.loadVerified(graph:graph,region:region,candidateID:selectedID)
        let cloud = try make(map:loaded.map,regionID:region.id,date:loaded.snapshot.saved_utc,mapHash:CampusFiles.hash(dir.appendingPathComponent("environment.arworldmap")))
        return transformed(cloud,by:graph.mapCandidate(selectedID)?.map_to_region ?? CampusMapGeometry.identity)
        #else
        throw CampusError.invalid("旧备份没有可在 Mac 查看的点云。请在 iPhone 上保存一次环境，再导出新版备份；无需重建路网。")
        #endif
    }
    static func transformed(_ cloud:CampusFeaturePointCloud,by matrix:[[Double]]) -> CampusFeaturePointCloud {
        CampusFeatureDistribution.transformed(cloud,by:matrix)
    }
    static func loadAll(graph:CampusGraph,region:CampusRegion) -> (layers:[CampusFeatureLayer],failures:[String]) {
        let candidates = graph.map_candidates.filter { $0.region_id == region.id }.sorted { $0.saved_utc == $1.saved_utc ? $0.id < $1.id : $0.saved_utc < $1.saved_utc }
        var layers:[CampusFeatureLayer] = [],failures:[String] = []
        if candidates.isEmpty {
            do { layers.append(CampusFeatureLayer(id:region.id,name:"原始地图",cloud:try load(graph:graph,region:region))) }
            catch { failures.append("原始地图："+error.localizedDescription) }
        } else {
            for m in candidates {
                do { layers.append(CampusFeatureLayer(id:m.id,name:m.name,cloud:try load(graph:graph,region:region,candidateID:m.id))) }
                catch { failures.append(m.name+"："+error.localizedDescription) }
            }
        }
        return (layers,failures)
    }
    #if !targetEnvironment(macCatalyst)
    static func make(map:ARWorldMap,regionID:String,date:String,mapHash:String?) throws -> CampusFeaturePointCloud {
        let points = map.rawFeaturePoints.points.map { ProbePoint(Double($0.x),Double($0.y),Double($0.z)) }
        let cloud = CampusFeaturePointCloud(regionID:regionID,date:date,source:mapHash == nil ? .sessionPreview : .savedMap,mapHash:mapHash,points:points)
        try cloud.validate(regionID:regionID,mapHash:mapHash);return cloud
    }
    #endif
}
