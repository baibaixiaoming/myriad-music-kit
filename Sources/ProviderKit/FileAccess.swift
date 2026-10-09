import AVFoundation
import Foundation

/// 程序内的“虚拟文件系统”：不经过系统挂载就能读网络盘（家庭服务器直连 NAS 用）。
/// 登记后，路径 `/@nas/<来源编号>/<子路径>` 的读取转给对应的实现；其他路径照常读本机文件。
/// 各种格式读取器（DSD、APE、SACD、CD 镜像、CUE、数据光盘）都经这里读文件，因此本机与网络盘的处理完全相同。
public protocol VirtualFileSystem: AnyObject, Sendable {
    /// 打开文件准备随机读取。
    func open(_ path: String) throws -> any RandomAccessReading
    /// 文件或文件夹信息；不存在时为 nil。
    func info(_ path: String) -> VirtualFileInfo?
    /// 递归列出文件夹下的所有文件（不含文件夹本身），路径相对于 `path`。读不到时抛错。
    func listFiles(_ path: String) throws -> [VirtualFileInfo]
}

public struct VirtualFileInfo: Sendable, Equatable {
    public let path: String
    public let size: Int64
    public let modified: Date
    public let isDirectory: Bool
    public init(path: String, size: Int64, modified: Date, isDirectory: Bool) {
        self.path = path; self.size = size; self.modified = modified; self.isDirectory = isDirectory
    }
}

public protocol RandomAccessReading: AnyObject, Sendable {
    var size: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
    func close()
}

public enum FileAccess {
    public static let root = "/@nas/"
    nonisolated(unsafe) private static var mounts: [String: any VirtualFileSystem] = [:]
    private static let lock = NSLock()

    /// 登记一个网络来源。之后 `/@nas/<id>/…` 由它提供。
    public static func mount(_ id: String, _ fs: any VirtualFileSystem) { lock.withLock { mounts[id] = fs } }
    public static func unmount(_ id: String) { lock.withLock { _ = mounts.removeValue(forKey: id) } }
    public static func path(source id: String, _ sub: String = "") -> String {
        root + id + (sub.isEmpty ? "" : "/" + sub.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    /// 虚拟路径对应的实现与其内部路径；本机路径返回 nil。
    static func resolve(_ path: String) -> (any VirtualFileSystem, String)? {
        guard path.hasPrefix(root) else { return nil }
        let rest = path.dropFirst(root.count)
        let id = rest.prefix { $0 != "/" }
        let sub = rest.dropFirst(id.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let fs = lock.withLock({ mounts[String(id)] }) else { return nil }
        return (fs, sub)
    }

    public static func isVirtual(_ url: URL) -> Bool { url.path(percentEncoded: false).hasPrefix(root) }

    static func p(_ url: URL) -> String { url.path(percentEncoded: false) }

    public static func exists(_ url: URL) -> Bool { info(url) != nil }

    public static func isDirectory(_ url: URL) -> Bool { info(url)?.isDirectory == true }

    public static func size(_ url: URL) -> UInt64? {
        guard let i = info(url), !i.isDirectory else { return nil }
        return UInt64(i.size)
    }

    public static func info(_ url: URL) -> VirtualFileInfo? {
        let path = p(url)
        if path.hasPrefix(root) {
            guard let (fs, sub) = resolve(path) else { return nil }
            return fs.info(sub)
        }
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return VirtualFileInfo(path: path, size: (a[.size] as? NSNumber)?.int64Value ?? 0,
                               modified: a[.modificationDate] as? Date ?? .distantPast,
                               isDirectory: a[.type] as? FileAttributeType == .typeDirectory)
    }

    /// 读整个小文件（CUE、歌词、镜像目录等）；超过上限或读不到时为 nil。
    public static func data(_ url: URL, limit: Int = 16 << 20) -> Data? {
        guard isVirtual(url) else {
            guard let s = size(url), s <= UInt64(limit) else { return nil }
            return try? Data(contentsOf: url)
        }
        guard let r = try? FileReader(forReadingFrom: url), r.size <= Int64(limit) else { return nil }
        defer { try? r.close() }
        return try? r.read(upToCount: Int(r.size))
    }

    /// 递归列出文件夹下的文件：完整路径 → (大小, 修改时间)。读不到文件夹时为 nil。
    public static func listFiles(_ folder: URL, extensions: Set<String>) -> [String: (size: Int64, modified: Date)]? {
        let path = p(folder)
        if path.hasPrefix(root) {
            guard let (fs, sub) = resolve(path), let list = try? fs.listFiles(sub) else { return nil }
            var result: [String: (Int64, Date)] = [:]
            let base = path.hasSuffix("/") ? String(path.dropLast()) : path
            for f in list where extensions.contains((f.path as NSString).pathExtension.lowercased()) {
                result[base + "/" + f.path] = (f.size, f.modified)
            }
            return result
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        var result: [String: (Int64, Date)] = [:]
        for case let url as URL in e where extensions.contains(url.pathExtension.lowercased()) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            result[url.standardizedFileURL.path(percentEncoded: false)] = (Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        return result
    }

    /// 让系统播放框架读取文件（读标签、时长或播放）。网络来源经“虚拟文件”加载器提供数据；
    /// 返回的 owner 须在使用期间保持存活。
    public static func asset(for url: URL) -> (asset: AVURLAsset, owner: AnyObject?) {
        guard isVirtual(url), let size = size(url),
              let made = SliceAssetLoader.asset(for: SliceAssetLoader.url(path: p(url), offset: 0, length: size, wav: false,
                                                                         ext: url.pathExtension.lowercased())) else {
            return (AVURLAsset(url: url), nil)
        }
        return (made.0, made.1)
    }
}

/// 与 FileHandle 用法相同的只读文件：本机文件直接读；网络来源带预读缓冲（小块读取不必每次走网络）。
public final class FileReader: @unchecked Sendable {
    private let local: FileHandle?
    private let remote: (any RandomAccessReading)?
    public let size: Int64
    private var position: Int64 = 0
    private var buffer = Data()
    private var bufferStart: Int64 = 0
    /// 网络读取的最小块。
    static let readAhead = 256 * 1024

    public init(forReadingFrom url: URL) throws {
        let path = url.path(percentEncoded: false)
        if path.hasPrefix(FileAccess.root) {
            guard let (fs, sub) = FileAccess.resolve(path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
            let r = try fs.open(sub)
            remote = r
            local = nil
            size = r.size
        } else {
            let h = try FileHandle(forReadingFrom: url)
            local = h
            remote = nil
            size = Int64(try h.seekToEnd())
            try h.seek(toOffset: 0)
        }
    }

    deinit { try? close() }

    public func seek(toOffset offset: UInt64) throws {
        if let local { try local.seek(toOffset: offset) }
        position = Int64(offset)
    }

    public func offset() throws -> UInt64 {
        if let local { return try local.offset() }
        return UInt64(position)
    }

    @discardableResult
    public func seekToEnd() throws -> UInt64 {
        if let local { return try local.seekToEnd() }
        position = size
        return UInt64(size)
    }

    public func read(upToCount count: Int) throws -> Data? {
        if let local { return try local.read(upToCount: count) }
        guard let remote, count > 0, position < size else { return Data() }
        let want = Int(min(Int64(count), size - position))
        let end = position + Int64(want)
        // 缓冲里有就直接给
        if position >= bufferStart, end <= bufferStart + Int64(buffer.count) {
            let from = Int(position - bufferStart)
            let out = buffer.subdata(in: buffer.startIndex + from ..< buffer.startIndex + from + want)
            position = end
            return out
        }
        // 大块读取直接取；小块读取按预读大小取并缓存
        if want >= Self.readAhead {
            let d = try remote.read(at: position, count: want)
            position += Int64(d.count)
            return d
        }
        let fetched = try remote.read(at: position, count: Int(min(Int64(Self.readAhead), size - position)))
        buffer = fetched
        bufferStart = position
        let take = min(want, fetched.count)
        position += Int64(take)
        return fetched.prefix(take)
    }

    public func close() throws {
        try local?.close()
        remote?.close()
    }
}
