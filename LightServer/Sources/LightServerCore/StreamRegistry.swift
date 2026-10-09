import Foundation
import SecureTransport

/// 已打开的音频流：`/v1/stream/open` 登记一个文件、发一个编号，之后 `/v1/stream/{编号}` 按 Range 读取。
/// 只能读自己（同一用户）打开的流；6 小时没人读的自动作废，最多同时记 256 个（超出去掉最久没用的）。
actor StreamRegistry {
    struct Entry {
        let owner: String
        let file: URL
        let contentType: String
        var lastUsed: Date
    }

    static let idleLimit: TimeInterval = 6 * 3600
    static let maxEntries = 256
    /// 每次从磁盘读、发给连接的块大小。
    static let chunkSize = 256 * 1024

    private var entries: [String: Entry] = [:]

    func open(owner: String, file: URL) -> String {
        purge()
        let id = UUID().uuidString.lowercased()
        entries[id] = Entry(owner: owner, file: file, contentType: Self.mime(file.pathExtension), lastUsed: Date())
        if entries.count > Self.maxEntries,
           let oldest = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            entries[oldest] = nil
        }
        return id
    }

    var count: Int { entries.count }

    /// 读取：每次都重新打开文件、按当时的大小回应（文件在播放期间被替换也不会读到别的位置之外）。
    func read(id: String, owner: String, range: String?) -> SecureServer.Response {
        guard var entry = entries[id], entry.owner == owner else {
            return Responses.error(404, .resourceRemoved, "播放编号已失效，请重新播放")
        }
        entry.lastUsed = Date()
        entries[id] = entry
        return Self.respond(file: entry.file, contentType: entry.contentType, range: range)
    }

    static func respond(file: URL, contentType: String, range: String?) -> SecureServer.Response {
        let reader: ChunkReader
        do { reader = try ChunkReader(file) }
        catch {
            serverLog("音频", "打不开文件 \(file.lastPathComponent)：\(error)")
            return Responses.error(404, .resourceRemoved, "音乐文件已不存在或无法读取，请刷新后重试")
        }
        let length = reader.length
        let start: Int64, end: Int64, partial: Bool
        switch ByteRange.parse(range, length: length) {
        case .whole:
            start = 0; end = length - 1; partial = false
        case .partial(let s, let e):
            start = s; end = e; partial = true
        case .unsatisfiable:
            return .full(HTTPResponseHead(status: 416, headers: ["content-range": "bytes */\(length)"]), Data())
        }
        var headers = ["accept-ranges": "bytes", "content-type": contentType]
        if partial { headers["content-range"] = "bytes \(start)-\(end)/\(length)" }
        reader.limit(from: start, through: end)
        // 按需读取：连接要下一块时才从磁盘读，慢的客户端不会让整首歌堆在内存里
        let body = AsyncThrowingStream<Data, Error>(unfolding: { try reader.next() })
        return .stream(HTTPResponseHead(status: partial ? 206 : 200, headers: headers), body)
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "flac": "audio/flac"
        case "mp3": "audio/mpeg"
        case "m4a", "mp4", "aac", "alac": "audio/mp4"
        case "wav": "audio/wav"
        case "aif", "aiff", "aifc": "audio/aiff"
        case "caf": "audio/x-caf"
        default: "application/octet-stream"
        }
    }

    private func purge() {
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.lastUsed) < Self.idleLimit }
    }
}

/// 一次读取用的文件句柄：读完或连接关闭（流被丢弃）时关闭。
final class ChunkReader: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    let length: Int64
    private var position: Int64 = 0
    private var end: Int64 = -1

    init(_ url: URL) throws {
        let h = try FileHandle(forReadingFrom: url)
        do { length = Int64(try h.seekToEnd()) }
        catch { try? h.close(); throw error }
        handle = h
    }

    deinit { try? handle?.close() }

    func limit(from start: Int64, through end: Int64) {
        lock.withLock { position = start; self.end = end }
    }

    /// 下一块；读完返回 nil 并关闭文件。
    func next() throws -> Data? {
        try lock.withLock {
            guard let h = handle else { return nil }
            guard position <= end else { close(); return nil }
            let count = Int(min(Int64(StreamRegistry.chunkSize), end - position + 1))
            try h.seek(toOffset: UInt64(position))
            guard let data = try h.read(upToCount: count), !data.isEmpty else { close(); return nil }
            position += Int64(data.count)
            return data
        }
    }

    private func close() {
        try? handle?.close()
        handle = nil
    }
}
