import Foundation

public enum LiDARScanRole: String, Codable, CaseIterable {
    case map, query
    public var title: String { self == .map ? "建图扫描" : "独立查询扫描" }
    /// Legacy schema-1 limits, kept for the stage-one capture tool and old packages.
    public var frameLimit: Int { frameLimit(schemaVersion:1) }
    /// Schema 2 lifts the map limit for keyframe-gated capture; it remains a safety cap,
    /// not a product stop condition. Queries stay short.
    public func frameLimit(schemaVersion: Int) -> Int {
        switch (self, schemaVersion) {
        case (.map, 2): return LiDARScanLimits.mapFramesV2
        case (.map, _): return 100
        case (.query, 2): return LiDARScanLimits.queryFramesV2
        case (.query, _): return 24
        }
    }
}

/// Safety caps shared by the writer, the Swift validator and Tools/lidar_data.py.
public enum LiDARScanLimits {
    public static let mapFramesV2 = 600
    /// Raw bytes per scan directory (depth, confidence, JPEG and metadata), schema 2.
    public static let rawBytesV2 = 1_500_000_000
    public static let maxFrameIndex = 999
    /// Voxel cap of one navigation map (10 cm voxels; budget, geometry.f32 and validation).
    /// A map grows over supplement sessions; each session keeps its own frame and raw limits.
    public static let mapVoxelsV3 = 400_000
    /// Query frames per scan for schema 2 (the person chooses 16…64, default 32); schema 1 stays 24.
    public static let queryFramesV2 = 64
}

/// Native capturedImage orientation, integer pixel centers. Depth is optical Z,
/// not Euclidean distance. Matrices in JSON are row-major, camera looks along -Z.
public struct LiDARCalibration: Codable, Equatable {
    public var width: Int, height: Int, image_width: Int, image_height: Int
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public init(width: Int, height: Int, imageWidth: Int, imageHeight: Int,
                fx: Double, fy: Double, cx: Double, cy: Double) {
        self.width = width; self.height = height; image_width = imageWidth; image_height = imageHeight
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
    }
    public func validate() throws {
        guard width > 0, height > 0, width <= 2048, height <= 2048,
              image_width > 0, image_height > 0, image_width <= 8192, image_height <= 8192,
              [fx,fy,cx,cy].allSatisfy(\.isFinite), fx > 0, fy > 0,
              cx >= 0, cy >= 0, cx < Double(image_width), cy < Double(image_height) else {
            throw LiDARScanError.invalid("相机内参或深度尺寸无效")
        }
    }
    public func point(u: Int, v: Int, depth: Double, cameraToSession t: [[Double]]) -> ProbePoint {
        // ARKit's intrinsics are scaled directly to the depth image, as in Apple's
        // sceneDepth sample. Neither depth nor RGB is rotated to portrait for storage.
        let sx = Double(width)/Double(image_width), sy = Double(height)/Double(image_height)
        let p = [(Double(u)-cx*sx)/(fx*sx)*depth,
                 -(Double(v)-cy*sy)/(fy*sy)*depth, -depth]
        let q = (0..<3).map { r in (0..<3).reduce(t[r][3]) { $0 + t[r][$1]*p[$1] } }
        return ProbePoint(q[0],q[1],q[2])
    }
}

public struct LiDARFrame: Codable, Equatable {
    public var index: Int
    public var timestamp: Double
    public var camera_to_session: [[Double]]
    public var calibration: LiDARCalibration
    public var valid_fraction: Double
    public var exposure_duration: Double
    public var exposure_offset: Double
    public var tracking: String = "normal"
    public init(index: Int, timestamp: Double, transform: [[Double]], calibration: LiDARCalibration,
                validFraction: Double, exposureDuration: Double = 0, exposureOffset: Double = 0) {
        self.index = index; self.timestamp = timestamp; camera_to_session = transform
        self.calibration = calibration; valid_fraction = validFraction
        exposure_duration = exposureDuration; exposure_offset = exposureOffset
    }
    public var folder: String { String(format:"frames/%04d", index) }
    public func validate() throws {
        try calibration.validate()
        guard index >= 0, index <= LiDARScanLimits.maxFrameIndex, timestamp.isFinite, timestamp >= 0,
              RigidMatrix.valid(camera_to_session), valid_fraction.isFinite,
              (0...1).contains(valid_fraction), exposure_duration.isFinite, exposure_offset.isFinite,
              tracking == "normal" else { throw LiDARScanError.invalid("帧坐标或质量信息无效") }
    }
}

public struct LiDARScanManifest: Codable {
    public var schema_version = 1
    public var kind = "lidar_geometry_scan"
    public var scan_id: String, session_id: String, label: String, role: LiDARScanRole
    public var building_id: String, region_id: String, region_name: String, lighting: String
    public var created_utc: String
    public var initial_world_map_used = false
    public var coordinate_system = "ARKit_Y_up_camera_minus_Z_row_major_meters"
    public var depth_encoding = "float32_little_endian_optical_z_meters"
    public var confidence_encoding = "uint8_0_low_1_medium_2_high"
    public var image_orientation = "native_capturedImage_no_rotation"
    public var depth_source = "ARFrame.sceneDepth_unsmoothed"
    public var route_alignment = "unbound_independent_session"
    public var state = "recording"
    public var frames: [LiDARFrame] = []
    public var frameLimit: Int { role.frameLimit(schemaVersion:schema_version) }
    public var end_reason: String?
    public var finished_utc: String?
    /// Set for a supplement scan of an existing map. Frame poses stay in this scan's own session;
    /// `map_from_session` (row-major) is the manually confirmed alignment that moved them into the map.
    public var supplement_of_map_id: String?
    public var map_from_session: [[Double]]?
    public var hardware: String
    public var app_version: String
    public init(role: LiDARScanRole, label: String, buildingID: String, regionID: String,
                regionName: String, lighting: String, hardware: String, appVersion: String) {
        scan_id = UUID().uuidString; session_id = UUID().uuidString; self.role = role; self.label = label
        building_id = buildingID; region_id = regionID; region_name = regionName; self.lighting = lighting
        created_utc = ISO8601DateFormatter().string(from: Date()); self.hardware = hardware; app_version = appVersion
    }
    public func validate() throws {
        guard [1,2].contains(schema_version), kind == "lidar_geometry_scan", UUID(uuidString:scan_id) != nil,
              UUID(uuidString:session_id) != nil, !initial_world_map_used,
              frames.count <= frameLimit, route_alignment == "unbound_independent_session",
              coordinate_system == "ARKit_Y_up_camera_minus_Z_row_major_meters",
              depth_encoding == "float32_little_endian_optical_z_meters",
              confidence_encoding == "uint8_0_low_1_medium_2_high",
              image_orientation == "native_capturedImage_no_rotation",
              depth_source == "ARFrame.sceneDepth_unsmoothed",
              Set(frames.map(\.index)).count == frames.count,
              (supplement_of_map_id == nil) == (map_from_session == nil),
              supplement_of_map_id.map({ UUID(uuidString:$0) != nil && role == .map }) ?? true,
              map_from_session.map(RigidMatrix.valid) ?? true else {
            throw LiDARScanError.invalid("扫描来源或会话隔离信息不符")
        }
        for (i,f) in frames.enumerated() {
            try f.validate()
            guard f.index == i, i == 0 || f.timestamp > frames[i-1].timestamp else {
                throw LiDARScanError.invalid("帧编号或时间顺序无效")
            }
        }
    }
}

public enum LiDARScanError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

public struct LiDARDepthObservation: Equatable {
    public var point: ProbePoint
    /// Optical-axis depth in meters.
    public var depth: Double
    /// 1 medium, 2 high.
    public var confidence: UInt8
    public init(point: ProbePoint, depth: Double, confidence: UInt8) { self.point = point; self.depth = depth; self.confidence = confidence }
}

public enum LiDARGeometry {
    public static func packedRows(_ bytes: Data, rowBytes: Int, height: Int, stride: Int) throws -> Data {
        guard rowBytes > 0, height > 0, stride >= rowBytes,
              rowBytes <= 33_554_432, height <= 8192, bytes.count >= stride*height else {
            throw LiDARScanError.invalid("深度缓冲区长度不符")
        }
        var result = Data(capacity:rowBytes*height)
        for y in 0..<height { result.append(bytes[(y*stride)..<(y*stride+rowBytes)]) }
        return result
    }
    /// Same sampling and filters as points(), keeping per-point depth and confidence for
    /// quality-aware budgets.
    public static func observations(depth: Data, confidence: Data, frame: LiDARFrame, pixelStride: Int = 4) throws -> [LiDARDepthObservation] {
        try frame.validate()
        let c = frame.calibration
        guard depth.count == c.width*c.height*4, confidence.count == c.width*c.height,
              pixelStride > 0 else { throw LiDARScanError.invalid("深度或置信度数据不完整") }
        return depth.withUnsafeBytes { raw in
            var result: [LiDARDepthObservation] = []
            for v in stride(from:0,to:c.height,by:pixelStride) {
                for u in stride(from:0,to:c.width,by:pixelStride) {
                    let i = v*c.width+u
                    let d = Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))))
                    if confidence[i] >= 1, confidence[i] <= 2, d.isFinite, d >= 0.2, d <= 4.5 {
                        result.append(LiDARDepthObservation(point:c.point(u:u,v:v,depth:d,cameraToSession:frame.camera_to_session),depth:d,confidence:confidence[i]))
                    }
                }
            }
            return result
        }
    }
    public static func points(depth: Data, confidence: Data, frame: LiDARFrame, pixelStride: Int = 4) throws -> [ProbePoint] {
        try frame.validate()
        let c = frame.calibration
        guard depth.count == c.width*c.height*4, confidence.count == c.width*c.height,
              pixelStride > 0 else { throw LiDARScanError.invalid("深度或置信度数据不完整") }
        return depth.withUnsafeBytes { raw in
            var result: [ProbePoint] = []
            for v in stride(from:0,to:c.height,by:pixelStride) {
                for u in stride(from:0,to:c.width,by:pixelStride) {
                    let i = v*c.width+u
                    let bits = UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))
                    let d = Double(Float(bitPattern:bits))
                    if confidence[i] >= 1, confidence[i] <= 2, d.isFinite, d >= 0.2, d <= 4.5 {
                        result.append(c.point(u:u,v:v,depth:d,cameraToSession:frame.camera_to_session))
                    }
                }
            }
            return result
        }
    }
}

/// Confined to a single serial IO queue by the capture controller.
/// A draft manifest is updated after each committed frame, so interrupted trials
/// remain inspectable. Only finish() creates the checksum manifest.
public final class LiDARScanWriter {
    public let directory: URL
    public private(set) var manifest: LiDARScanManifest
    private var voxels: [String:ProbePoint] = [:]
    /// Bytes of frame payloads written so far; schema 2 refuses frames past LiDARScanLimits.rawBytesV2.
    public private(set) var rawBytes = 0
    public init(root: URL, manifest: LiDARScanManifest) throws {
        try manifest.validate(); self.manifest = manifest
        directory = root.appendingPathComponent("\(manifest.role.rawValue)-\(manifest.scan_id)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try persist()
    }
    private func json<T:Encodable>(_ value:T, at url:URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(value).write(to:url,options:.atomic)
    }
    private func persist() throws { try json(manifest,at:directory.appendingPathComponent("scan.json")) }
    public func append(frame: LiDARFrame, depth: Data, confidence: Data, jpeg: Data) throws -> Int {
        guard manifest.state == "recording", frame.index == manifest.frames.count,
              manifest.frames.count < manifest.frameLimit, !jpeg.isEmpty,
              manifest.frames.last.map({frame.timestamp > $0.timestamp}) ?? true else {
            throw LiDARScanError.invalid("扫描已结束或帧顺序错误")
        }
        if manifest.schema_version >= 2 && rawBytes+depth.count+confidence.count+jpeg.count > LiDARScanLimits.rawBytesV2 {
            throw LiDARScanError.invalid("原始数据已达到本张图的空间上限")
        }
        let points = try LiDARGeometry.points(depth:depth,confidence:confidence,frame:frame)
        let folder = directory.appendingPathComponent(frame.folder)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        do {
            try depth.write(to:folder.appendingPathComponent("depth.f32"),options:.atomic)
            try confidence.write(to:folder.appendingPathComponent("confidence.u8"),options:.atomic)
            try jpeg.write(to:folder.appendingPathComponent("rgb.jpg"),options:.atomic)
            for p in points {
                let key = "\(Int(floor(p.x/0.04))),\(Int(floor(p.y/0.04))),\(Int(floor(p.z/0.04)))"
                if voxels.count < 250_000 || voxels[key] != nil { voxels[key] = p }
            }
            manifest.frames.append(frame); try persist()
            rawBytes += depth.count+confidence.count+jpeg.count
        } catch { try? FileManager.default.removeItem(at:folder); throw error }
        return voxels.count
    }
    public func event(_ name:String, timestamp:Double, details:String = "") throws {
        let url = directory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) { FileManager.default.createFile(atPath:url.path,contents:nil) }
        let handle = try FileHandle(forWritingTo:url); defer { try? handle.close() }
        try handle.seekToEnd()
        let data = try JSONSerialization.data(withJSONObject:["event":name,"timestamp":timestamp,"details":details],options:.sortedKeys)
        try handle.write(contentsOf:data+Data([10]))
    }
    public func finish(reason:String, valid:Bool) throws -> LiDARScanManifest {
        guard manifest.state == "recording" else { return manifest }
        manifest.state = valid && manifest.frames.count >= 3 ? "complete" : "interrupted"
        manifest.end_reason = reason; manifest.finished_utc = ISO8601DateFormatter().string(from:Date())
        let header = "ply\nformat ascii 1.0\ncomment preview only, confidence >= medium, 0.2 to 4.5m, 4cm voxel, capped 250000\nelement vertex \(voxels.count)\nproperty float x\nproperty float y\nproperty float z\nend_header\n"
        let ply = header + voxels.sorted(by:{$0.key < $1.key}).map { String(format:"%.4f %.4f %.4f\n",$0.value.x,$0.value.y,$0.value.z) }.joined()
        try Data(ply.utf8).write(to:directory.appendingPathComponent("preview.ply"),options:.atomic)
        try persist(); try ProbeIO.makeManifest(at:directory); return manifest
    }
}


/// Sampling still has a fixed capacity. Report refused new coverage instead of
/// silently pretending it entered the map; raw frame persistence is independent.
public enum LiDARCaptureBudget {
    public struct Batch {
        public let rejectedSamples: Int
        public let rejectedVoxels: Int
        public let rejectedByBlock: [String:Int]
        public let addedVoxels: Int
    }
    public static func ingest(_ points:[ProbePoint], into cloud:inout [LiDARVoxelKey:ProbePoint],
                              limit:Int = 60_000, voxelSize:Double = 0.10) -> Batch {
        var rejectedSamples = 0,added = 0,seen = Set<LiDARVoxelKey>(),blocks = [String:Int]()
        for point in points where point.array.allSatisfy({ $0.isFinite && abs($0) < 1000 }) {
            let key = LiDARVoxelKey(point,size:voxelSize)
            if cloud[key] != nil { cloud[key] = point }
            else if cloud.count < max(0,limit) { cloud[key] = point;added += 1 }
            else {
                rejectedSamples += 1
                if seen.insert(key).inserted {
                    let block = "\(Int(floor(point.x/2))),\(Int(floor(point.z/2)))"
                    blocks[block,default:0] += 1
                }
            }
        }
        return Batch(rejectedSamples:rejectedSamples,rejectedVoxels:seen.count,rejectedByBlock:blocks,addedVoxels:added)
    }
}

// MARK: - Landmark geometry (stage 2a)

/// One frame in which the user confirmed a plate: the box is in native capturedImage pixels.
public struct LiDARLandmarkSample {
    public var frame: LiDARFrame
    public var depth: Data
    public var confidence: Data
    /// [x, y, width, height] in native (unrotated) image pixels, origin top-left.
    public var nativeBox: [Double]
    public init(frame: LiDARFrame, depth: Data, confidence: Data, nativeBox: [Double]) {
        self.frame = frame; self.depth = depth; self.confidence = confidence; self.nativeBox = nativeBox
    }
}

/// A camera ray through the plate center and a wall plane, in session coordinates.
public struct LiDARPlaneSample: Equatable {
    public var cameraOrigin: ProbePoint
    public var rayDirection: ProbePoint
    public var planePoint: ProbePoint
    public var planeNormal: ProbePoint
    public init(cameraOrigin: ProbePoint, rayDirection: ProbePoint, planePoint: ProbePoint, planeNormal: ProbePoint) {
        self.cameraOrigin = cameraOrigin; self.rayDirection = rayDirection; self.planePoint = planePoint; self.planeNormal = planeNormal
    }
}

public struct LiDARLandmarkGeometryResult: Codable, Equatable {
    /// measured or unknown. Unknown keeps the text usable but claims no position.
    public var status: String
    public var center: ProbePoint?
    /// Horizontal unit normal pointing from the wall toward the cameras.
    public var normal: ProbePoint?
    /// Largest distance of a per-frame center from the mean; consistency, not absolute accuracy.
    public var spread_m: Double?
    public var observations: Int
    public var reason: String
    /// Default for a landmark saved before or without a 3D measurement.
    public static func unknown(_ reason: String = "not_measured", observations: Int = 0) -> LiDARLandmarkGeometryResult {
        LiDARLandmarkGeometryResult(status:"unknown",center:nil,normal:nil,spread_m:nil,observations:observations,reason:reason)
    }
}

public enum LiDARLandmarkGeometry {
    /// Default entrance for a measured wall plate: the plate center dropped to the floor and
    /// moved `offset` along the wall normal into the corridor. A suggestion for the user to
    /// accept or move, never a measured door position. nil when the plate has no geometry.
    public static func suggestedEntrance(_ geometry: LiDARLandmarkGeometryResult, floorY: Double, offset: Double = 0.5) -> ProbePoint? {
        guard geometry.status == "measured",let c = geometry.center,let n = geometry.normal,floorY.isFinite else { return nil }
        let h = hypot(n.x,n.z);guard h > 1e-6 else { return nil }
        return ProbePoint(c.x+n.x/h*offset,floorY,c.z+n.z/h*offset)
    }
    /// Vision boxes for orientation .right (portrait-held phone) are normalized in the
    /// rotated image with origin bottom-left. Returns the native-pixel box, origin top-left.
    public static func nativeBox(visionBox b: [Double], imageWidth W: Int, imageHeight H: Int) -> [Double] {
        // Displayed image is native rotated 90° clockwise: display = (H - 1 - y, x).
        let dx0 = b[0]*Double(H),dx1 = (b[0]+b[2])*Double(H)
        let dyTop0 = (1-b[1]-b[3])*Double(W),dyTop1 = (1-b[1])*Double(W)
        // native x = display y (top-left origin); native y = H - display x.
        return [dyTop0,Double(H)-dx1,dyTop1-dyTop0,dx1-dx0]
    }
    struct PerFrame { let center: ProbePoint; let normal: ProbePoint }
    /// Fits the wall around the box in each frame and intersects the ray through the box
    /// center with it. Requires >= minFrames frames agreeing within maxSpread.
    public static func measure(_ samples: [LiDARLandmarkSample], minFrames: Int = 2, maxSpread: Double = 0.10) -> LiDARLandmarkGeometryResult {
        var frames = [PerFrame](),failures = [String]()
        for s in samples {
            do {
                if let f = try single(s) { frames.append(f) } else { failures.append("wall_not_measured") }
            } catch { failures.append("invalid_frame") }
        }
        return aggregate(frames,failures:failures,minFrames:minFrames,maxSpread:maxSpread)
    }
    /// Same rules for devices without depth: each sample is the ray through the plate center
    /// plus a wall plane from any source (for example ARCore vertical-plane hit tests).
    public static func measure(planes: [LiDARPlaneSample], minFrames: Int = 2, maxSpread: Double = 0.10) -> LiDARLandmarkGeometryResult {
        var frames = [PerFrame](),failures = [String]()
        for s in planes { if let f = intersect(s) { frames.append(f) } else { failures.append("wall_not_measured") } }
        return aggregate(frames,failures:failures,minFrames:minFrames,maxSpread:maxSpread)
    }
    static func aggregate(_ frames: [PerFrame], failures: [String], minFrames: Int, maxSpread: Double) -> LiDARLandmarkGeometryResult {
        func unknown(_ reason: String) -> LiDARLandmarkGeometryResult {
            LiDARLandmarkGeometryResult(status:"unknown",center:nil,normal:nil,spread_m:nil,observations:frames.count,reason:reason)
        }
        guard frames.count >= minFrames else { return unknown(frames.isEmpty ? (failures.first ?? "no_frames") : "too_few_measured_frames") }
        let n = Double(frames.count)
        let c = ProbePoint(frames.reduce(0) { $0+$1.center.x }/n,frames.reduce(0) { $0+$1.center.y }/n,frames.reduce(0) { $0+$1.center.z }/n)
        let spread = frames.map { sqrt(pow($0.center.x-c.x,2)+pow($0.center.y-c.y,2)+pow($0.center.z-c.z,2)) }.max() ?? 0
        var nx = frames.reduce(0) { $0+$1.normal.x },nz = frames.reduce(0) { $0+$1.normal.z }
        let len = hypot(nx,nz)
        guard len > 0.5*n else { return unknown("normals_disagree") }
        nx /= len;nz /= len
        guard spread <= maxSpread else {
            return LiDARLandmarkGeometryResult(status:"unknown",center:nil,normal:nil,spread_m:spread,observations:frames.count,reason:"frames_disagree")
        }
        return LiDARLandmarkGeometryResult(status:"measured",center:c,normal:ProbePoint(nx,0,nz),spread_m:spread,observations:frames.count,
                                           reason:"consistency_only_not_absolute_accuracy")
    }
    static func single(_ s: LiDARLandmarkSample) throws -> PerFrame? {
        try s.frame.validate()
        let c = s.frame.calibration,t = s.frame.camera_to_session,b = s.nativeBox
        guard b.count == 4,b.allSatisfy(\.isFinite),b[2] > 0,b[3] > 0,
              s.depth.count == c.width*c.height*4,s.confidence.count == c.width*c.height else { return nil }
        let sx = Double(c.width)/Double(c.image_width),sy = Double(c.height)/Double(c.image_height)
        // Wall region: the box grown by half its size each side, in depth pixels.
        let u0 = max(0,Int((b[0]-b[2]/2)*sx)),u1 = min(c.width-1,Int((b[0]+b[2]*1.5)*sx))
        let v0 = max(0,Int((b[1]-b[3]/2)*sy)),v1 = min(c.height-1,Int((b[1]+b[3]*1.5)*sy))
        guard u1 > u0,v1 > v0 else { return nil }
        var pts = [ProbePoint]()
        s.depth.withUnsafeBytes { raw in
            for v in v0...v1 { for u in u0...u1 {
                let i = v*c.width+u
                let d = Double(Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:i*4,as:UInt32.self))))
                if s.confidence[i] >= 1,d.isFinite,d >= 0.2,d <= 4.5 { pts.append(c.point(u:u,v:v,depth:d,cameraToSession:t)) }
            } }
        }
        guard pts.count >= 8 else { return nil }
        // Plane by PCA: normal = eigenvector of the smallest eigenvalue of the covariance.
        let n = Double(pts.count)
        let m = ProbePoint(pts.reduce(0) { $0+$1.x }/n,pts.reduce(0) { $0+$1.y }/n,pts.reduce(0) { $0+$1.z }/n)
        var cov = [[Double]](repeating:[0,0,0],count:3)
        for p in pts { let d = [p.x-m.x,p.y-m.y,p.z-m.z];for i in 0..<3 { for j in 0..<3 { cov[i][j] += d[i]*d[j]/n } } }
        guard var normal = smallestEigenvector(cov) else { return nil }
        // Residual check: a box over a door gap or glass gives a poor plane.
        let rms = sqrt(pts.reduce(0) { $0+pow(($1.x-m.x)*normal[0]+($1.y-m.y)*normal[1]+($1.z-m.z)*normal[2],2) }/n)
        guard rms <= 0.03,abs(normal[1]) <= 0.3 else { return nil }
        // Ray through the box center.
        let cu = (b[0]+b[2]/2)*sx,cv = (b[1]+b[3]/2)*sy
        let far = c.point(u:Int(cu.rounded()),v:Int(cv.rounded()),depth:1,cameraToSession:t)
        let camera = ProbePoint(t[0][3],t[1][3],t[2][3])
        return intersect(LiDARPlaneSample(cameraOrigin:camera,rayDirection:ProbePoint(far.x-camera.x,far.y-camera.y,far.z-camera.z),
                                          planePoint:m,planeNormal:ProbePoint(normal[0],normal[1],normal[2])))
    }
    /// Shared by every plane source: LiDAR depth on iPhone, or a detected vertical plane /
    /// hit test on devices without depth. Orients the normal toward the camera.
    static func intersect(_ s: LiDARPlaneSample) -> PerFrame? {
        let o = s.cameraOrigin,d = s.rayDirection,p = s.planePoint
        var n = [s.planeNormal.x,s.planeNormal.y,s.planeNormal.z]
        let nl = sqrt(n.reduce(0) { $0+$1*$1 })
        guard nl > 1e-9,[o,d,p].allSatisfy({ $0.array.allSatisfy(\.isFinite) }) else { return nil }
        n = n.map { $0/nl }
        guard abs(n[1]) <= 0.3 else { return nil }
        if (o.x-p.x)*n[0]+(o.y-p.y)*n[1]+(o.z-p.z)*n[2] < 0 { n = n.map { -$0 } }
        let denom = d.x*n[0]+d.y*n[1]+d.z*n[2]
        guard abs(denom) > 1e-6 else { return nil }
        let dl = sqrt(d.x*d.x+d.y*d.y+d.z*d.z)
        let k = ((p.x-o.x)*n[0]+(p.y-o.y)*n[1]+(p.z-o.z)*n[2])/denom
        guard k*dl > 0.2,k*dl < 4.5 else { return nil }
        let h = hypot(n[0],n[2])
        return PerFrame(center:ProbePoint(o.x+k*d.x,o.y+k*d.y,o.z+k*d.z),normal:ProbePoint(n[0]/h,0,n[2]/h))
    }
    /// Smallest-eigenvalue eigenvector of a symmetric 3x3 matrix by power iteration on the
    /// shifted matrix (trace*I - A).
    static func smallestEigenvector(_ a: [[Double]]) -> [Double]? {
        let tr = a[0][0]+a[1][1]+a[2][2]
        let b = (0..<3).map { i in (0..<3).map { j in (i == j ? tr : 0)-a[i][j] } }
        var v = [0.577,0.577,0.577]
        for _ in 0..<100 {
            var w = (0..<3).map { i in (0..<3).reduce(0.0) { $0+b[i][$1]*v[$1] } }
            let len = sqrt(w.reduce(0) { $0+$1*$1 });guard len > 1e-12 else { return nil }
            w = w.map { $0/len };v = w
        }
        return v
    }
}
