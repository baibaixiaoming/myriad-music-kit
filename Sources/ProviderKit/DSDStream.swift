import Foundation

/// 经网络传 DSD：服务器把任意 DSD 来源（DSF、DFF、DST 压缩的 DFF、SACD 镜像里的一首）
/// 现场组成一个标准 DSF 文件（不压缩，每声道 4096 字节一块），客户端按字节范围读取。
/// DSF 结构简单、可随意跳转，下载下来也是能直接用的普通文件。
public final class VirtualDSF: @unchecked Sendable {
    public static let blockSize = 4096
    public static let headerSize = 28 + 52 + 12

    public let source: any DSDSource
    /// 数据部分（每声道字节数向上补齐到整块）。
    public let blocks: Int64
    public var dataSize: Int64 { blocks * Int64(Self.blockSize * source.channels) }
    public var totalLength: Int64 { Int64(Self.headerSize) + dataSize }
    private let lock = NSLock()

    public init(source: any DSDSource) {
        self.source = source
        let bytes = (source.sampleCount + 7) / 8
        blocks = (bytes + Int64(Self.blockSize) - 1) / Int64(Self.blockSize)
    }

    /// DSF 声道类型：1 单声道、2 立体声、3 三声道、4 四声道、6 五声道、7 5.1。
    static func channelType(_ n: Int) -> UInt32 {
        switch n { case 1: 1; case 2: 2; case 3: 3; case 4: 4; case 5: 6; case 6: 7; default: 2 }
    }

    public var header: Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(UInt64(totalLength)); u64(0)
        d.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0)
        u32(Self.channelType(source.channels)); u32(UInt32(source.channels)); u32(UInt32(source.sampleRate)); u32(1)
        u64(UInt64(source.sampleCount)); u32(UInt32(Self.blockSize)); u32(0)
        d.append(contentsOf: Array("data".utf8)); u64(UInt64(12 + dataSize))
        return d
    }

    /// 读取虚拟文件中 [start, start+count) 的内容。
    public func bytes(from start: Int64, count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var out = Data()
        var pos = start
        let end = min(totalLength, start + Int64(count))
        if pos < Int64(Self.headerSize) {
            let h = header
            out.append(h[Int(pos) ..< Int(min(end, Int64(Self.headerSize)))])
            pos = Int64(Self.headerSize)
        }
        let groupSize = Int64(Self.blockSize * source.channels)
        while pos < end {
            let inner = pos - Int64(Self.headerSize)
            let group = inner / groupSize
            // 一个块组：读出各声道 4096 字节，按 DSF 规定翻转为最低位在前
            let channelData = try source.read(fromByte: group * Int64(Self.blockSize), count: Self.blockSize)
            var block = [UInt8](repeating: 0x69, count: Int(groupSize))   // 不足一块处补静音
            for c in 0..<source.channels where c < channelData.count {
                let src = channelData[c]
                for i in 0..<src.count { block[c * Self.blockSize + i] = DSDFile.reverse[Int(src[i])] }
            }
            let from = Int(inner - group * groupSize)
            let take = Int(min(end - pos, groupSize - Int64(from)))
            out.append(contentsOf: block[from ..< from + take])
            pos += Int64(take)
        }
        return out
    }
}

/// 客户端读网络上的 DSF：只需能按字节范围取数据的函数（在播放线程上同步调用）。
/// 每次多取若干块组并缓存，同时在后台预取下一段，减少等待。
public final class RemoteDSFSource: DSDSource, @unchecked Sendable {
    public typealias Fetch = @Sendable (_ offset: Int64, _ count: Int) throws -> Data

    public let sampleRate: Int
    public let channels: Int
    public let sampleCount: Int64
    private let blockSize: Int
    private let dataOffset: Int64
    private let fetch: Fetch
    /// 每次取的块组数（双声道 DSD64 约 0.75 秒）。
    private let groupsPerChunk = 64
    private let lock = NSLock()
    private var cache: [Int64: [UInt8]] = [:]
    private var pending: Set<Int64> = []

    public init(fetch: @escaping Fetch) throws {
        self.fetch = fetch
        let h = try fetch(0, VirtualDSF.headerSize)
        guard h.count >= VirtualDSF.headerSize, h.prefix(4) == Data("DSD ".utf8),
              h[h.startIndex + 28 ..< h.startIndex + 32] == Data("fmt ".utf8) else { throw DSDFile.bad }
        channels = Int(h.le32(28 + 24))
        sampleRate = Int(h.le32(28 + 28))
        sampleCount = Int64(h.le64(28 + 36))
        blockSize = Int(h.le32(28 + 44))
        dataOffset = Int64(VirtualDSF.headerSize)
        guard channels > 0, sampleRate > 0, blockSize > 0 else { throw DSDFile.bad }
    }

    private var chunkBytes: Int { blockSize * channels * groupsPerChunk }

    private func load(_ chunk: Int64) throws -> [UInt8] {
        if let c = lock.withLock({ cache[chunk] }) { return c }
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let d = try fetch(dataOffset + chunk * Int64(chunkBytes), chunkBytes)
                let bytes = [UInt8](d)
                lock.withLock {
                    cache[chunk] = bytes
                    // 只留附近几段
                    for k in cache.keys where k < chunk - 2 || k > chunk + 4 { cache[k] = nil }
                }
                return bytes
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.2 * Double(attempt + 1))
            }
        }
        throw lastError ?? DSDFile.bad
    }

    private func prefetch(_ chunk: Int64) {
        let start = lock.withLock { () -> Bool in
            guard cache[chunk] == nil, !pending.contains(chunk) else { return false }
            pending.insert(chunk)
            return true
        }
        guard start else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            _ = try? load(chunk)
            lock.withLock { _ = pending.remove(chunk) }
        }
    }

    public func read(fromByte byteIndex: Int64, count: Int) throws -> [[UInt8]] {
        let total = (sampleCount + 7) / 8
        let n = Int(max(0, min(Int64(count), total - byteIndex)))
        var out = Array(repeating: [UInt8](), count: channels)
        guard n > 0 else { return out }
        var pos = byteIndex, remaining = n
        let groupSize = Int64(blockSize * channels)
        while remaining > 0 {
            let group = pos / Int64(blockSize), inBlock = Int(pos % Int64(blockSize))
            let chunk = group / Int64(groupsPerChunk)
            let data = try load(chunk)
            prefetch(chunk + 1)
            let base = Int((group - chunk * Int64(groupsPerChunk)) * groupSize)
            let take = min(remaining, blockSize - inBlock)
            guard base + channels * blockSize <= data.count else { throw DSDFile.bad }
            for c in 0..<channels {
                let s = base + c * blockSize + inBlock
                out[c] += data[s ..< s + take].map { DSDFile.reverse[Int($0)] }
            }
            pos += Int64(take)
            remaining -= take
        }
        return out
    }
}
