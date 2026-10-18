import Foundation

public enum ProbeArchiveError: Error, LocalizedError {
    case invalidPath, tooLarge, unreadable
    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "导出路径无效。"
        case .tooLarge: return "数据包超过首版 ZIP 大小限制，请分成更短的测试。"
        case .unreadable: return "无法读取待导出的文件。"
        }
    }
}

private extension Data {
    mutating func le16(_ n: UInt16) {
        append(UInt8(truncatingIfNeeded: n)); append(UInt8(truncatingIfNeeded: n >> 8))
    }
    mutating func le32(_ n: UInt32) {
        le16(UInt16(truncatingIfNeeded: n)); le16(UInt16(truncatingIfNeeded: n >> 16))
    }
}

public enum ProbeZip {
    private static let table: [UInt32] = (0..<256).map { i in
        var n = UInt32(i)
        for _ in 0..<8 { n = (n & 1) == 1 ? 0xedb88320 ^ (n >> 1) : n >> 1 }
        return n
    }
    public static func crc32(_ bytes: Data) -> UInt32 {
        updateCRC(0xffffffff, bytes) ^ 0xffffffff
    }
    private static func updateCRC(_ current: UInt32, _ data: Data) -> UInt32 {
        data.reduce(current) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) }
    }
    // Stored ZIP, no dependency or network. Stream file data; don't buffer a whole run.
    public static func create(directory: URL, destination: URL) throws {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let output = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !output.path.hasPrefix(root.path + "/") else { throw ProbeArchiveError.invalidPath }
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw ProbeArchiveError.unreadable
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let attrs = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attrs.isSymbolicLink != true else { throw ProbeArchiveError.invalidPath }
            if attrs.isRegularFile == true { files.append(file) }
        }
        guard files.count <= Int(UInt16.max) else { throw ProbeArchiveError.tooLarge }
        files.sort { $0.path < $1.path }
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.appendingPathExtension("partial")
        if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw ProbeArchiveError.unreadable }
        let writer = try FileHandle(forWritingTo: temporary)
        var central = Data()
        var offset: UInt64 = 0
        do {
            for file in files {
                let normalized = file.standardizedFileURL
                guard normalized.pathComponents.starts(with: root.pathComponents) else { throw ProbeArchiveError.invalidPath }
                let relative = normalized.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { throw ProbeArchiveError.invalidPath }
                let name = Data((root.lastPathComponent + "/" + relative).utf8)
                let reader = try FileHandle(forReadingFrom: file)
                var size: UInt64 = 0
                var crc: UInt32 = 0xffffffff
                while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
                    size += UInt64(chunk.count); crc = updateCRC(crc, chunk)
                }
                crc ^= 0xffffffff
                guard size <= UInt64(UInt32.max), offset <= UInt64(UInt32.max), name.count <= Int(UInt16.max) else {
                    try reader.close(); throw ProbeArchiveError.tooLarge
                }
                var header = Data()
                header.le32(0x04034b50); header.le16(20); header.le16(0x0800)
                header.le16(0); header.le16(0); header.le16(0x0021)
                header.le32(crc); header.le32(UInt32(size)); header.le32(UInt32(size))
                header.le16(UInt16(name.count)); header.le16(0); header.append(name)
                try writer.write(contentsOf: header)
                try reader.seek(toOffset: 0)
                while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty { try writer.write(contentsOf: chunk) }
                try reader.close()
                central.le32(0x02014b50); central.le16(20); central.le16(20)
                central.le16(0x0800); central.le16(0); central.le16(0); central.le16(0x0021)
                central.le32(crc); central.le32(UInt32(size)); central.le32(UInt32(size))
                central.le16(UInt16(name.count)); central.le16(0); central.le16(0)
                central.le16(0); central.le16(0); central.le32(0); central.le32(UInt32(offset)); central.append(name)
                offset += UInt64(header.count) + size
            }
            guard offset + UInt64(central.count) <= UInt64(UInt32.max) else { throw ProbeArchiveError.tooLarge }
            try writer.write(contentsOf: central)
            var end = Data()
            end.le32(0x06054b50); end.le16(0); end.le16(0)
            end.le16(UInt16(files.count)); end.le16(UInt16(files.count))
            end.le32(UInt32(central.count)); end.le32(UInt32(offset)); end.le16(0)
            try writer.write(contentsOf: end)
            try writer.close()
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.moveItem(at: temporary, to: output)
        } catch {
            try? writer.close()
            try? fm.removeItem(at: temporary)
            throw error
        }
    }
}
