import Foundation

public final class CampusLibrary: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let lock = NSRecursiveLock()
    private struct Pointer: Codable { var version_id: String }
    private struct MapUpdate: Codable { var old_file_id:String;var new_file_id:String }
    private struct Backup: Codable { var schema_version = 1; var kind = "campus_network_backup"; var building_id: String }
    public init(root: URL) { self.root = root }
    private func buildingURL(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CampusError.corrupt }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    public func directory(_ id: String) throws -> URL {
        let building = try buildingURL(id)
        let pointer = try JSONDecoder().decode(Pointer.self, from: Data(contentsOf: building.appendingPathComponent("current.json")))
        guard UUID(uuidString: pointer.version_id) != nil else { throw CampusError.corrupt }
        return building.appendingPathComponent("versions/"+pointer.version_id, isDirectory: true)
    }
    public func load(_ id: String) throws -> CampusGraph {
        let graph = try JSONDecoder().decode(CampusGraph.self, from: Data(contentsOf: directory(id).appendingPathComponent("graph.json")))
        try graph.validate(); guard graph.building_id == id else { throw CampusError.corrupt }; return graph
    }
    public func list() -> [CampusGraph] {
        ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? load($0.lastPathComponent) }.sorted { $0.updated_utc > $1.updated_utc }
    }
    /// Keep the published graph version and one prior graph version. Native files are shared;
    /// explicitly overwritten or deleted subenvironments require an exported ZIP for rollback.
    /// Unreadable, partial, and symbolic-link directories are deliberately left untouched.
    public func historyCleanupCandidates() -> [URL] {
        lock.lock();defer { lock.unlock() }
        var candidates:[URL] = []
        for graph in list() {
            guard let current = try? directory(graph.building_id) else { continue }
            let versions = current.deletingLastPathComponent()
            var previous:[(URL,Int)] = []
            for item in (try? fm.contentsOfDirectory(at:versions,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])) ?? [] {
                guard item != current,UUID(uuidString:item.lastPathComponent) != nil,
                      let attrs = try? item.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),attrs.isDirectory == true,attrs.isSymbolicLink != true,
                      let data = try? Data(contentsOf:item.appendingPathComponent("graph.json")),
                      let old = try? JSONDecoder().decode(CampusGraph.self,from:data),old.building_id == graph.building_id,
                      old.revision < graph.revision,(try? old.validate()) != nil else { continue }
                previous.append((item,old.revision))
            }
            previous.sort { $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1 }
            candidates += previous.dropFirst().map { $0.0 }
        }
        return candidates
    }
    @discardableResult public func pruneHistory() throws -> Int {
        lock.lock();defer { lock.unlock() }
        for graph in list() { _ = try prepareMaps(graph.building_id) }
        let candidates = historyCleanupCandidates()
        for directory in candidates { try fm.removeItem(at:directory) }
        return candidates.count
    }
    public func mapsDirectory(_ id:String) throws -> URL { try buildingURL(id).appendingPathComponent("maps") }
    public func candidateDirectory(buildingID:String,candidateID:String) throws -> URL {
        guard UUID(uuidString:candidateID) != nil else { throw CampusError.corrupt }
        let fileID = (try? load(buildingID))?.mapCandidate(candidateID)?.fileID ?? candidateID
        return try mapFileDirectory(buildingID:buildingID,fileID:fileID)
    }
    private func mapFileDirectory(buildingID:String,fileID:String) throws -> URL {
        guard UUID(uuidString:fileID) != nil else { throw CampusError.corrupt }
        return try mapsDirectory(buildingID).appendingPathComponent(fileID)
    }
    /// Recover interrupted replacements using the atomically published graph as the authority.
    /// Never remove a native file still referenced by a current subenvironment.
    public func recoverMapUpdates(_ id:String) throws {
        lock.lock();defer { lock.unlock() }
        let graph = try load(id),live = Set(graph.map_candidates.map(\.fileID))
        let updates = try buildingURL(id).appendingPathComponent("map-updates")
        for journal in (try? fm.contentsOfDirectory(at:updates,includingPropertiesForKeys:nil)) ?? [] {
            guard journal.pathExtension == "json",UUID(uuidString:journal.deletingPathExtension().lastPathComponent) != nil else { continue }
            let update = try JSONDecoder().decode(MapUpdate.self,from:Data(contentsOf:journal))
            guard UUID(uuidString:update.old_file_id) != nil,UUID(uuidString:update.new_file_id) != nil,update.old_file_id != update.new_file_id else { throw CampusError.corrupt }
            let retired = live.contains(update.new_file_id) ? update.old_file_id : update.new_file_id
            if !live.contains(retired) {
                let directory = try mapFileDirectory(buildingID:id,fileID:retired)
                if fm.fileExists(atPath:directory.path) { try fm.removeItem(at:directory) }
            }
            try fm.removeItem(at:journal)
        }
    }
    /// Migrate the published legacy maps before ordinary version cleanup can remove them.
    public func prepareMaps(_ id:String) throws -> CampusGraph {
        lock.lock();defer { lock.unlock() }
        try recoverMapUpdates(id)
        let graph = try load(id),dir = try directory(id)
        if graph.regions.contains(where: { $0.map_saved && $0.default_map_id == nil && fm.fileExists(atPath:dir.appendingPathComponent("regions/"+$0.id+"/environment.arworldmap").path) }) { return try save(graph) }
        return graph
    }
    public func deleteCandidate(buildingID:String,candidateID:String) throws {
        lock.lock();defer { lock.unlock() }
        var graph = try load(buildingID)
        guard let candidate = graph.mapCandidate(candidateID),!candidate.protected,
              !graph.regions.contains(where:{$0.default_map_id == candidateID}) else { throw CampusError.invalid("受保护或默认地图不能删除。") }
        let target = try mapFileDirectory(buildingID:buildingID,fileID:candidate.fileID)
        graph.map_candidates.removeAll { $0.id == candidateID }
        _ = try save(graph)
        try fm.removeItem(at:target)
    }
    public func regionDirectory(buildingID: String, regionID: String) throws -> URL {
        guard UUID(uuidString: regionID) != nil else { throw CampusError.corrupt }
        if let id = try load(buildingID).region(regionID)?.default_map_id { return try candidateDirectory(buildingID:buildingID,candidateID:id) }
        return try directory(buildingID).appendingPathComponent("regions/"+regionID, isDirectory: true)
    }
    public func verifyRegion(graph: CampusGraph, region: CampusRegion, in directory: URL) throws -> CampusRegionSnapshot {
        guard region.map_saved else { throw CampusError.unsaved(region.name) }
        try CampusFiles.verify(directory)
        let snapshot = try JSONDecoder().decode(CampusRegionSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("region.json")))
        let candidate = graph.map_candidates.first { $0.fileID == directory.lastPathComponent }
        try snapshot.validate(graph: graph, region: region,candidate:candidate != nil)
        if let candidate {
            guard candidate.region_id == region.id else { throw CampusError.corrupt }
            let manifest = try JSONDecoder().decode(CampusFiles.Manifest.self,from:Data(contentsOf:directory.appendingPathComponent("files.json")))
            if let hash = candidate.world_map_sha256 { guard manifest.files.first(where: { $0.path == "environment.arworldmap" })?.sha256 == hash else { throw CampusError.corrupt } }
            let live = graph.bindings.filter { $0.region_id == region.id }
            let lookup = Dictionary(uniqueKeysWithValues:live.map { ($0.node_id,$0.position) })
            for b in snapshot.bindings {
                if let target = lookup[b.node_id] {
                    let actual = CampusMapGeometry.point(b.position,through:candidate.map_to_region)
                    guard Swift.zip(actual,target).reduce(0.0,{ $0+pow($1.0-$1.1,2) }).squareRoot() <= 0.45 else { throw CampusError.corrupt }
                }
            }
        }
        guard fm.fileExists(atPath: directory.appendingPathComponent("environment.arworldmap").path) else { throw CampusError.corrupt }
        for b in snapshot.bindings {
            let photo = directory.appendingPathComponent("references/\(b.node_id).jpg")
            let json = directory.appendingPathComponent("references/\(b.node_id).json")
            guard fm.fileExists(atPath: photo.path), fm.fileExists(atPath: json.path) else { throw CampusError.corrupt }
        }
        return snapshot
    }
    /// Copy and verify native bytes before atomically publishing their graph reference.
    /// Replacement retains a logical ID and removes the previous native files after publication.
    @discardableResult public func saveCandidate(_ graph:CampusGraph,source:URL,candidate:CampusMapCandidate,makeDefault:Bool = false,replacing:Bool = false) throws -> CampusGraph {
        lock.lock();defer { lock.unlock() }
        var next = graph
        let existing = next.map_candidates.firstIndex { $0.id == candidate.id }
        guard let i = next.regions.firstIndex(where: { $0.id == candidate.region_id }),replacing == (existing != nil) else { throw CampusError.corrupt }
        let old = existing.map { next.map_candidates[$0] }
        if replacing {
            try recoverMapUpdates(graph.building_id)
            guard try load(graph.building_id).revision == graph.revision,old?.region_id == candidate.region_id else { throw CampusError.conflict }
        }
        var stored = candidate
        if let old {
            stored.file_id = UUID().uuidString
            stored.name = old.name;stored.protected = old.protected;stored.enabled = old.enabled
            stored.source_map_id = old.source_map_id;stored.verified = false
            next.map_candidates[existing!] = stored
        } else { next.map_candidates.append(stored) }
        let candidateIndex = existing ?? (next.map_candidates.count-1)
        next.regions[i].map_saved = true
        if makeDefault || next.regions[i].default_map_id == nil { next.regions[i].default_map_id = candidate.id }
        next.schema_version = 3;try next.validate()
        // Validate using the candidate ID rather than the temporary source folder name.
        try CampusFiles.verify(source)
        let manifest = try JSONDecoder().decode(CampusFiles.Manifest.self,from:Data(contentsOf:source.appendingPathComponent("files.json")))
        guard let hash = manifest.files.first(where: { $0.path == "environment.arworldmap" })?.sha256,
              candidate.world_map_sha256 == nil || candidate.world_map_sha256 == hash else { throw CampusError.corrupt }
        next.map_candidates[candidateIndex].world_map_sha256 = hash
        let snapshot = try JSONDecoder().decode(CampusRegionSnapshot.self,from:Data(contentsOf:source.appendingPathComponent("region.json")))
        try snapshot.validate(graph:next,region:next.regions[i],candidate:true)
        let target = try mapFileDirectory(buildingID:next.building_id,fileID:stored.fileID)
        let newBuilding = !fm.fileExists(atPath:try buildingURL(graph.building_id).path)
        try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard !fm.fileExists(atPath:target.path) else { throw CampusError.conflict }
        var journal:URL?
        if let old {
            let url = try buildingURL(graph.building_id).appendingPathComponent("map-updates/"+UUID().uuidString+".json")
            try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try CampusFiles.encode(MapUpdate(old_file_id:old.fileID,new_file_id:stored.fileID),to:url)
            journal = url
        }
        let saved:CampusGraph
        do {
            try fm.copyItem(at:source,to:target)
            _ = try verifyRegion(graph:next,region:next.regions[i],in:target)
            saved = try publish(next,newBuilding:newBuilding)
        } catch {
            if journal != nil { try? recoverMapUpdates(graph.building_id) }
            else { try? fm.removeItem(at:target) }
            if newBuilding,let building = try? buildingURL(graph.building_id) { try? fm.removeItem(at:building) }
            throw error
        }
        // Publication has succeeded: cleanup errors must not report the saved map as failed.
        // The journal retries cleanup on the next preparation/replacement after a crash.
        if journal != nil { try? recoverMapUpdates(graph.building_id) }
        return saved
    }
    // Publish an immutable version and then atomically update its small pointer.
    // A crash before pointer publication leaves the previously committed graph intact.
    @discardableResult public func save(_ graph: CampusGraph, regionSource: URL? = nil, regionID: String? = nil) throws -> CampusGraph {
        try publish(graph,regionSource:regionSource,regionID:regionID)
    }
    private func legacyCandidate(snapshot:CampusRegionSnapshot,source:URL,name:String) throws -> CampusMapCandidate {
        let manifest = try JSONDecoder().decode(CampusFiles.Manifest.self,from:Data(contentsOf:source.appendingPathComponent("files.json")))
        var candidate = CampusMapCandidate(regionID:snapshot.region_id,name:name,date:snapshot.saved_utc)
        candidate.world_map_sha256 = manifest.files.first(where: { $0.path == "environment.arworldmap" })?.sha256
        let cloudURL = source.appendingPathComponent("feature-points.json")
        if let size = try? cloudURL.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 16*1024*1024,
           let data = try? Data(contentsOf:cloudURL),let cloud = try? JSONDecoder().decode(CampusFeaturePointCloud.self,from:data) {
            for b in snapshot.bindings { candidate.node_coverage[b.node_id] = cloud.points.filter { hypot($0.x-b.position[0],$0.z-b.position[2]) <= 5 }.count }
        };return candidate
    }
    private func publish(_ graph:CampusGraph,regionSource:URL? = nil,regionID:String? = nil,newBuilding:Bool = false) throws -> CampusGraph {
        lock.lock(); defer { lock.unlock() }
        try graph.validate()
        let building = try buildingURL(graph.building_id)
        let existing = !newBuilding && fm.fileExists(atPath: building.path) ? try load(graph.building_id) : nil
        if let existing, existing.revision != graph.revision { throw CampusError.conflict }
        let oldDirectory = try? directory(graph.building_id)
        guard (regionSource == nil) == (regionID == nil) else { throw CampusError.corrupt }
        let versionID = UUID().uuidString
        let versions = building.appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        let staging = versions.appendingPathComponent(".partial-"+versionID, isDirectory: true)
        let final = versions.appendingPathComponent(versionID, isDirectory: true)
        var next = graph; next.schema_version = 3; next.revision += 1; next.updated_utc = ISO8601DateFormatter().string(from: Date())
        do {
            try fm.createDirectory(at:staging,withIntermediateDirectories:true)
            // Protect the last legacy snapshot even when a new candidate is supplied in this save.
            if let oldDirectory {
                for region in existing?.regions ?? [] where region.map_saved && region.default_map_id == nil {
                    let source = oldDirectory.appendingPathComponent("regions/"+region.id)
                    guard fm.fileExists(atPath:source.appendingPathComponent("environment.arworldmap").path),let index = next.regions.firstIndex(where: { $0.id == region.id }) else { continue }
                    let snapshot = try verifyRegion(graph:existing!,region:region,in:source)
                    let candidate = try legacyCandidate(snapshot:snapshot,source:source,name:"原始地图（受保护）")
                    let target = try candidateDirectory(buildingID:graph.building_id,candidateID:candidate.id)
                    try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                    try fm.copyItem(at:source,to:target);next.map_candidates.append(candidate)
                    next.regions[index].default_map_id = candidate.id
                }
            }
            let maps = staging.appendingPathComponent("regions", isDirectory: true)
            try fm.createDirectory(at: maps, withIntermediateDirectories: true)
            if let source = regionSource, let rid = regionID, let region = graph.region(rid) {
                _ = try verifyRegion(graph: graph, region: region, in: source)
                let snapshot = try JSONDecoder().decode(CampusRegionSnapshot.self,from:Data(contentsOf:source.appendingPathComponent("region.json")))
                let candidate = try legacyCandidate(snapshot:snapshot,source:source,name:"地图快照")
                let target = try candidateDirectory(buildingID:graph.building_id,candidateID:candidate.id)
                try fm.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                try fm.copyItem(at:source,to:target);next.map_candidates.append(candidate)
                if let index = next.regions.firstIndex(where: { $0.id == rid }) { next.regions[index].default_map_id = candidate.id }
            }
            let regionIDs = Set(graph.regions.map(\.id))
            for item in (try? fm.contentsOfDirectory(at: maps, includingPropertiesForKeys: nil)) ?? [] where !regionIDs.contains(item.lastPathComponent) {
                try fm.removeItem(at: item)
            }
            try next.validate()
            try CampusFiles.encode(next, to: staging.appendingPathComponent("graph.json"))
            // A previously exported backup may have been imported here; regenerate at export.
            for file in ["files.json", "backup.json"] {
                let url = staging.appendingPathComponent(file)
                if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            }
            // Recheck publication against another writer.
            if let oldDirectory, try directory(graph.building_id) != oldDirectory { throw CampusError.conflict }
            try fm.moveItem(at: staging, to: final)
            try CampusFiles.encode(Pointer(version_id: versionID), to: building.appendingPathComponent("current.json"))
            return next
        } catch { try? fm.removeItem(at: staging); throw error }
    }
    public func export(_ id: String, destination: URL, regionID: String? = nil,candidateID:String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        var graph = try prepareMaps(id)
        let source = try directory(id)
        var selectedRegionID = regionID
        if let candidateID {
            guard let candidate = graph.mapCandidate(candidateID),regionID == nil || regionID == candidate.region_id,
                  let index = graph.regions.firstIndex(where: { $0.id == candidate.region_id }) else { throw CampusError.corrupt }
            selectedRegionID = candidate.region_id
            graph.map_candidates = [candidate]
            graph.map_candidates[0].enabled = true
            graph.regions[index].default_map_id = candidateID
        }
        if let regionID = selectedRegionID {
            guard let region = graph.region(regionID) else { throw CampusError.corrupt }
            graph.regions = [region]
            graph.map_candidates = graph.map_candidates.filter { $0.region_id == regionID }
            graph.bindings = graph.bindings.filter { $0.region_id == regionID }
            let nodeIDs = Set(graph.bindings.map(\.node_id))
            graph.nodes = graph.nodes.filter { nodeIDs.contains($0.id) }
            graph.edges = graph.edges.filter { $0.kind == .walk && $0.region_id == regionID }
            let edgeIDs = Set(graph.edges.map(\.id)); graph.rooms = graph.rooms.filter { edgeIDs.contains($0.edge_id) }
            graph.floors = graph.floors.filter { $0.id == region.floor_id }
            graph.name = String((graph.name+" · "+region.name).prefix(120))
            try graph.validate()
        }
        for r in graph.regions {
            let candidates = graph.map_candidates.filter { $0.region_id == r.id }
            if candidates.isEmpty { _ = try verifyRegion(graph:graph,region:r,in:source.appendingPathComponent("regions/"+r.id)) }
            for c in candidates { _ = try verifyRegion(graph:graph,region:r,in:candidateDirectory(buildingID:id,candidateID:c.id)) }
        }
        let nativeSources = try Dictionary(uniqueKeysWithValues:graph.map_candidates.map { ($0.id,try candidateDirectory(buildingID:id,candidateID:$0.id)) })
        // Portable packages use logical IDs, retaining compatibility with earlier imports.
        for i in graph.map_candidates.indices { graph.map_candidates[i].file_id = nil }
        let temporary = fm.temporaryDirectory.appendingPathComponent("campus-export-"+UUID().uuidString)
        let package = temporary.appendingPathComponent("building-"+id)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        try fm.createDirectory(at: package.appendingPathComponent("regions"), withIntermediateDirectories: true)
        try CampusFiles.encode(graph, to: package.appendingPathComponent("graph.json"))
        try fm.createDirectory(at:package.appendingPathComponent("maps"),withIntermediateDirectories:true)
        for c in graph.map_candidates {
            try fm.copyItem(at:nativeSources[c.id]!,to:package.appendingPathComponent("maps/"+c.id))
        }
        for r in graph.regions where r.default_map_id == nil {
            try fm.copyItem(at:source.appendingPathComponent("regions/"+r.id),to:package.appendingPathComponent("regions/"+r.id))
        }
        try CampusFiles.encode(Backup(building_id: id), to: package.appendingPathComponent("backup.json"))
        try CampusFiles.manifest(package)
        try CampusFiles.verify(package)
        let manifest = try JSONDecoder().decode(CampusFiles.Manifest.self, from: Data(contentsOf: package.appendingPathComponent("files.json")))
        // Keep our exports inside the same size limits as our importer, including ZIP headers.
        let projected = manifest.files.reduce(22) { $0 + $1.bytes + 128 + 2 * ($1.path.utf8.count + package.lastPathComponent.utf8.count + 1) }
        guard projected < 511 * 1024 * 1024 else { throw CampusError.invalid("完整备份超过 512 MB，请先减少区域参考照片，或分楼栋采集。") }
        try ProbeZip.create(directory: package, destination: destination)
    }
    public func importGraph(_ url: URL) throws -> CampusGraph {
        lock.lock(); defer { lock.unlock() }
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 10 * 1024 * 1024 else { throw CampusError.corrupt }
        var graph = try JSONDecoder().decode(CampusGraph.self,from:Data(contentsOf:url)); try graph.validate()
        if fm.fileExists(atPath:try buildingURL(graph.building_id).path) { graph.building_id = UUID().uuidString; graph.name = String(graph.name.prefix(105))+"（路网副本）" }
        graph.revision = 0;graph.map_candidates = []
        for i in graph.regions.indices { graph.regions[i].default_map_id = nil }
        return try save(graph)
    }
    public func importBackup(_ url: URL, validateMap: ((URL, CampusRegionSnapshot) throws -> Void)? = nil) throws -> CampusGraph {
        let temp = fm.temporaryDirectory.appendingPathComponent("campus-import-"+UUID().uuidString)
        defer { try? fm.removeItem(at: temp) }
        let package = try CampusBackupZIP.extract(url, to: temp)
        return try importPackage(package, validateMap: validateMap)
    }
    /// Recover an old regional snapshot as a candidate without replacing today's logical graph.
    public func importCandidateBackup(_ url:URL,buildingID:String,regionID:String,validateMap:((URL,CampusRegionSnapshot) throws -> Void)? = nil) throws -> CampusGraph {
        lock.lock();defer { lock.unlock() }
        let temp = fm.temporaryDirectory.appendingPathComponent("candidate-import-"+UUID().uuidString)
        defer { try? fm.removeItem(at:temp) }
        let package = try CampusBackupZIP.extract(url,to:temp);try CampusFiles.verify(package)
        let backup = try JSONDecoder().decode(Backup.self,from:Data(contentsOf:package.appendingPathComponent("backup.json")))
        let sourceGraph = try JSONDecoder().decode(CampusGraph.self,from:Data(contentsOf:package.appendingPathComponent("graph.json")))
        try sourceGraph.validate()
        guard backup.schema_version == 1,backup.kind == "campus_network_backup",backup.building_id == sourceGraph.building_id,
              let sourceRegion = sourceGraph.region(regionID) else { throw CampusError.invalid("备份没有这个区域编号，请选择同一路网的区域备份。") }
        let originalID = sourceRegion.default_map_id
        let source = package.appendingPathComponent(sourceGraph.mapCandidate(originalID).map { "maps/"+$0.fileID } ?? "regions/"+regionID)
        var snapshot = try verifyRegion(graph:sourceGraph,region:sourceRegion,in:source)
        try validateMap?(source.appendingPathComponent("environment.arworldmap"),snapshot)
        let graph = try prepareMaps(buildingID)
        guard graph.region(regionID) != nil else { throw CampusError.corrupt }
        let fit = try CampusMapGeometry.fit(source:snapshot.bindings,target:graph.bindings.filter { $0.region_id == regionID })
        let staged = temp.appendingPathComponent("candidate");try fm.copyItem(at:source,to:staged)
        snapshot.building_id = buildingID
        try CampusFiles.encode(snapshot,to:staged.appendingPathComponent("region.json"));try CampusFiles.manifest(staged)
        var coverage:[String:Int] = [:]
        if let data = try? Data(contentsOf:staged.appendingPathComponent("feature-points.json")),let cloud = try? JSONDecoder().decode(CampusFeaturePointCloud.self,from:data) {
            for b in graph.bindings where b.region_id == regionID {
                let p = CampusMapGeometry.point(b.position,through:CampusMapGeometry.inverse(fit.transform))
                coverage[b.node_id] = cloud.points.filter { hypot($0.x-p[0],$0.z-p[2]) <= 5 }.count
            }
        }
        var candidate = CampusMapCandidate(regionID:regionID,name:"导入旧图 · "+String(snapshot.saved_utc.prefix(16)),date:snapshot.saved_utc,lighting:sourceGraph.mapCandidate(originalID)?.lighting ?? .other,transform:fit.transform,coverage:coverage)
        let localNodes = Set(graph.bindings.filter { $0.region_id == regionID }.map(\.node_id))
        candidate.preferred_node_ids = sourceGraph.mapCandidate(originalID)?.preferred_node_ids?.filter { localNodes.contains($0) }
        candidate.suggested_node_ids = sourceGraph.mapCandidate(originalID)?.suggested_node_ids?.filter { localNodes.contains($0) }
        return try saveCandidate(graph,source:staged,candidate:candidate)
    }
    public func importPackage(_ package: URL, validateMap: ((URL, CampusRegionSnapshot) throws -> Void)? = nil) throws -> CampusGraph {
        lock.lock(); defer { lock.unlock() }
        try CampusFiles.verify(package)
        let backup = try JSONDecoder().decode(Backup.self, from: Data(contentsOf: package.appendingPathComponent("backup.json")))
        var graph = try JSONDecoder().decode(CampusGraph.self, from: Data(contentsOf: package.appendingPathComponent("graph.json")))
        try graph.validate()
        guard backup.schema_version == 1, backup.kind == "campus_network_backup", backup.building_id == graph.building_id else { throw CampusError.corrupt }
        for r in graph.regions {
            let candidates = graph.map_candidates.filter { $0.region_id == r.id }
            let directories = candidates.isEmpty ? [package.appendingPathComponent("regions/"+r.id)] : candidates.map { package.appendingPathComponent("maps/"+$0.fileID) }
            for dir in directories {
                let snapshot = try verifyRegion(graph:graph,region:r,in:dir)
                try validateMap?(dir.appendingPathComponent("environment.arworldmap"),snapshot)
            }
        }
        // Imports never overwrite an existing building, even if names/IDs match.
        let isCopy = fm.fileExists(atPath: try buildingURL(graph.building_id).path)
        if isCopy { graph.building_id = UUID().uuidString; graph.name = String(graph.name.prefix(105)) + "（导入副本）" }
        let building = try buildingURL(graph.building_id), versionID = UUID().uuidString
        let versions = building.appendingPathComponent("versions")
        let staging = versions.appendingPathComponent(".partial-"+versionID)
        let final = versions.appendingPathComponent(versionID)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: package, to: staging)
            if isCopy {
                let regionDirs = graph.regions.filter { $0.default_map_id == nil }.map { staging.appendingPathComponent("regions/"+$0.id) }
                let mapDirs = graph.map_candidates.map { staging.appendingPathComponent("maps/"+$0.fileID) }
                for dir in regionDirs+mapDirs {
                    var snapshot = try JSONDecoder().decode(CampusRegionSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("region.json")))
                    snapshot.building_id = graph.building_id
                    try CampusFiles.encode(snapshot, to: dir.appendingPathComponent("region.json")); try CampusFiles.manifest(dir)
                }
            }
            let stagedMaps = staging.appendingPathComponent("maps")
            if fm.fileExists(atPath:stagedMaps.path) { try fm.moveItem(at:stagedMaps,to:mapsDirectory(graph.building_id)) }
            graph.revision += 1; graph.updated_utc = ISO8601DateFormatter().string(from: Date())
            try CampusFiles.encode(graph, to: staging.appendingPathComponent("graph.json"))
            for name in ["backup.json", "files.json"] { try fm.removeItem(at: staging.appendingPathComponent(name)) }
            try fm.moveItem(at: staging, to: final)
            try CampusFiles.encode(Pointer(version_id: versionID), to: building.appendingPathComponent("current.json"))
            return graph
        } catch { try? fm.removeItem(at: building); throw error }
    }
}
