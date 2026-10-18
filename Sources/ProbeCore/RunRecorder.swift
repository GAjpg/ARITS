import Foundation
import CryptoKit
import Darwin

enum ProbeIO {
    static func hardwareIdentifier() -> String {
        var information = utsname()
        guard uname(&information) == 0 else { return "unknown" }
        return withUnsafeBytes(of: information.machine) { bytes in
            guard let address = bytes.bindMemory(to: CChar.self).baseAddress else { return "unknown" }
            return String(cString: address)
        }
    }
    static func json(_ value: Any, pretty: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])
    }
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var runs: URL { documents.appendingPathComponent("Runs", isDirectory: true) }
    static var previewRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARProbePreview", isDirectory: true)
    }
    static var previewRuns: URL { previewRoot.appendingPathComponent("PreviewRuns", isDirectory: true) }
    static func existingRuns(at root: URL = runs) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    static func makeManifest(at directory: URL) throws {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw ProbeArchiveError.unreadable
        }
        var entries: [[String: Any]] = []
        for case let file as URL in enumerator {
            guard file.standardizedFileURL != root.appendingPathComponent("files.json"), file.pathExtension != "partial",
                  (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let handle = try FileHandle(forReadingFrom: file)
            var hasher = SHA256(); var size = 0
            do {
                while let data = try handle.read(upToCount: 131_072), !data.isEmpty {
                    size += data.count; hasher.update(data: data)
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let normalized = file.standardizedFileURL
            guard normalized.pathComponents.starts(with: root.pathComponents) else { throw ProbeArchiveError.invalidPath }
            entries.append(["path": normalized.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/"),
                            "bytes": size, "sha256": hasher.finalize().map { String(format: "%02x", $0) }.joined()])
        }
        entries.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        try json(["schema_version": 1, "files": entries], pretty: true)
            .write(to: directory.appendingPathComponent("files.json"), options: .atomic)
    }
}

enum ProbeDataMode: String {
    case real = "real_ar_capture"
    case simulation = "simulation"
}

// IO state is confined to queue; UI callbacks/frame IDs are confined to MainActor.
// Initial setup happens before publication, and queued tasks retain this object.
final class RunRecorder: @unchecked Sendable {
    let runID: String
    let sessionID: String
    let directory: URL
    let dataMode: ProbeDataMode
    @MainActor var onFailure: ((String) -> Void)?
    private let queue = DispatchQueue(label: "campus.probe.writer", qos: .utility)
    private let gate = BoundedTaskGate(capacity: 120)
    private var handles: [String: FileHandle] = [:]
    private var closed = false
    private var errorMessage: String?
    private var captured = 0
    private var metadata: [String: Any]
    @MainActor private var nextFrame = 0

    init(sessionID: String, configuration: [String: Any], device: [String: Any], rootDirectory: URL = ProbeIO.runs,
         dataMode: ProbeDataMode = .real, additionalLogs: [String] = []) throws {
        guard additionalLogs.allSatisfy({ $0.range(of: "^[a-z][a-z0-9-]{0,63}\\.jsonl$", options: .regularExpression) != nil }) else {
            throw ProbeArchiveError.invalidPath
        }
        self.sessionID = sessionID
        self.dataMode = dataMode
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        runID = (dataMode == .simulation ? "preview-run-" : "run-") + formatter.string(from: Date()) + "-" + String(UUID().uuidString.prefix(6))
        directory = rootDirectory.appendingPathComponent(runID, isDirectory: true)
        metadata = device.merging(["schema_version": 1, "run_id": runID, "session_id": sessionID,
                    "initial_session_id": sessionID, "session_id_semantics": "initial_session_in_run_container",
                    "ar_sessions": [[String:Any]](),
                    "started_utc": ISO8601DateFormatter().string(from: Date()), "state": "recording",
                    "platform": device["platform"] ?? "iOS", "data_kind": dataMode.rawValue,
                    "is_real_ar_capture": dataMode == .real,
                    "hardware_identifier": ProbeIO.hardwareIdentifier(),
                    "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "unknown",
                    "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "unknown",
                    "sdk_source": dataMode == .real ? "native_ARKit_ARFrame" : "SceneKit_synthetic_preview", "configuration": configuration,
                    "coordinate_system": "arkit_right_handed_y_up_camera_forward_minus_z",
                    "image_geometry_verified": false, "ar_alignment_verified": false]) { _, right in right }
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("frames"), withIntermediateDirectories: true)
        try ProbeIO.json(metadata, pretty: true).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
        for name in Set(["poses.jsonl", "events.jsonl", "camera-events.jsonl", "anchors.jsonl"] + additionalLogs) {
            let file = directory.appendingPathComponent(name)
            guard fm.createFile(atPath: file.path, contents: nil) else { throw ProbeArchiveError.unreadable }
            handles[name] = try FileHandle(forWritingTo: file)
        }
        let template = "test_id,result,actual_m,estimated_m,drift_m,method,notes\n" + (1...15).map { "T\(String(format: "%02d", $0)),,,,,," }.joined(separator: "\n") + "\n"
        try Data(template.utf8).write(to: directory.appendingPathComponent("measurements.csv"), options: .atomic)
        append("events.jsonl", ["event": "recording_started", "session_id": sessionID])
    }

    deinit { for handle in handles.values { try? handle.close() } }
    @MainActor func newFrameID() -> String { nextFrame += 1; return String(format: "frame-%05d", nextFrame) }

    /// A run can contain multiple coordinate sessions. Legacy session_id always
    /// means the initial session; each geometry event carries ar_session_id.
    func beginARSession(_ id: String, generation: Int) {
        queue.async { [self] in
            guard !closed, errorMessage == nil else { return }
            var sessions = metadata["ar_sessions"] as? [[String:Any]] ?? []
            sessions.append(["ar_session_id":id,"generation":generation,
                             "started_uptime":ProcessInfo.processInfo.systemUptime])
            metadata["ar_sessions"] = sessions
            do { try ProbeIO.json(metadata,pretty:true).write(to:directory.appendingPathComponent("run.json"),options:.atomic) }
            catch { fail(error) }
        }
    }

    /// Called off the main thread. The queue barrier includes all preceding append calls.
    func snapshotLog(_ name:String) throws -> Data {
        try queue.sync {
            guard handles[name] != nil,errorMessage == nil else { throw ProbeArchiveError.unreadable }
            if !closed { try handles[name]?.synchronize() }
            return try Data(contentsOf:directory.appendingPathComponent(name))
        }
    }

    /// Result publication shares the logging queue so finish/manifest includes it.
    func writeResult(_ data: Data, filename: String) {
        queue.async { [self] in
            guard !closed, errorMessage == nil else { return }
            do {
                guard filename.range(of:"^localization-[A-Za-z0-9-]{1,80}\\.json$",options:.regularExpression) != nil else {
                    throw ProbeArchiveError.invalidPath
                }
                _ = try JSONSerialization.jsonObject(with:data)
                try data.write(to:directory.appendingPathComponent(filename),options:.atomic)
            } catch { fail(error) }
        }
    }

    /// Evidence publication is serialized with finish, so the exported checksum
    /// manifest includes the photographs and report from a manual plate query.
    func writeLandmarkFiles(_ files:[String:Data],completion:@escaping @MainActor (Result<Void,Error>) -> Void) {
        queue.async { [self] in
            let result = Result { () -> Void in
                guard !closed,errorMessage == nil,!files.isEmpty,files.count <= 20,
                      files.values.reduce(0,{ $0+$1.count }) <= 25_000_000 else { throw ProbeArchiveError.unreadable }
                for path in files.keys {
                    let parts = path.split(separator:"/",omittingEmptySubsequences:false)
                    guard parts.count == 3,parts[0] == "landmarks",UUID(uuidString:String(parts[1])) != nil,
                          String(parts[2]).range(of:"^(?:[0-9]{1,2}\\.(?:jpg|f32|u8)|crop\\.jpg|observation\\.json)$",options:.regularExpression) != nil else { throw ProbeArchiveError.invalidPath }
                }
                let identifiers = Set(files.keys.map { $0.split(separator:"/")[1] })
                guard identifiers.count == 1,let identifier = identifiers.first else { throw ProbeArchiveError.invalidPath }
                let parent = directory.appendingPathComponent("landmarks",isDirectory:true)
                try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
                let staging = parent.appendingPathComponent(".pending-"+UUID().uuidString,isDirectory:true)
                try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false)
                defer { try? FileManager.default.removeItem(at:staging) }
                for (path,bytes) in files {
                    try bytes.write(to:staging.appendingPathComponent(String(path.split(separator:"/").last!)),options:.atomic)
                }
                // Publish a whole observation together; a failed write leaves no partial report.
                try FileManager.default.moveItem(at:staging,to:parent.appendingPathComponent(String(identifier),isDirectory:true))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func append(_ file: String, _ object: [String: Any]) {
        guard gate.acquire() else {
            // The gate counts rejected tasks; avoid enqueuing more work on overload.
            return
        }
        queue.async { [self] in
            defer { gate.release() }
            guard !closed, errorMessage == nil else { return }
            do {
                var record = object; record["run_id"] = runID; record["session_id"] = sessionID
                var bytes = try ProbeIO.json(record); bytes.append(0x0a)
                guard let handle = handles[file] else { throw ProbeArchiveError.unreadable }
                try handle.write(contentsOf: bytes)
            } catch { fail(error) }
        }
    }

    func commit(image: Data, frame: [String: Any], frameID: String, completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard !closed, errorMessage == nil else { throw ProbeArchiveError.unreadable }
                guard frame["run_id"] as? String == runID, frame["session_id"] as? String == sessionID,
                      frame["frame_id"] as? String == frameID,
                      frameID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                      (frame["image"] as? [String: Any])?["path"] as? String == "frames/\(frameID).jpg" else {
                    throw ProbeFrameError.mismatchedIdentity
                }
                let frameMode = frame["data_kind"] as? String ?? ProbeDataMode.real.rawValue
                guard frameMode == dataMode.rawValue else { throw ProbeFrameError.mismatchedDataMode }
                if dataMode == .simulation {
                    let validity = frame["validity"] as? [String: Any] ?? [:]
                    guard frame["is_real_ar_capture"] as? Bool == false,
                          validity["image_geometry_verified"] as? Bool != true,
                          validity["ready_for_visual_localization_query"] as? Bool != true,
                          validity["ready_for_ar_alignment"] as? Bool != true else {
                        throw ProbeFrameError.mismatchedDataMode
                    }
                }
                let frames = directory.appendingPathComponent("frames")
                let jpg = frames.appendingPathComponent(frameID + ".jpg")
                let json = frames.appendingPathComponent(frameID + ".json")
                // Metadata is committed last. Only complete pairs count as valid captures.
                try image.write(to: jpg, options: .atomic)
                do { try ProbeIO.json(frame, pretty: true).write(to: json, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: jpg); throw error }
                captured += 1
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                fail(error)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func finish(statistics: [String: Any], completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard !closed else { throw ProbeArchiveError.unreadable }
                closed = true
                for handle in handles.values { try handle.synchronize(); try handle.close() }
                handles.removeAll()
                metadata["state"] = errorMessage == nil ? "finished" : "interrupted"
                metadata["finished_utc"] = ISO8601DateFormatter().string(from: Date())
                if let message = errorMessage { metadata["error"] = message }
                try ProbeIO.json(metadata, pretty: true).write(to: directory.appendingPathComponent("run.json"), options: .atomic)
                var summary = statistics
                summary["captured_frames"] = captured
                summary["log_tasks_dropped"] = gate.rejectedCount
                summary["data_kind"] = dataMode.rawValue
                summary["field_validation"] = dataMode == .simulation ? "not_applicable_simulation" : "unverified_requires_physical_measurement"
                summary["ar_alignment_validation"] = dataMode == .simulation ? "not_applicable_simulation" : "unverified_requires_projection_tests"
                try ProbeIO.json(summary, pretty: true).write(to: directory.appendingPathComponent("summary.json"), options: .atomic)
                try ProbeIO.makeManifest(at: directory)
                DispatchQueue.main.async { completion(.success(self.directory)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }

    private func fail(_ error: Error) {
        guard errorMessage == nil else { return }
        errorMessage = error.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onFailure?(error.localizedDescription) }
    }
}

enum ProbeFrameError: Error, LocalizedError {
    case mismatchedIdentity
    case mismatchedDataMode
    var errorDescription: String? {
        switch self {
        case .mismatchedIdentity: return "帧标识、会话或图片路径不匹配，已拒绝保存该样本。"
        case .mismatchedDataMode: return "模拟数据与真实采集标记不匹配，已拒绝保存该样本。"
        }
    }
}


/// Thermal pause is latched independently from manual pause and AR validity.
/// Cooling permits an explicit user resume; it never restarts capture itself.
public struct LiDARThermalCaptureGate: Equatable {
    public private(set) var paused = false
    public private(set) var rawState = 0
    public private(set) var coolSince: Double?
    public let cooldownSeconds: Double
    /// ProcessInfo.ThermalState raw value that stops capture. Serious (2) is reached routinely by
    /// AR plus LiDAR, so it only slows capture (`throttled`); critical (3) pauses it.
    public let pauseAtState: Int
    public var throttled: Bool { rawState >= 2 }
    public init(cooldownSeconds: Double = 15, pauseAtState: Int = 3) {
        self.cooldownSeconds = max(0,cooldownSeconds);self.pauseAtState = pauseAtState
    }
    public mutating func update(rawState: Int, now: Double) {
        guard now.isFinite else { return }
        self.rawState = rawState
        if rawState >= pauseAtState { paused = true;coolSince = nil }
        else if paused && coolSince == nil { coolSince = now }
    }
    public func mayResume(now: Double, trackingValid: Bool) -> Bool {
        guard paused,rawState < pauseAtState,trackingValid,let coolSince,now.isFinite else { return false }
        return now-coolSince >= cooldownSeconds
    }
    @discardableResult public mutating func resume(now: Double, trackingValid: Bool) -> Bool {
        guard mayResume(now:now,trackingValid:trackingValid) else { return false }
        paused = false;coolSince = nil;return true
    }
}

/// Removes only generated, unreferenced plate directories from a capture being saved.
/// The caller validates its final landmark set first and confines this operation to its IO queue.
/// Referenced evidence and non-UUID folders are never removed; symbolic links abort the preflight.
public enum LiDARLandmarkFileCleanup {
    public struct Summary {
        public let removedIDs:[String]
        public let removedBytes:Int
    }
    public static func prune(in directory:URL,keepingIDs:[String]) throws -> Summary {
        let fm = FileManager.default
        let root = directory.appendingPathComponent("landmarks",isDirectory:true)
        guard fm.fileExists(atPath:root.path) else { return Summary(removedIDs:[],removedBytes:0) }
        let properties = try root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard properties.isDirectory == true,properties.isSymbolicLink != true else {
            throw LiDARScanError.invalid("门牌证据目录无效，未清理")
        }
        let kept = Set(keepingIDs.map { UUID(uuidString:$0)?.uuidString ?? $0 })
        var plan = [(url:URL,id:String,bytes:Int)]()
        for child in try fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey]) {
            guard let uuid = UUID(uuidString:child.lastPathComponent),!kept.contains(uuid.uuidString) else { continue }
            let values = try child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LiDARScanError.invalid("门牌证据含符号链接，未清理") }
            guard values.isDirectory == true else { continue }
            var failure:Error?
            guard let files = fm.enumerator(at:child,includingPropertiesForKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey],errorHandler:{ _,error in failure = error;return false }) else {
                throw LiDARScanError.invalid("无法核对门牌证据目录，未清理")
            }
            var bytes = 0
            for case let file as URL in files {
                let attributes = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.isRegularFileKey,.fileSizeKey])
                guard attributes.isSymbolicLink != true else { throw LiDARScanError.invalid("门牌证据含符号链接，未清理") }
                if attributes.isRegularFile == true { bytes += attributes.fileSize ?? 0 }
            }
            if let failure { throw failure }
            plan.append((child,child.lastPathComponent,bytes))
        }
        // All candidates are checked before removing any one, so an unsafe path cannot
        // cause a partial cleanup during preflight. A filesystem deletion error still propagates.
        for item in plan { try fm.removeItem(at:item.url) }
        return Summary(removedIDs:plan.map(\.id).sorted(),removedBytes:plan.reduce(0) { $0+$1.bytes })
    }
}


/// A request waits for a new tracked depth frame; old cached frames cannot satisfy it.
/// This gate never changes the AR session, its coordinates, or a confirmed alignment.
public struct LiDARDepthRequestGate {
    public enum Update:Equatable { case idle,waiting,ready,timedOut }
    public private(set) var requestedAt:Double?
    public private(set) var deadline:Double?
    public var waiting:Bool { requestedAt != nil }
    public init() {}
    public mutating func begin(now:Double,timeout:Double = 6) {
        guard now.isFinite,timeout.isFinite,timeout > 0 else { cancel();return }
        requestedAt = now;deadline = now+timeout
    }
    public mutating func cancel() { requestedAt = nil;deadline = nil }
    public mutating func update(frameTimestamp:Double?,now:Double,hasDepth:Bool,trackingNormal:Bool) -> Update {
        guard let requestedAt,let deadline else { return .idle }
        guard now.isFinite else { return .waiting }
        if now >= deadline { cancel();return .timedOut }
        guard trackingNormal,hasDepth,let timestamp = frameTimestamp,timestamp.isFinite,
              timestamp > requestedAt,now-timestamp >= -0.05,now-timestamp <= 0.25 else { return .waiting }
        cancel();return .ready
    }
}
