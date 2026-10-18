import Foundation

public struct CampusStorageUsage {
    public let title:String
    public let bytes:Int64
}
public enum CampusStorage {
    /// File totals are estimates: shared filesystem blocks may differ from the system's app-size report.
    public static func bytes(at root:URL) -> Int64 {
        let keys:Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]
        guard let attrs = try? root.resourceValues(forKeys:keys),attrs.isSymbolicLink != true else { return 0 }
        if attrs.isRegularFile == true { return Int64(attrs.fileSize ?? 0) }
        guard let files = FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys)) else { return 0 }
        var size:Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys:keys) else { continue }
            if values.isSymbolicLink == true { files.skipDescendants();continue }
            if values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        return size
    }
    public static func usage(documents:URL,library:CampusLibrary,cache:URL?,temporary:URL?) -> [CampusStorageUsage] {
        let network = documents.appendingPathComponent("CampusNetworks")
        let current = library.list().reduce(Int64(0)) { sum,g in sum+( (try? library.directory(g.building_id)).map { bytes(at:$0) } ?? 0 )+( (try? library.mapsDirectory(g.building_id)).map { bytes(at:$0) } ?? 0 ) }
        let records = ["NetworkTrials","Runs","PreviewRuns"].reduce(Int64(0)) { $0+bytes(at:documents.appendingPathComponent($1)) }
        let exports = bytes(at:documents.appendingPathComponent("Exports"))+bytes(at:documents.appendingPathComponent("PreviewExports"))
        let networkTotal = bytes(at:network),docTotal = bytes(at:documents)
        return [CampusStorageUsage(title:"当前路网与环境",bytes:current),
                CampusStorageUsage(title:"历史版本与草稿",bytes:max(0,networkTotal-current)),
                CampusStorageUsage(title:"验证照片和日志",bytes:records),
                CampusStorageUsage(title:"导出的 ZIP 与文件",bytes:exports),
                CampusStorageUsage(title:"其他保存的数据",bytes:max(0,docTotal-networkTotal-records-exports)),
                CampusStorageUsage(title:"缓存与临时文件",bytes:(cache.map { bytes(at:$0) } ?? 0)+(temporary.map { bytes(at:$0) } ?? 0))]
    }
    /// Only ended trials can be cleaned. Keep the most recent three in each trial collection.
    public static func trialCleanupCandidates(documents:URL) -> [URL] {
        var all:[URL] = []
        for name in ["NetworkTrials","Runs","PreviewRuns"] {
            let root = documents.appendingPathComponent(name)
            var finished:[(URL,String)] = []
            for directory in (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey])) ?? [] {
                guard let attrs = try? directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),attrs.isDirectory == true,attrs.isSymbolicLink != true,
                      let data = try? Data(contentsOf:directory.appendingPathComponent("run.json")),
                      let run = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                      ["finished","interrupted"].contains(run["state"] as? String ?? ""),
                      let time = run["started_utc"] as? String,ISO8601DateFormatter().date(from:time) != nil else { continue }
                finished.append((directory,time))
            }
            finished.sort { $0.1 == $1.1 ? $0.0.lastPathComponent > $1.0.lastPathComponent : $0.1 > $1.1 }
            all += finished.dropFirst(3).map { $0.0 }
        };return all
    }
    @discardableResult public static func pruneTrials(documents:URL) throws -> Int {
        let candidates = trialCleanupCandidates(documents:documents)
        for directory in candidates { try FileManager.default.removeItem(at:directory) }
        return candidates.count
    }
}
