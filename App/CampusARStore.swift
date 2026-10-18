#if !targetEnvironment(macCatalyst)
import ARKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum CampusARStore {
    struct Loaded {
        let map:ARWorldMap,directory:URL,snapshot:CampusRegionSnapshot
        let validationSeconds:Double,decodeSeconds:Double,cacheHit:Bool
    }
    private final class Cached:NSObject {
        let map:ARWorldMap,snapshot:CampusRegionSnapshot,fingerprint:String
        init(map:ARWorldMap,snapshot:CampusRegionSnapshot,fingerprint:String) { self.map = map;self.snapshot = snapshot;self.fingerprint = fingerprint }
    }
    private static let cache = NSCache<NSString,Cached>()
    // Called on CampusApp.io. Validate new versions fully; cache only unchanged files.
    static func loadVerified(graph:CampusGraph,region:CampusRegion,candidateID:String? = nil) throws -> Loaded {
        let dir = try candidateID.map { try CampusApp.library.candidateDirectory(buildingID:graph.building_id,candidateID:$0) } ?? CampusApp.library.regionDirectory(buildingID:graph.building_id,regionID:region.id)
        let keys:Set<URLResourceKey> = [.fileSizeKey,.contentModificationDateKey,.isRegularFileKey]
        guard let files = FileManager.default.enumerator(at:dir,includingPropertiesForKeys:Array(keys)) else { throw CampusError.corrupt }
        var attrs:[String] = []
        for case let url as URL in files {
            let v = try url.resourceValues(forKeys:keys)
            if v.isRegularFile == true { attrs.append(url.path+":"+String(v.fileSize ?? -1)+":"+String(v.contentModificationDate?.timeIntervalSince1970 ?? 0)) }
        }
        let fingerprint = attrs.sorted().joined(separator:"|"),key = (dir.path+":"+String(graph.revision)) as NSString
        if let old = cache.object(forKey:key),old.fingerprint == fingerprint {
            return Loaded(map:old.map.copy() as! ARWorldMap,directory:dir,snapshot:old.snapshot,validationSeconds:0,decodeSeconds:0,cacheHit:true)
        }
        let start = ProcessInfo.processInfo.systemUptime,snapshot = try CampusApp.library.verifyRegion(graph:graph,region:region,in:dir)
        let validated = ProcessInfo.processInfo.systemUptime,map = try decode(dir.appendingPathComponent("environment.arworldmap"),snapshot:snapshot)
        let decoded = ProcessInfo.processInfo.systemUptime
        cache.countLimit = 2;cache.totalCostLimit = 100*1024*1024
        let bytes = (try dir.appendingPathComponent("environment.arworldmap").resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0
        cache.setObject(Cached(map:map,snapshot:snapshot,fingerprint:fingerprint),forKey:key,cost:bytes)
        return Loaded(map:map.copy() as! ARWorldMap,directory:dir,snapshot:snapshot,validationSeconds:validated-start,decodeSeconds:decoded-validated,cacheHit:false)
    }
    static func validateArchive(_ url: URL, snapshot: CampusRegionSnapshot) throws {
        _ = try decode(url,snapshot:snapshot)
        for binding in snapshot.bindings {
            let base = url.deletingLastPathComponent().appendingPathComponent("references/"+binding.node_id)
            guard let source = CGImageSourceCreateWithURL(base.appendingPathExtension("jpg") as CFURL,nil),
                  let image = CGImageSourceCreateImageAtIndex(source,0,nil),
                  let metadata = try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathExtension("json"))) as? [String:Any],
                  let dimensions = metadata["image"] as? [String:Any],
                  dimensions["width"] as? Int == image.width, dimensions["height"] as? Int == image.height,
                  metadata["pose_association"] as? String == "same_ARFrame" else { throw CampusError.corrupt }
        }
    }
    static func decode(_ url: URL, snapshot: CampusRegionSnapshot) throws -> ARWorldMap {
        let data = try Data(contentsOf:url)
        guard data.count > 0, data.count <= 100 * 1024 * 1024,
              let map = try NSKeyedUnarchiver.unarchivedObject(ofClass:ARWorldMap.self,from:data) else { throw CampusError.corrupt }
        for binding in snapshot.bindings {
            guard let anchor = map.anchors.first(where: { $0.identifier.uuidString == binding.anchor_id && $0.name == "campus-node/"+binding.node_id }),
                  RigidMatrix.valid(matrixRows(anchor.transform)) else { throw CampusError.corrupt }
            let m = matrixRows(anchor.transform)
            guard (0..<4).allSatisfy({ r in (0..<4).allSatisfy { abs(m[r][$0] - binding.anchor_to_map[r][$0]) < 1e-4 } }) else { throw CampusError.corrupt }
        }
        return map
    }
    static func writeReference(_ reference: WorldMapReferenceFrame, nodeID: String, directory: URL) throws {
        guard UUID(uuidString:nodeID) != nil else { throw CampusError.corrupt }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let context = CIContext(), image = CIImage(cvPixelBuffer:reference.pixels)
        guard let cg = context.createCGImage(image,from:image.extent) else { throw CaptureError.encoding }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw CaptureError.encoding }
        CGImageDestinationAddImage(writer,cg,[kCGImagePropertyOrientation:1,kCGImageDestinationLossyCompressionQuality:0.80] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CaptureError.encoding }
        try (data as Data).write(to:directory.appendingPathComponent(nodeID+".jpg"),options:.atomic)
        try ProbeIO.json(reference.metadata,pretty:true).write(to:directory.appendingPathComponent(nodeID+".json"),options:.atomic)
    }
    static func writeSearchView(_ reference:WorldMapReferenceFrame, directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let id = UUID().uuidString, image = CIImage(cvPixelBuffer:reference.pixels)
        let scale = min(1,640/max(image.extent.width,image.extent.height))
        let resized = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg = CIContext().createCGImage(resized,from:resized.extent.integral) else { throw CaptureError.encoding }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw CaptureError.encoding }
        CGImageDestinationAddImage(writer,cg,[kCGImagePropertyOrientation:1,kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CaptureError.encoding }
        try (data as Data).write(to:directory.appendingPathComponent(id+".jpg"),options:.atomic)
        // These small images are retrieval references, not metric pose training labels.
        try ProbeIO.json(["purpose":"region_search_thumbnail_not_ground_truth","source_frame":reference.metadata,"saved_image":["width":cg.width,"height":cg.height],"source_pixel_scale":Double(scale)],pretty:true).write(to:directory.appendingPathComponent(id+".json"),options:.atomic)
    }
    static func writeGuide(_ reference:WorldMapReferenceFrame,guide:CampusRecoveryGuide,directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let image = CIImage(cvPixelBuffer:reference.pixels),scale = min(1,960/max(image.extent.width,image.extent.height))
        let resized = image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        guard let cg = CIContext().createCGImage(resized,from:resized.extent.integral) else { throw CaptureError.encoding }
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw CaptureError.encoding }
        CGImageDestinationAddImage(writer,cg,[kCGImagePropertyOrientation:1,kCGImageDestinationLossyCompressionQuality:0.8] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CaptureError.encoding }
        try (data as Data).write(to:directory.appendingPathComponent(guide.id+".jpg"),options:.atomic)
        try CampusFiles.encode(guide,to:directory.appendingPathComponent(guide.id+".json"))
    }
    static func save(graph: CampusGraph, regionID: String, map: ARWorldMap, references: URL, views: URL,guides:URL, sessionID: String,localBindings:[CampusBinding],lighting:CampusLighting,sourceMapID:String?,preferredNodeIDs:[String]? = nil,suggestedNodeIDs:[String]? = nil,replacingMapID:String? = nil) throws -> (graph:CampusGraph,features:CampusFeaturePointCloud,candidate:CampusMapCandidate) {
        guard graph.region(regionID) != nil,map.rawFeaturePoints.points.count > 0,localBindings.count >= 2 else { throw CampusError.corrupt }
        var draft = graph
        let nativeBindings = try localBindings.map { b -> CampusBinding in
            guard let anchor = map.anchors.first(where: { $0.identifier.uuidString == b.anchor_id && $0.name == "campus-node/"+b.node_id }) else { throw CampusError.invalid("地图缺少已绑定节点的锚点，请保持跟踪后重试。") }
            return CampusBinding(regionID:regionID,nodeID:b.node_id,anchorID:b.anchor_id,transform:matrixRows(anchor.transform))
        }
        let fit = try CampusMapGeometry.fit(source:nativeBindings,target:draft.bindings.filter { $0.region_id == regionID })
        for i in draft.edges.indices where draft.edges[i].region_id == regionID {
            guard let a = draft.binding(nodeID:draft.edges[i].from,regionID:regionID), let b = draft.binding(nodeID:draft.edges[i].to,regionID:regionID) else { throw CampusError.corrupt }
            let length = hypot(a.position[0]-b.position[0],a.position[2]-b.position[2])
            guard length >= 0.1 else { throw CampusError.invalid("部分节点距离过近，检查重复标点后再保存。") }
            draft.edges[i].length_m = length; draft.edges[i].cost_m = length
        }
        guard let i = draft.regions.firstIndex(where:{$0.id == regionID}) else { throw CampusError.corrupt }
        draft.regions[i].map_saved = true; try draft.validate()
        var snapshot = CampusRegionSnapshot(graph:draft,region:draft.regions[i],sessionID:sessionID,features:map.rawFeaturePoints.points.count)
        snapshot.bindings = nativeBindings
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("campus-map-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temp) }
        try NSKeyedArchiver.archivedData(withRootObject:map,requiringSecureCoding:true).write(to:temp.appendingPathComponent("environment.arworldmap"),options:.atomic)
        let cloud = try CampusFeatureStore.make(map:map,regionID:regionID,date:snapshot.saved_utc,
                                               mapHash:CampusFiles.hash(temp.appendingPathComponent("environment.arworldmap")))
        try JSONEncoder().encode(cloud).write(to:temp.appendingPathComponent(CampusFeatureStore.fileName),options:.atomic)
        try CampusFiles.encode(snapshot,to:temp.appendingPathComponent("region.json"))
        try FileManager.default.copyItem(at:references,to:temp.appendingPathComponent("references"))
        if FileManager.default.fileExists(atPath:views.path) { try FileManager.default.copyItem(at:views,to:temp.appendingPathComponent("views")) }
        if FileManager.default.fileExists(atPath:guides.path) { try FileManager.default.copyItem(at:guides,to:temp.appendingPathComponent("guides")) }
        // Remove photos of undone points so a restored package has a precise reference set.
        let needed = Set(snapshot.bindings.map(\.node_id))
        let ref = temp.appendingPathComponent("references")
        for file in try FileManager.default.contentsOfDirectory(at:ref,includingPropertiesForKeys:nil) where !needed.contains(file.deletingPathExtension().lastPathComponent) {
            try FileManager.default.removeItem(at:file)
        }
        let guideDir = temp.appendingPathComponent("guides")
        for json in (try? FileManager.default.contentsOfDirectory(at:guideDir,includingPropertiesForKeys:nil)) ?? [] where json.pathExtension == "json" {
            guard let g = try? JSONDecoder().decode(CampusRecoveryGuide.self,from:Data(contentsOf:json)),(try? g.validate(nodeIDs:needed)) != nil else {
                try? FileManager.default.removeItem(at:json.deletingPathExtension().appendingPathExtension("jpg"));try? FileManager.default.removeItem(at:json);continue
            }
        }
        try CampusFiles.manifest(temp); try validateArchive(temp.appendingPathComponent("environment.arworldmap"),snapshot:snapshot)
        var coverage:[String:Int] = [:]
        for binding in draft.bindings where binding.region_id == regionID {
            let local = CampusMapGeometry.point(binding.position,through:CampusMapGeometry.inverse(fit.transform))
            coverage[binding.node_id] = map.rawFeaturePoints.points.filter { hypot(Double($0.x)-local[0],Double($0.z)-local[2]) <= 5 }.count
        }
        var candidate = CampusMapCandidate(regionID:regionID,name:(preferredNodeIDs == nil ? "" : "局部补采 · ")+lighting.title+" · "+String(snapshot.saved_utc.prefix(16)),date:snapshot.saved_utc,lighting:lighting,transform:fit.transform,coverage:coverage)
        candidate.source_map_id = sourceMapID
        candidate.preferred_node_ids = preferredNodeIDs
        candidate.suggested_node_ids = suggestedNodeIDs
        candidate.world_map_sha256 = cloud.world_map_sha256
        if let replacingMapID {
            guard let previous = graph.mapCandidate(replacingMapID),previous.region_id == regionID else { throw CampusError.corrupt }
            candidate.id = previous.id
            candidate.preferred_node_ids = preferredNodeIDs ?? previous.preferred_node_ids
        }
        let saved = try CampusApp.library.saveCandidate(draft,source:temp,candidate:candidate,replacing:replacingMapID != nil)
        guard let stored = saved.mapCandidate(candidate.id) else { throw CampusError.corrupt }
        return (saved,cloud,stored)
    }
}
#endif
