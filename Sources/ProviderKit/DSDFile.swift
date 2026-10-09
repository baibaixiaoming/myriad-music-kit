import Foundation

/// DSD 音频文件（DSF、DFF）的读取：格式信息、标签、按块读取原始 1 比特数据。
/// 读出的数据统一为“每声道连续字节、每字节最早的比特在最高位”，供 DoP 打包或转换为 PCM。
public final class DSDFile: @unchecked Sendable {
    public enum Container: Sendable { case dsf, dff }

    public let url: URL
    public let container: Container
    /// DSD 采样率（每秒比特数），如 2_822_400（DSD64）。
    public let sampleRate: Int
    public let channels: Int
    /// 每声道总比特数（即总采样数）。
    public let sampleCount: Int64
    public private(set) var title: String?
    public private(set) var artist: String?
    public private(set) var album: String?
    public private(set) var trackNumber: Int?
    /// 全部标签（通用键名，如 ALBUMARTIST、DISCNUMBER、DATE），整理资料库用。
    public private(set) var rawTags: [String: [String]] = [:]

    private let handle: FileReader
    private let dataOffset: UInt64
    /// DSF：每声道块大小（通常 4096 字节）。DFF 为交错存储，此值为 0。
    private let blockSize: Int
    /// DST 压缩的 DFF：每帧在文件中的位置，以及解码器与最近解码的一帧（顺序播放时每帧只解一次）。
    struct DSTFrame { let offset: UInt64; let length: Int }
    private var dstFrames: [DSTFrame] = []
    private var dstDecoder: DSTDecoder?
    private var cachedFrame: (index: Int, data: [[UInt8]])?
    /// 是否为 DST 压缩。
    public var isDSTCompressed: Bool { dstDecoder != nil }

    public var duration: Double { Double(sampleCount) / Double(sampleRate) }
    /// DSD64、DSD128……
    public var rateName: String { "DSD\(sampleRate / 44100)" }

    public init(url: URL) throws {
        self.url = url
        var pendingMeta: UInt64 = 0
        var pendingTitle: (String?, String?)?
        let fh = try FileReader(forReadingFrom: url)
        handle = fh
        let head = try fh.read(upToCount: 4) ?? Data()
        switch String(data: head, encoding: .ascii) {
        case "DSD ":
            container = .dsf
            // DSD 块：28 字节；fmt 块：52 字节
            try fh.seek(toOffset: 0)
            let h = try Self.read(fh, 28 + 52)
            guard String(data: h[28..<32], encoding: .ascii) == "fmt " else { throw Self.bad }
            let metaOffset = h.le64(20)
            channels = Int(h.le32(28 + 24))
            sampleRate = Int(h.le32(28 + 28))
            let bits = h.le32(28 + 32)
            guard bits == 1 else { throw Self.bad }          // 只支持最低位在前（标准 DSF 都是 1）
            sampleCount = Int64(h.le64(28 + 36))
            blockSize = Int(h.le32(28 + 44))
            // data 块
            let d = try Self.read(fh, 12)
            guard String(data: d[0..<4], encoding: .ascii) == "data" else { throw Self.bad }
            dataOffset = 28 + 52 + 12
            pendingMeta = metaOffset
        case "FRM8":
            container = .dff
            blockSize = 0
            var rate = 0, ch = 0, offset: UInt64 = 0, size: UInt64 = 0
            var foundTitle: String?, foundArtist: String?
            var dst = false
            var frames: [DSTFrame] = []
            try fh.seek(toOffset: 16)                    // FRM8 + 大小 + "DSD "
            // 逐块读取：PROP（含 FS、CHNL、CMPR）、DSD（数据）、DIIN（标签）
            func walk(_ end: UInt64) throws {
                while try fh.offset() + 12 <= end {
                    let h = try Self.read(fh, 12)
                    let id = String(data: h[0..<4], encoding: .ascii) ?? ""
                    let len = h.be64(4)
                    let start = try fh.offset()
                    switch id {
                    case "PROP":
                        _ = try Self.read(fh, 4)         // "SND "
                        try walk(start + len)
                    case "FS  ": rate = Int(try Self.read(fh, 4).be32(0))
                    case "CHNL": ch = Int(try Self.read(fh, 2).be16(0))
                    case "CMPR":
                        switch String(data: try Self.read(fh, 4), encoding: .ascii) {
                        case "DSD ": break
                        case "DST ": dst = true
                        default: throw Self.compressed
                        }
                    case "DSD ": offset = start; size = len
                    // DST 压缩：数据块里依次是 FRTE（帧数）和一个个 DSTF（每帧 1/75 秒）
                    case "DST ": offset = start; size = len; try walk(start + len)
                    case "DSTF": frames.append(DSTFrame(offset: start, length: Int(len)))
                    case "DIIN": try walk(start + len)
                    case "DITI": foundTitle = Self.dffText(try Self.read(fh, Int(len)))
                    case "DIAR": foundArtist = Self.dffText(try Self.read(fh, Int(len)))
                    default: break
                    }
                    try fh.seek(toOffset: start + len + (len & 1))
                }
            }
            let total = try fh.seekToEnd()
            try fh.seek(toOffset: 16)
            try walk(total)
            guard rate > 0, ch > 0, size > 0 else { throw Self.bad }
            sampleRate = rate
            channels = ch
            dataOffset = offset
            if dst {
                guard !frames.isEmpty else { throw Self.bad }
                dstFrames = frames
                dstDecoder = DSTDecoder(channels: ch, dsdRate: rate)
                sampleCount = Int64(frames.count) * Int64(rate / 75)
            } else {
                sampleCount = Int64(size) * 8 / Int64(ch)
            }
            pendingTitle = (foundTitle, foundArtist)
        default:
            throw Self.bad
        }
            if pendingMeta > 0 { readID3(at: pendingMeta) }
        if let t = pendingTitle { title = t.0; artist = t.1 }
    }

    deinit { try? handle.close() }

    static let bad = NSError(domain: "DSD", code: 1, userInfo: [NSLocalizedDescriptionKey: "不是有效的 DSD 文件"])
    static let compressed = NSError(domain: "DSD", code: 2, userInfo: [NSLocalizedDescriptionKey: "不支持这种压缩方式的 DSD 文件"])

    /// 读取从第 `byteIndex` 个字节（每声道计）开始的 `count` 个字节，按声道分开返回。
    /// 统一为每字节最早的比特在最高位。超出文件末尾的部分不返回。
    public func read(fromByte byteIndex: Int64, count: Int) throws -> [[UInt8]] {
        let totalBytes = sampleCount / 8
        let n = Int(max(0, min(Int64(count), totalBytes - byteIndex)))
        guard n > 0 else { return Array(repeating: [], count: channels) }
        var out = Array(repeating: [UInt8](), count: channels)
        if let decoder = dstDecoder {
            let bpf = decoder.bytesPerFrame
            var pos = byteIndex
            var remaining = n
            for c in 0..<channels { out[c].reserveCapacity(n) }
            while remaining > 0 {
                let index = Int(pos / Int64(bpf)), inFrame = Int(pos % Int64(bpf))
                let frame = try decodedFrame(index, decoder)
                let take = min(remaining, bpf - inFrame)
                for c in 0..<channels { out[c] += frame[c][inFrame ..< inFrame + take] }
                pos += Int64(take)
                remaining -= take
            }
            return out
        }
        switch container {
        case .dff:
            try handle.seek(toOffset: dataOffset + UInt64(byteIndex) * UInt64(channels))
            let raw = try Self.read(handle, n * channels)
            for c in 0..<channels { out[c].reserveCapacity(n) }
            raw.withUnsafeBytes { p in
                for i in 0..<n { for c in 0..<channels { out[c].append(p[i * channels + c]) } }
            }
        case .dsf:
            // 每个块组：各声道各 blockSize 字节；字节内最低位在前，需要翻转
            var pos = byteIndex
            var remaining = n
            while remaining > 0 {
                let group = pos / Int64(blockSize), inBlock = Int(pos % Int64(blockSize))
                let take = min(remaining, blockSize - inBlock)
                for c in 0..<channels {
                    let off = dataOffset + UInt64(group) * UInt64(blockSize * channels) + UInt64(c * blockSize + inBlock)
                    try handle.seek(toOffset: off)
                    let raw = try Self.read(handle, take)
                    out[c] += raw.map { Self.reverse[Int($0)] }
                }
                pos += Int64(take)
                remaining -= take
            }
        }
        return out
    }

    private func decodedFrame(_ index: Int, _ decoder: DSTDecoder) throws -> [[UInt8]] {
        if let c = cachedFrame, c.index == index { return c.data }
        guard dstFrames.indices.contains(index) else { throw Self.bad }
        let f = dstFrames[index]
        try handle.seek(toOffset: f.offset)
        let data = try decoder.decode(try Self.read(handle, f.length))
        cachedFrame = (index, data)
        return data
    }

    static let reverse: [UInt8] = (0..<256).map { v in
        var r: UInt8 = 0, x = UInt8(v)
        for _ in 0..<8 { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }

    static func read(_ h: FileReader, _ n: Int) throws -> Data {
        guard let d = try h.read(upToCount: n), d.count == n else { throw bad }
        return d
    }

    static func dffText(_ d: Data) -> String? {
        guard d.count > 4 else { return nil }
        let len = Int(d.be32(0))
        return String(data: d.subdata(in: 4..<min(d.count, 4 + len)), encoding: .utf8)
    }

    /// DSF 文件末尾的 ID3v2 标签：只取歌名、歌手、专辑、音轨号。
    private func readID3(at offset: UInt64) {
        guard (try? handle.seek(toOffset: offset)) != nil, let head = try? handle.read(upToCount: 10), head.count == 10,
              String(data: head[0..<3], encoding: .ascii) == "ID3" else { return }
        let version = head[3]
        let size = Int(head[6] & 0x7F) << 21 | Int(head[7] & 0x7F) << 14 | Int(head[8] & 0x7F) << 7 | Int(head[9] & 0x7F)
        guard let body = try? handle.read(upToCount: size) else { return }
        var i = 0
        while i + 10 <= body.count {
            let id = String(data: body[i..<i + 4], encoding: .ascii) ?? ""
            guard id.first?.isLetter == true || id.first?.isNumber == true else { break }
            let len = version >= 4
                ? Int(body[i + 4] & 0x7F) << 21 | Int(body[i + 5] & 0x7F) << 14 | Int(body[i + 6] & 0x7F) << 7 | Int(body[i + 7] & 0x7F)
                : Int(body.be32(i + 4))
            let start = i + 10, end = min(body.count, start + len)
            if start < end {
                let text = Self.id3Text(body.subdata(in: start..<end))
                switch id {
                case "TIT2": title = text
                case "TPE1": artist = text
                case "TALB": album = text
                case "TRCK": trackNumber = text.flatMap { Int($0.split(separator: "/").first ?? "") }
                default: break
                }
                let names = ["TIT2": "TITLE", "TPE1": "ARTIST", "TPE2": "ALBUMARTIST", "TALB": "ALBUM", "TRCK": "TRACKNUMBER",
                             "TPOS": "DISCNUMBER", "TYER": "DATE", "TDRC": "DATE", "TCMP": "COMPILATION",
                             "TCOM": "COMPOSER", "TPE3": "CONDUCTOR", "TPUB": "LABEL", "TCON": "GENRE",
                             "TIT1": "WORK", "MVNM": "MOVEMENTNAME"]
                if let name = names[id], let text { rawTags[name, default: []] += text.split(separator: "\0").map(String.init) }
                // 演奏者名单（TMCL、旧版 TIPL）：“乐器\0人名\0乐器\0人名……”，转成“人名 (乐器)”
                if id == "TMCL" || id == "TIPL", let text {
                    let parts = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                    var k = 0
                    while k + 1 < parts.count {
                        let role = parts[k], name = parts[k + 1]
                        if !name.isEmpty {
                            // TIPL 里多是制作人员（录音师、制作人），只收常见演奏角色
                            if id == "TMCL" || ["conductor", "orchestra", "performer", "soloist"].contains(role.lowercased()) {
                                rawTags["PERFORMER", default: []].append(role.isEmpty ? name : "\(name) (\(role))")
                            }
                        }
                        k += 2
                    }
                }
                // 自定义文字：说明\0值
                if id == "TXXX", let text, let nul = text.firstIndex(of: "\0") {
                    rawTags[String(text[..<nul]), default: []].append(String(text[text.index(after: nul)...]))
                }
            }
            i = end
        }
    }

    static func id3Text(_ d: Data) -> String? {
        guard let enc = d.first else { return nil }
        let body = d.dropFirst()
        let s: String? = switch enc {
        case 1: String(data: body, encoding: .utf16)
        case 2: String(data: body, encoding: .utf16BigEndian)
        case 3: String(data: body, encoding: .utf8)
        default: String(data: body, encoding: .isoLatin1)
        }
        return s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
            .replacingOccurrences(of: "\0\0", with: "\0")
    }
}

extension Data {
    func le32(_ i: Int) -> UInt32 { self[startIndex + i ..< startIndex + i + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    func le64(_ i: Int) -> UInt64 { self[startIndex + i ..< startIndex + i + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
    func be16(_ i: Int) -> UInt16 { self[startIndex + i ..< startIndex + i + 2].reduce(0) { $0 << 8 | UInt16($1) } }
    func be32(_ i: Int) -> UInt32 { self[startIndex + i ..< startIndex + i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func be64(_ i: Int) -> UInt64 { self[startIndex + i ..< startIndex + i + 8].reduce(0) { $0 << 8 | UInt64($1) } }
}
