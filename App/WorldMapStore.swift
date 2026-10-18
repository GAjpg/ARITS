#if !targetEnvironment(macCatalyst)
import ARKit
import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct WorldMapMetadata: Codable {
    var schema_version = 1
    var map_id: String
    var name: String
    var created_utc: String
    var source_session_id: String
    var origin_anchor_id: String
    var origin_anchor_name: String
    var anchor_to_map: [[Double]]
    var route_to_anchor: [[Double]]
    var saved_mapping_status: String
    var feature_point_count: Int
    var app_version: String
    var reference_timestamp: Double
    var localization_provider = "arkit_world_map"
    var map_format = "ARWorldMap_secure_archive_ios_only"
    var physical_alignment_verified = false

    func validate(route: PortableRoute) throws {
        try route.validate()
        guard schema_version == 1, UUID(uuidString: map_id) != nil, map_id == route.route_id,
              UUID(uuidString: source_session_id) != nil, UUID(uuidString: origin_anchor_id) != nil,
              !origin_anchor_name.isEmpty, name == route.name, RigidMatrix.valid(anchor_to_map),
              RigidMatrix.valid(route_to_anchor), saved_mapping_status == "mapped", feature_point_count > 0,
              reference_timestamp.isFinite, reference_timestamp > 0,
              localization_provider == "arkit_world_map", map_format == "ARWorldMap_secure_archive_ios_only",
              physical_alignment_verified == false else {
            throw WorldMapDataError.invalidMetadata
        }
    }
}

struct SavedWorldMap {
    let directory: URL
    let metadata: WorldMapMetadata
    let route: PortableRoute
}

struct LoadedWorldMap {
    let package: SavedWorldMap
    let worldMap: ARWorldMap
}

// Only one raw pixel buffer is retained, rather than retaining a stream of ARFrames.
struct WorldMapReferenceFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
    let metadata: [String: Any]
    init(frame: ARFrame) {
        pixels = frame.capturedImage
        let k = frame.camera.intrinsics, size = frame.camera.imageResolution
        metadata = ["schema_version": 1, "purpose": "relocalization_view_guide_not_ground_truth",
            "timestamp": frame.timestamp, "clock_domain": "ARKit_session",
            "camera_to_session": matrixRows(frame.camera.transform),
            "image": ["width": Int(size.width), "height": Int(size.height), "rotation_deg": 0, "mirrored": false],
            "intrinsics": ["fx": Double(k.columns.0.x), "fy": Double(k.columns.1.y),
                "cx": Double(k.columns.2.x), "cy": Double(k.columns.2.y)],
            "pose_association": "same_ARFrame", "world_map_snapshot_association": "separate_ARSession_snapshot"]
    }
}

final class WorldMapStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "campus.probe.world-map", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    static var root: URL { ProbeIO.documents.appendingPathComponent("WorldMaps", isDirectory: true) }

    func packages() -> [SavedWorldMap] {
        let directories = (try? FileManager.default.contentsOfDirectory(at: Self.root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return directories.compactMap { url in
            guard url.lastPathComponent.hasPrefix("map-"),
                  let metadataData = try? Data(contentsOf: url.appendingPathComponent("map.json")),
                  let routeData = try? Data(contentsOf: url.appendingPathComponent("route.json")),
                  let metadata = try? JSONDecoder().decode(WorldMapMetadata.self, from: metadataData),
                  let route = try? JSONDecoder().decode(PortableRoute.self, from: routeData),
                  (try? metadata.validate(route: route)) != nil else { return nil }
            return SavedWorldMap(directory: url, metadata: metadata, route: route)
        }.sorted { $0.metadata.created_utc > $1.metadata.created_utc }
    }

    func save(map: ARWorldMap, metadata: WorldMapMetadata, route: PortableRoute, reference: WorldMapReferenceFrame,
              completion: @escaping @MainActor (Result<SavedWorldMap, Error>) -> Void) {
        queue.async { [self] in
            var staging: URL?
            do {
                try metadata.validate(route: route)
                guard map.anchors.contains(where: { $0.identifier.uuidString == metadata.origin_anchor_id
                    && $0.name == metadata.origin_anchor_name }) else { throw WorldMapDataError.missingAnchor }
                try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
                let temp = Self.root.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
                staging = temp
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(metadata).write(to: temp.appendingPathComponent("map.json"), options: .atomic)
                try encoder.encode(route).write(to: temp.appendingPathComponent("route.json"), options: .atomic)
                let archived = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                try archived.write(to: temp.appendingPathComponent("environment.arworldmap"), options: .atomic)
                let image = CIImage(cvPixelBuffer: reference.pixels)
                guard let cg = context.createCGImage(image, from: image.extent) else { throw CaptureError.encoding }
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CaptureError.encoding }
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85,
                    kCGImagePropertyOrientation: 1] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { throw CaptureError.encoding }
                try (data as Data).write(to: temp.appendingPathComponent("reference.jpg"), options: .atomic)
                try ProbeIO.json(reference.metadata, pretty: true).write(to: temp.appendingPathComponent("reference.json"), options: .atomic)
                try ProbeIO.makeManifest(at: temp)
                let final = Self.root.appendingPathComponent("map-\(metadata.map_id)", isDirectory: true)
                try FileManager.default.moveItem(at: temp, to: final); staging = nil
                let package = SavedWorldMap(directory: final, metadata: metadata, route: route)
                DispatchQueue.main.async { completion(.success(package)) }
            } catch {
                if let staging { try? FileManager.default.removeItem(at: staging) }
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func load(_ package: SavedWorldMap, completion: @escaping @MainActor (Result<LoadedWorldMap, Error>) -> Void) {
        queue.async {
            do {
                try Self.verify(package.directory)
                let decoder = JSONDecoder()
                let metadata = try decoder.decode(WorldMapMetadata.self, from: Data(contentsOf: package.directory.appendingPathComponent("map.json")))
                let route = try decoder.decode(PortableRoute.self, from: Data(contentsOf: package.directory.appendingPathComponent("route.json")))
                try metadata.validate(route: route)
                let bytes = try Data(contentsOf: package.directory.appendingPathComponent("environment.arworldmap"))
                guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: bytes),
                      let anchor = map.anchors.first(where: { $0.identifier.uuidString == metadata.origin_anchor_id
                        && $0.name == metadata.origin_anchor_name }) else { throw WorldMapDataError.missingAnchor }
                let matrix = matrixRows(anchor.transform)
                guard RigidMatrix.valid(matrix), (0..<4).allSatisfy({ row in
                    (0..<4).allSatisfy { abs(matrix[row][$0] - metadata.anchor_to_map[row][$0]) < 1e-4 }
                }) else { throw WorldMapDataError.invalidMetadata }
                let loaded = LoadedWorldMap(package: SavedWorldMap(directory: package.directory, metadata: metadata, route: route), worldMap: map)
                DispatchQueue.main.async { completion(.success(loaded)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func attach(_ package: SavedWorldMap, to run: RunRecorder, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async {
            do {
                try Self.verify(package.directory)
                try FileManager.default.copyItem(at: package.directory, to: run.directory.appendingPathComponent("input-world-map", isDirectory: true))
                DispatchQueue.main.async { completion(.success(())) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    func export(_ package: SavedWorldMap, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                try Self.verify(package.directory)
                let url = ProbeIO.documents.appendingPathComponent("Exports").appendingPathComponent(package.directory.lastPathComponent + ".zip")
                try ProbeZip.create(directory: package.directory, destination: url)
                DispatchQueue.main.async { completion(.success(url)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    static func importPackage(_ directory: URL) throws -> String {
        try CampusFiles.verify(directory)
        try verify(directory)
        let decoder = JSONDecoder()
        var metadata = try decoder.decode(WorldMapMetadata.self, from: Data(contentsOf: directory.appendingPathComponent("map.json")))
        var route = try decoder.decode(PortableRoute.self, from: Data(contentsOf: directory.appendingPathComponent("route.json")))
        try metadata.validate(route: route)
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: Data(contentsOf: directory.appendingPathComponent("environment.arworldmap"))),
              let anchor = map.anchors.first(where: { $0.identifier.uuidString == metadata.origin_anchor_id && $0.name == metadata.origin_anchor_name }) else { throw WorldMapDataError.missingAnchor }
        let transform = matrixRows(anchor.transform)
        guard RigidMatrix.valid(transform), (0..<4).allSatisfy({ r in (0..<4).allSatisfy { abs(transform[r][$0] - metadata.anchor_to_map[r][$0]) < 1e-4 } }) else { throw WorldMapDataError.invalidMetadata }
        let fm = FileManager.default; try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: root.appendingPathComponent("map-"+metadata.map_id).path) {
            let id = UUID().uuidString; metadata.map_id = id; route.route_id = id
            metadata.name = String(metadata.name.prefix(100)) + "（导入副本）"; route.name = metadata.name
        }
        let stage = root.appendingPathComponent(".partial-"+UUID().uuidString)
        do {
            try fm.copyItem(at: directory, to: stage)
            try CampusFiles.encode(metadata, to: stage.appendingPathComponent("map.json"))
            try CampusFiles.encode(route, to: stage.appendingPathComponent("route.json")); try CampusFiles.manifest(stage)
            try verify(stage)
            try fm.moveItem(at: stage, to: root.appendingPathComponent("map-"+metadata.map_id))
            return metadata.name
        } catch { try? fm.removeItem(at:stage); throw error }
    }

    private static func verify(_ directory: URL) throws {
        let required = Set(["map.json", "route.json", "environment.arworldmap", "reference.jpg", "reference.json"])
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("files.json"))) as? [String: Any]
        guard let entries = manifest?["files"] as? [[String: Any]], entries.count == required.count,
              Set(entries.compactMap { $0["path"] as? String }) == required else { throw WorldMapDataError.corruptedPackage }
        for entry in entries {
            guard let name = entry["path"] as? String, let size = entry["bytes"] as? Int,
                  let hash = entry["sha256"] as? String else { throw WorldMapDataError.corruptedPackage }
            let file = directory.appendingPathComponent(name)
            guard (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw WorldMapDataError.corruptedPackage }
            let bytes = try Data(contentsOf: file)
            guard bytes.count == size, size > 0, size <= 100 * 1024 * 1024,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else { throw WorldMapDataError.corruptedPackage }
        }
    }
}

func worldMappingName(_ status: ARFrame.WorldMappingStatus) -> String {
    switch status {
    case .notAvailable: return "not_available"
    case .limited: return "limited"
    case .extending: return "extending"
    case .mapped: return "mapped"
    @unknown default: return "unknown"
    }
}
func worldMappingTitle(_ status: ARFrame.WorldMappingStatus) -> String {
    switch status {
    case .notAvailable: return "尚未建图"
    case .limited: return "继续扫描"
    case .extending: return "地图扩展中"
    case .mapped: return "可保存地图"
    @unknown default: return "建图状态未知"
    }
}
#endif
