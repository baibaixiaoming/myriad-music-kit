import Foundation

/// DSD 数据来源：DSF、DFF 文件，或 SACD 镜像里的一首歌。播放核心只通过这个接口取数据。
/// 读出的数据为“每声道连续字节、每字节最早的比特在最高位”。
public protocol DSDSource: AnyObject, Sendable {
    var sampleRate: Int { get }
    var channels: Int { get }
    /// 每声道总比特数。
    var sampleCount: Int64 { get }
    func read(fromByte byteIndex: Int64, count: Int) throws -> [[UInt8]]
}

extension DSDSource {
    public var duration: Double { Double(sampleCount) / Double(sampleRate) }
    public var rateName: String { "DSD\(sampleRate / 44100)" }
}

extension DSDFile: DSDSource {}

/// SACD 镜像（ISO）：主目录、双声道区与多声道区、曲目表与曲目文字，以及按曲目读取 DSD 数据。
/// 扇区 2048 字节。第 510 扇区是主目录（SACDMTOC），后面是专辑文字（SACDText）；
/// 各区目录（TWOCHTOC / MULCHTOC）之后依次是曲目位置表（SACDTRL1）、曲目时间表（SACDTRL2）、曲目文字（SACDTTxt）。
public final class SACDImage: @unchecked Sendable {
    public enum AreaKind: Int, Sendable { case stereo = 2, multichannel = 6 }

    public struct Track: Sendable {
        public let number: Int
        public let title: String?
        public let performer: String?
        /// 起始时间与长度（帧，每秒 75 帧，从光盘开头算）。
        public let startFrame: Int
        public let frameCount: Int
        public var duration: Double { Double(frameCount) / 75 }
    }

    public struct Area: Sendable {
        public let kind: AreaKind
        public let channels: Int
        public let sampleRate: Int
        public let isDST: Bool
        public let tracks: [Track]
        let firstSector: Int
        let lastSector: Int
    }

    public let url: URL
    public let albumTitle: String?
    public let albumArtist: String?
    public let areas: [Area]
    let handle: FileReader
    private let lock = NSLock()

    public static let sectorSize = 2048
    public static let bad = NSError(domain: "SACD", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 SACD 镜像"])

    /// 只看主目录标记，判断一个文件是不是 SACD 镜像（不读整个文件）。
    public static func isSACD(_ url: URL) -> Bool {
        guard let h = try? FileReader(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(510 * sectorSize))) != nil, let d = try? h.read(upToCount: 8) else { return false }
        return d == Data("SACDMTOC".utf8)
    }

    public init(url: URL) throws {
        self.url = url
        let h = try FileReader(forReadingFrom: url)
        handle = h
        func sector(_ n: Int, count: Int = 1) throws -> Data {
            try h.seek(toOffset: UInt64(n * Self.sectorSize))
            guard let d = try h.read(upToCount: count * Self.sectorSize), d.count == count * Self.sectorSize else { throw Self.bad }
            return d
        }
        let master = try sector(510)
        guard master.prefix(8) == Data("SACDMTOC".utf8) else { throw Self.bad }
        // 专辑文字
        let text = try sector(511)
        func masterText(_ index: Int) -> String? {
            let off = Int(text.be16(16 + index * 2))
            return off > 0 ? Self.cString(text, at: off) : nil
        }
        albumTitle = masterText(0) ?? masterText(8)
        albumArtist = masterText(1) ?? masterText(9)

        var areas: [Area] = []
        for (tocIndex, expected) in [(64, "TWOCHTOC"), (72, "MULCHTOC")] {
            let tocSector = Int(master.be32(tocIndex))
            guard tocSector > 0 else { continue }
            let toc = try sector(tocSector)
            guard String(data: toc.prefix(8), encoding: .ascii) == expected else { continue }
            let fsCode = Int(toc[toc.startIndex + 20])
            let frameFormat = Int(toc[toc.startIndex + 21]) & 0x0F
            let channels = Int(toc[toc.startIndex + 32])
            let trackCount = Int(toc[toc.startIndex + 0x45])
            let first = Int(toc.be32(0x48)), last = Int(toc.be32(0x4C))
            // 曲目时间表、曲目文字：在区目录后面的若干扇区里，按标记查找
            let tocSize = max(2, Int(toc.be16(10)))
            let block = try sector(tocSector, count: min(tocSize, 64))
            var starts: [Int] = [], lengths: [Int] = []
            var titles = [String?](repeating: nil, count: trackCount)
            var performers = [String?](repeating: nil, count: trackCount)
            for s in 1..<min(tocSize, 64) {
                let base = s * Self.sectorSize
                let tag = String(data: block[base ..< base + 8], encoding: .ascii)
                if tag == "SACDTRL2" {
                    for t in 0..<trackCount {
                        starts.append(Self.timeFrames(block, at: base + 8 + t * 4))
                        lengths.append(Self.timeFrames(block, at: base + 8 + 255 * 4 + t * 4))
                    }
                } else if tag == "SACDTTxt" {
                    for t in 0..<trackCount {
                        let off = Int(block.be16(base + 8 + t * 2))
                        guard off > 0, base + off < block.count else { continue }
                        var p = base + off
                        let items = Int(block[p]); p += 4
                        for _ in 0..<items {
                            guard p + 2 < block.count else { break }
                            let type = block[p]; p += 2
                            let s = Self.cString(block, at: p)
                            p += (s?.utf8.count ?? 0) + 1
                            while p % 4 != 0 { p += 1 }
                            if type == 1, titles[t] == nil { titles[t] = s }
                            if type == 2, performers[t] == nil { performers[t] = s }
                        }
                    }
                }
            }
            guard starts.count == trackCount else { continue }
            let tracks = (0..<trackCount).map {
                Track(number: $0 + 1, title: titles[$0], performer: performers[$0], startFrame: starts[$0], frameCount: lengths[$0])
            }
            areas.append(Area(kind: expected == "TWOCHTOC" ? .stereo : .multichannel, channels: channels,
                              sampleRate: 44100 * 64 * (fsCode == 4 ? 1 : max(1, fsCode / 4)), isDST: frameFormat == 0,
                              tracks: tracks, firstSector: first, lastSector: last))
        }
        guard !areas.isEmpty else { throw Self.bad }
        self.areas = areas
    }

    deinit { try? handle.close() }

    /// 时间码（分、秒、帧）→ 帧数。
    static func timeFrames(_ d: Data, at i: Int) -> Int {
        let b = d.startIndex + i
        return (Int(d[b]) * 60 + Int(d[b + 1])) * 75 + Int(d[b + 2])
    }

    /// 以 0 结尾的文字。依次尝试 UTF-8、简体中文、繁体中文、日文、西欧编码。
    static func cString(_ d: Data, at i: Int) -> String? {
        var end = d.startIndex + i
        guard end < d.endIndex else { return nil }
        let start = end
        while end < d.endIndex, d[end] != 0 { end += 1 }
        let bytes = d[start..<end]
        guard !bytes.isEmpty else { return nil }
        let encodings: [String.Encoding] = [
            .utf8,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            .shiftJIS, .isoLatin1,
        ]
        for e in encodings { if let s = String(data: bytes, encoding: e) { return s.trimmingCharacters(in: .whitespaces) } }
        return nil
    }

    func readSectors(_ first: Int, count: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(first * Self.sectorSize))
        return try handle.read(upToCount: count * Self.sectorSize) ?? Data()
    }

    /// 某个区的某首歌的 DSD 数据来源。
    public func source(area: AreaKind, track: Int) throws -> SACDTrackSource {
        guard let a = areas.first(where: { $0.kind == area }), a.tracks.indices.contains(track - 1) else { throw Self.bad }
        return SACDTrackSource(image: self, area: a, track: a.tracks[track - 1])
    }
}

/// SACD 镜像里一首歌的 DSD 数据：按时间码定位帧，DST 帧解码，未压缩帧直接拆分声道。
/// 只在播放核心的读取线程里使用。
public final class SACDTrackSource: DSDSource, @unchecked Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let sampleCount: Int64
    let image: SACDImage
    let area: SACDImage.Area
    let track: SACDImage.Track
    private let bytesPerFrame: Int
    private let decoder: DSTDecoder?

    // 顺序读取的状态：下一帧所在扇区、已缓存的扇区数据、正在拼接的帧
    private var buffer = Data()
    private var bufferStart = 0
    private var cursorSector = 0
    private var pending: [Data] = []           // 已拼好、按顺序排列的帧
    private var pendingFirstFrame: Int?        // pending[0] 的帧号（光盘时间）；nil 表示还没有拼好的帧
    private var assembling: Data?
    private var assemblingFrame = -1
    private var frameQueue: [Int] = []          // 当前扇区里新开始的帧的帧号（来自帧信息）
    private var cached: (frame: Int, data: [[UInt8]])?

    init(image: SACDImage, area: SACDImage.Area, track: SACDImage.Track) {
        self.image = image
        self.area = area
        self.track = track
        sampleRate = area.sampleRate
        channels = area.channels
        bytesPerFrame = area.sampleRate / 75 / 8
        sampleCount = Int64(track.frameCount) * Int64(area.sampleRate / 75)
        decoder = area.isDST ? DSTDecoder(channels: area.channels, dsdRate: area.sampleRate) : nil
    }

    public func read(fromByte byteIndex: Int64, count: Int) throws -> [[UInt8]] {
        let total = sampleCount / 8
        let n = Int(max(0, min(Int64(count), total - byteIndex)))
        var out = Array(repeating: [UInt8](), count: channels)
        guard n > 0 else { return out }
        var pos = byteIndex, remaining = n
        while remaining > 0 {
            let index = Int(pos / Int64(bytesPerFrame)), inFrame = Int(pos % Int64(bytesPerFrame))
            let frame = try decodedFrame(track.startFrame + index)
            let take = min(remaining, bytesPerFrame - inFrame)
            for c in 0..<channels { out[c] += frame[c][inFrame ..< inFrame + take] }
            pos += Int64(take); remaining -= take
        }
        return out
    }

    private func decodedFrame(_ frameNumber: Int) throws -> [[UInt8]] {
        if let c = cached, c.frame == frameNumber { return c.data }
        let raw = try rawFrame(frameNumber)
        let data: [[UInt8]]
        if let decoder {
            data = try decoder.decode(raw)
        } else {
            // 未压缩：按声道逐字节交错
            var d = Array(repeating: [UInt8](repeating: 0x69, count: bytesPerFrame), count: channels)
            raw.withUnsafeBytes { p in
                let b = p.bindMemory(to: UInt8.self)
                for i in 0..<bytesPerFrame { for c in 0..<channels where i * channels + c < b.count { d[c][i] = b[i * channels + c] } }
            }
            data = d
        }
        cached = (frameNumber, data)
        return data
    }

    // MARK: 取原始帧

    private func rawFrame(_ frameNumber: Int) throws -> Data {
        // 顺序播放：下一帧已经在 pending 里，或接着往后读就能拿到
        if let first = pendingFirstFrame, frameNumber >= first, frameNumber <= first + pending.count + 8 {
            // 顺序播放：接着往后读即可
        } else {
            try seek(to: frameNumber)
        }
        while (pendingFirstFrame.map { frameNumber >= $0 + pending.count } ?? true) {
            guard try readNextSector() else { break }
        }
        guard let first = pendingFirstFrame else { throw SACDImage.bad }
        let i = frameNumber - first
        guard pending.indices.contains(i) else { throw SACDImage.bad }
        let frame = pending[i]
        // 已用过的帧丢掉
        if i > 0 { pending.removeFirst(i); pendingFirstFrame = first + i }
        return frame
    }

    /// 二分查找：找到“第一个新帧的时间码 ≤ 目标”的最后一个扇区，从那里开始顺序读。
    private func seek(to frameNumber: Int) throws {
        var lo = area.firstSector, hi = area.lastSector
        var best = lo
        var steps = 0
        while lo <= hi, steps < 40 {
            steps += 1
            let mid = (lo + hi) / 2
            // 从 mid 往后找第一个带帧信息的扇区
            var s = mid, found: (sector: Int, frame: Int)?
            while s <= min(hi, mid + 16) {
                let d = try image.readSectors(s, count: 1)
                if let f = Self.firstFrameNumber(d) { found = (s, f); break }
                s += 1
            }
            guard let found else { hi = mid - 1; continue }
            if found.frame <= frameNumber { best = found.sector; lo = found.sector + 1 } else { hi = mid - 1 }
        }
        cursorSector = best
        buffer = Data(); bufferStart = 0
        pending = []; assembling = nil; assemblingFrame = -1
        pendingFirstFrame = nil
        // 读到目标帧为止（丢掉之前的帧）
        while true {
            guard try readNextSector() else { break }
            if let first = pendingFirstFrame, first + pending.count > frameNumber { break }
        }
        if let first = pendingFirstFrame, frameNumber > first {
            let drop = min(pending.count, frameNumber - first)
            pending.removeFirst(drop); pendingFirstFrame = first + drop
        }
    }

    /// 扇区头：第一字节高 3 位为数据包个数、接着 3 位为帧信息个数、最低位为 DST 标志；
    /// 数据包信息每个 2 字节（帧起始 1 位、保留 1 位、类型 3 位（2 为音频）、长度 11 位）；
    /// 帧信息每个 3 字节时间码（DST 时再加 1 字节）。
    static func parseHeader(_ d: Data) -> (packets: [(start: Bool, type: Int, length: Int)], frames: [Int], headerLength: Int) {
        let b = d.startIndex
        let h = d[b]
        let pic = Int(h >> 5), fic = Int((h >> 2) & 7), dst = h & 1 == 1
        var pos = 1
        var packets: [(Bool, Int, Int)] = []
        for _ in 0..<pic {
            let v = Int(d[b + pos]) << 8 | Int(d[b + pos + 1]); pos += 2
            packets.append(((v >> 15) & 1 == 1, (v >> 11) & 7, v & 0x7FF))
        }
        var frames: [Int] = []
        for _ in 0..<fic {
            frames.append(SACDImage.timeFrames(d, at: pos))
            pos += dst ? 4 : 3
        }
        return (packets, frames, pos)
    }

    static func firstFrameNumber(_ d: Data) -> Int? {
        guard !d.isEmpty else { return nil }
        return parseHeader(d).frames.first
    }

    /// 读一个扇区，把其中的音频数据拼进帧。返回 false 表示读到区尾。
    private func readNextSector() throws -> Bool {
        guard cursorSector <= area.lastSector else {
            if let a = assembling, assemblingFrame >= 0 {
                if pendingFirstFrame == nil || pending.isEmpty { pendingFirstFrame = assemblingFrame }
                pending.append(a)
            }
            assembling = nil
            return false
        }
        // 一次读 64 个扇区缓存起来，顺序播放时少读文件
        if cursorSector < bufferStart || cursorSector >= bufferStart + buffer.count / SACDImage.sectorSize {
            bufferStart = cursorSector
            buffer = try image.readSectors(cursorSector, count: min(64, area.lastSector - cursorSector + 1))
            guard !buffer.isEmpty else { return false }
        }
        let off = (cursorSector - bufferStart) * SACDImage.sectorSize
        let d = buffer.subdata(in: off ..< off + SACDImage.sectorSize)
        cursorSector += 1
        let (packets, frames, headerLength) = Self.parseHeader(d)
        var pos = headerLength
        var frameInfo = frames.makeIterator()
        for p in packets {
            let data = d.subdata(in: pos ..< min(d.count, pos + p.length))
            pos += p.length
            guard p.type == 2 else { continue }
            if p.start {
                if let a = assembling, assemblingFrame >= 0 {
                    if pendingFirstFrame == nil || pending.isEmpty { pendingFirstFrame = assemblingFrame }
                    pending.append(a)
                }
                assembling = Data()
                assemblingFrame = frameInfo.next() ?? (assemblingFrame + 1)
            }
            assembling?.append(data)
        }
        return true
    }
}
