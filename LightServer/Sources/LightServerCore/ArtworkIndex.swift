import CryptoKit
import Foundation

/// 封面索引：每首歌、每张专辑对应哪张图。本地音乐模块不读封面，由这里负责。
/// 找法：先找歌曲所在文件夹里的图片（cover、folder、front、album 优先，其次任意 jpg/png），再找文件内嵌的封面。
/// 对外只给令牌（`lightmusic://artwork/<令牌>`），令牌只对应索引里的条目，不能借它读任意文件。
actor ArtworkIndex {
    enum Source: Hashable, Sendable {
        /// 文件夹里的图片文件。
        case image(String)
        /// 音乐文件内嵌的封面。
        case embedded(String)
    }

    struct Fingerprint: Hashable, Sendable {
        let size: Int64
        let modified: Date
    }

    static let scheme = "lightmusic"
    static let preferredNames = ["cover", "folder", "front", "album", "albumart"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    /// 内存里缓存的图片数量。
    static let cacheLimit = 32

    /// 曲目文件路径 → 令牌。
    private var byTrack: [String: String] = [:]
    /// 专辑编号 → 令牌。
    private var byAlbum: [String: String] = [:]
    private var byToken: [String: Source] = [:]
    /// 上次检查内嵌封面的结果（文件没变就不再读）。
    private var embeddedChecked: [String: (Fingerprint, Bool)] = [:]
    private var cache: [String: (data: Data, type: String)] = [:]
    private var cacheOrder: [String] = []

    /// 按音乐库现有的曲目重建索引。`albums`：专辑编号 → 这张专辑各首歌的文件路径（用第一首有封面的）。
    func rebuild(tracks: [(path: String, fingerprint: Fingerprint?)], albums: [String: [String]]) async {
        var folderImage: [String: String?] = [:]
        var nextTrack: [String: String] = [:]
        var nextToken: [String: Source] = [:]
        var nextChecked: [String: (Fingerprint, Bool)] = [:]
        for (path, fingerprint) in tracks where nextTrack[path] == nil {
            let folder = (path as NSString).deletingLastPathComponent
            if folderImage[folder] == nil { folderImage[folder] = .some(Self.findImage(in: folder)) }
            var source: Source?
            if let image = folderImage[folder] ?? nil {
                source = .image(image)
            } else {
                var has: Bool
                if let fingerprint, let old = embeddedChecked[path], old.0 == fingerprint { has = old.1 }
                else { has = await EmbeddedArtwork.exists(in: URL(fileURLWithPath: path)) }
                if let fingerprint { nextChecked[path] = (fingerprint, has) }
                if has { source = .embedded(path) }
            }
            guard let source else { continue }
            let token = Self.token(for: source)
            nextTrack[path] = token
            nextToken[token] = source
        }
        byTrack = nextTrack
        byToken = nextToken
        embeddedChecked = nextChecked
        byAlbum = albums.compactMapValues { paths in paths.lazy.compactMap { nextTrack[$0] }.first }
        // 已不在索引里的图片从缓存里去掉
        cache = cache.filter { nextToken[$0.key] != nil }
        cacheOrder.removeAll { cache[$0] == nil }
    }

    func url(forTrackPath path: String) -> URL? { byTrack[path].map(Self.url(token:)) }
    func url(forAlbum id: String) -> URL? { byAlbum[id].map(Self.url(token:)) }
    var trackCount: Int { byTrack.count }

    /// 按客户端发来的地址取图。不认识的地址返回 nil。
    func image(for raw: String) async -> (data: Data, type: String)? {
        guard let token = Self.token(fromURL: raw), let source = byToken[token] else { return nil }
        if let hit = cache[token] { return hit }
        let data: Data?
        switch source {
        case .image(let path):
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            data = size <= EmbeddedArtwork.maxBytes ? try? Data(contentsOf: url) : nil
        case .embedded(let path):
            data = await EmbeddedArtwork.read(from: URL(fileURLWithPath: path))
        }
        guard let data, !data.isEmpty else { return nil }
        let result = (data, Self.mime(data))
        cache[token] = result
        cacheOrder.append(token)
        if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        return result
    }

    // MARK: 工具

    static func findImage(in folder: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        let images = names.filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
        for preferred in preferredNames {
            if let hit = images.first(where: { ($0 as NSString).deletingPathExtension.lowercased() == preferred }) {
                return (folder as NSString).appendingPathComponent(hit)
            }
        }
        return images.first.map { (folder as NSString).appendingPathComponent($0) }
    }

    /// 令牌由来源与文件的大小、修改时间算出：图片换了，地址也跟着变，客户端不会一直用旧图。
    static func token(for source: Source) -> String {
        let (kind, path) = switch source {
        case .image(let p): ("image", p)
        case .embedded(let p): ("embedded", p)
        }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = "\(values?.fileSize ?? 0)-\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        let digest = SHA256.hash(data: Data("\(kind)\n\(path)\n\(stamp)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func url(token: String) -> URL { URL(string: "\(scheme)://artwork/\(token)")! }

    static func token(fromURL raw: String) -> String? {
        guard let url = URL(string: raw), url.scheme == scheme, url.host == "artwork" else { return nil }
        let token = url.lastPathComponent
        guard token.count == 24, token.allSatisfy(\.isHexDigit) else { return nil }
        return token
    }

    static func mime(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "application/octet-stream"
    }
}
