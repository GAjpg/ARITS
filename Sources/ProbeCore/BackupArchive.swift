import Foundation
import CryptoKit

public enum CampusBackupZIP {
    // The app exports uncompressed ZIPs. Reject other formats rather than guessing
    // at compressed sizes, encrypted streams, or unsafe external paths.
    public static func extract(_ source: URL, to destination: URL) throws -> URL {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw CampusError.corrupt }
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        func u16(_ p: Int) throws -> Int {
            guard p >= 0, p + 2 <= data.count else { throw CampusError.corrupt }
            return Int(data[p]) | Int(data[p+1]) << 8
        }
        func u32(_ p: Int) throws -> Int { try u16(p) | u16(p+2) << 16 }
        guard data.count >= 22 else { throw CampusError.corrupt }
        var end: Int?
        for p in stride(from: data.count-22, through: max(0,data.count-65557), by: -1) {
            if try u32(p) == 0x06054b50, p + 22 + (try u16(p+20)) == data.count { end = p; break }
        }
        guard let end, try u16(end+4) == 0, try u16(end+6) == 0,
              try u16(end+8) == u16(end+10) else { throw CampusError.corrupt }
        let count = try u16(end+10), centralSize = try u32(end+12), start = try u32(end+16)
        guard count > 0, count <= 10000, start >= 0, start + centralSize == end else { throw CampusError.corrupt }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw CampusError.corrupt }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var p = start, names = Set<String>(), roots = Set<String>(), total = 0
        var intervals: [(Int,Int)] = []
        do {
            for _ in 0..<count {
                guard p + 46 <= end, try u32(p) == 0x02014b50 else { throw CampusError.corrupt }
                let flags = try u16(p+8), method = try u16(p+10), crc = try u32(p+16)
                let compressed = try u32(p+20), expanded = try u32(p+24), nameLength = try u16(p+28)
                let extra = try u16(p+30), comment = try u16(p+32), local = try u32(p+42)
                let external = try u32(p+38), mode = (external >> 16) & 0xf000
                guard flags & ~0x0800 == 0, method == 0 else { throw CampusError.unsupportedZIP }
                guard compressed == expanded, expanded <= 100 * 1024 * 1024,
                      try u16(p+34) == 0, mode != 0xa000,
                      p + 46 + nameLength + extra + comment <= end,
                      let name = String(data: data.subdata(in: p+46..<p+46+nameLength), encoding: .utf8) else { throw CampusError.corrupt }
                let parts = name.split(separator: "/", omittingEmptySubsequences: false)
                let directory = name.hasSuffix("/")
                let components = directory ? Array(parts.dropLast()) : Array(parts)
                guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                      components.count >= 2, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }),
                      names.insert(name).inserted else { throw CampusError.corrupt }
                roots.insert(String(components[0]))
                guard local >= 0, local + 30 <= start, try u32(local) == 0x04034b50,
                      try u16(local+6) == flags, try u16(local+8) == method,
                      try u32(local+14) == crc, try u32(local+18) == compressed,
                      try u32(local+22) == expanded else { throw CampusError.corrupt }
                let localName = try u16(local+26), localExtra = try u16(local+28)
                let payload = local + 30 + localName + localExtra
                guard localName == nameLength, payload <= start, payload + expanded <= start,
                      data.subdata(in: local+30..<local+30+localName) == Data(name.utf8),
                      !intervals.contains(where: { local < $0.1 && payload+expanded > $0.0 }) else { throw CampusError.corrupt }
                intervals.append((local,payload+expanded)); total += expanded
                guard total <= 512 * 1024 * 1024 else { throw CampusError.corrupt }
                let bytes = data.subdata(in: payload..<payload+expanded)
                guard ProbeZip.crc32(bytes) == UInt32(crc) else { throw CampusError.corrupt }
                let target = destination.appendingPathComponent(name)
                if directory {
                    guard expanded == 0 else { throw CampusError.corrupt }
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: target, options: .atomic)
                }
                p += 46 + nameLength + extra + comment
            }
            guard p == end, roots.count == 1, let root = roots.first else { throw CampusError.corrupt }
            return destination.appendingPathComponent(root, isDirectory: true)
        } catch { try? fm.removeItem(at: destination); throw error }
    }
}

public enum CampusFiles {
    public static func hash(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var hash = SHA256()
        while let bytes = try reader.read(upToCount: 65536), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func verify(_ directory: URL) throws {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("files.json")))
        guard !manifest.files.isEmpty, manifest.files.count <= 10000,
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw CampusError.corrupt }
        let fm = FileManager.default
        guard let enumeration = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey]) else { throw CampusError.corrupt }
        var actual = Set<String>()
        for case let file as URL in enumeration {
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey])
            guard attrs.isSymbolicLink != true else { throw CampusError.corrupt }
            if attrs.isRegularFile == true {
                let path = file.standardizedFileURL.pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")
                if path != "files.json" { actual.insert(path) }
            }
        }
        guard actual == Set(manifest.files.map(\.path)) else { throw CampusError.corrupt }
        for e in manifest.files {
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !e.path.hasPrefix("/"), !e.path.contains("\\"), !e.path.contains("\0"),
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), e.bytes > 0, e.bytes <= 100 * 1024 * 1024 else { throw CampusError.corrupt }
            let file = directory.appendingPathComponent(e.path)
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == e.bytes,
                  try hash(file) == e.sha256 else { throw CampusError.corrupt }
        }
    }
    public struct Manifest: Codable { public var files: [Entry] }
    public struct Entry: Codable { public var path: String; public var bytes: Int; public var sha256: String }
    public static func manifest(_ directory: URL) throws {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let enumeration = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey]) else { throw CampusError.corrupt }
        var entries: [Entry] = []
        for case let file as URL in enumeration {
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard attrs.isSymbolicLink != true else { throw CampusError.corrupt }
            let relative = file.standardizedFileURL.pathComponents.dropFirst(directory.pathComponents.count).joined(separator: "/")
            if attrs.isRegularFile == true, relative != "files.json" {
                entries.append(Entry(path: relative, bytes: attrs.fileSize ?? 0, sha256: try hash(file)))
            }
        }
        try encode(Manifest(files: entries.sorted { $0.path < $1.path }), to: directory.appendingPathComponent("files.json"))
    }
}
