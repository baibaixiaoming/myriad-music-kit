// 本文件按 Monkey's Audio SDK 改写，除本项目的 MIT 许可外，还须遵守其许可：
// Copyright 2000-2026 Matthew T. Ashland. All rights reserved.
// 3 clause BSD license — 全文见 LICENSES/MonkeysAudio-BSD-3-Clause.txt

import Foundation

/// Monkey's Audio（APE）无损音频文件的读取与解码。
/// 解码算法按 Monkey's Audio SDK（BSD 三条款许可，版权 Matthew T. Ashland）改写为 Swift，
/// 支持 3.99 及以后版本写出的文件（2004 年以来的全部常见文件），各压缩级别、8/16/24/32 位整数与 32 位浮点。
///
/// 结构：文件分帧（通常每帧约 4.6 万到 7.3 万个采样块），帧与帧互不依赖，可随机跳转。
/// 每帧依次是：校验值、特殊标志（静音、伪立体声）、区间编码的残差；残差经神经网络滤波器
/// 和自适应预测器还原为中/侧声道，再换回左右声道。
public final class APEFile: @unchecked Sendable {
    public enum APEError: Error, Equatable {
        case invalid(String)
        case unsupported(String)
    }

    public let url: URL
    public let version: Int
    public let compressionLevel: Int
    public let formatFlags: Int
    public let blocksPerFrame: Int
    public let finalFrameBlocks: Int
    public let totalFrames: Int
    public let bitsPerSample: Int
    public let channels: Int
    public let sampleRate: Int
    /// 每声道总采样数。
    public let totalBlocks: Int64
    public private(set) var title: String?
    public private(set) var artist: String?
    public private(set) var album: String?
    public private(set) var trackNumber: Int?
    /// 全部标签（原样的键名），整理资料库用。
    public private(set) var rawTags: [String: [String]] = [:]

    /// 32 位浮点（MACF）。
    public var isFloat: Bool { formatFlags & 0x1000 != 0 }
    public var bytesPerSample: Int { bitsPerSample / 8 }
    /// 每个采样块（各声道一个采样）的字节数。
    public var blockAlign: Int { bytesPerSample * channels }
    public var duration: Double { Double(totalBlocks) / Double(sampleRate) }

    private let handle: FileReader
    private let fileSize: Int64
    private let terminatingBytes: Int64
    /// 每帧在文件中的起点。
    private let seekTable: [Int64]
    private var cachedFrame: (index: Int, data: [UInt8])?
    /// 24 位文件：某些旧版编码器的中间版本（8.50 之前）计算方式略有不同，校验失败时切换并保持。
    private var interim = false

    public init(url: URL) throws {
        self.url = url
        let fh = try FileReader(forReadingFrom: url)
        handle = fh
        fileSize = Int64(try fh.seekToEnd())
        let junk = try Self.findDescriptor(fh)
        try fh.seek(toOffset: UInt64(junk))
        let common = try Self.read(fh, 6)
        let ver = Int(common.le16(4))
        guard ver >= 3990 else { throw APEError.unsupported("过旧的 APE 文件（版本 \(ver)）") }
        version = ver
        try fh.seek(toOffset: UInt64(junk))
        let d = try Self.read(fh, 52)
        let descriptorBytes = Int64(d.le32(8)), headerBytes = Int64(d.le32(12))
        let seekTableBytes = Int(d.le32(16))
        terminatingBytes = Int64(d.le32(32))
        try fh.seek(toOffset: UInt64(junk + descriptorBytes))
        let h = try Self.read(fh, 24)
        compressionLevel = Int(h.le16(0))
        formatFlags = Int(h.le16(2))
        blocksPerFrame = Int(h.le32(4))
        finalFrameBlocks = Int(h.le32(8))
        totalFrames = Int(h.le32(12))
        bitsPerSample = Int(h.le16(16))
        channels = Int(h.le16(18))
        sampleRate = Int(h.le32(20))
        guard (1...32).contains(channels), [8, 16, 24, 32].contains(bitsPerSample), sampleRate > 0,
              blocksPerFrame > 0, blocksPerFrame <= 10_000_000, finalFrameBlocks <= blocksPerFrame, totalFrames > 0,
              [1000, 2000, 3000, 4000, 5000].contains(compressionLevel) else { throw APEError.invalid("文件头错误") }
        totalBlocks = Int64(totalFrames - 1) * Int64(blocksPerFrame) + Int64(finalFrameBlocks)
        // 寻址表：32 位偏移，超过 4GB 时回绕
        try fh.seek(toOffset: UInt64(junk + descriptorBytes + headerBytes))
        let count = min(seekTableBytes / 4, totalFrames)
        guard count == totalFrames else { throw APEError.invalid("寻址表不完整") }
        let raw = try Self.read(fh, count * 4)
        var table = [Int64](), add: Int64 = 0, previous: UInt32 = 0
        table.reserveCapacity(count)
        for i in 0..<count {
            let v = raw.le32(i * 4)
            if v < previous { add += 1 << 32 }
            table.append(add + Int64(v) + junk)
            previous = v
        }
        seekTable = table
        readAPETag()
    }

    deinit { try? handle.close() }

    // MARK: 读取

    /// 读取从第 `block` 个采样块开始的 `count` 块，返回交错的小端 PCM 字节（8 位为无符号，浮点为 32 位浮点）。
    public func read(fromBlock block: Int64, count: Int) throws -> [UInt8] {
        let n = Int(max(0, min(Int64(count), totalBlocks - block)))
        guard n > 0 else { return [] }
        var out = [UInt8]()
        out.reserveCapacity(n * blockAlign)
        var pos = block, remaining = n
        while remaining > 0 {
            let index = Int(pos / Int64(blocksPerFrame)), inFrame = Int(pos % Int64(blocksPerFrame))
            let frame = try decodedFrame(index)
            let available = frame.count / blockAlign - inFrame
            guard available > 0 else { break }
            let take = min(remaining, available)
            out += frame[inFrame * blockAlign ..< (inFrame + take) * blockAlign]
            pos += Int64(take)
            remaining -= take
        }
        return out
    }

    func blocks(inFrame index: Int) -> Int { index == totalFrames - 1 ? finalFrameBlocks : blocksPerFrame }

    private func decodedFrame(_ index: Int) throws -> [UInt8] {
        if let c = cachedFrame, c.index == index { return c.data }
        let data = try decodeFrame(index)
        cachedFrame = (index, data)
        return data
    }

    /// 解码一帧。校验失败时（24 位文件先尝试兼容算法）返回静音，避免整首中断。
    public func decodeFrame(_ index: Int) throws -> [UInt8] {
        guard seekTable.indices.contains(index) else { throw APEError.invalid("帧序号越界") }
        // 帧按 4 字节对齐读取（相对第一帧），前面多出的字节跳过
        let start = seekTable[index]
        let remainder = Int((start - seekTable[0]) % 4)
        let end = index + 1 < totalFrames ? seekTable[index + 1] : fileSize - terminatingBytes
        let frameBytes = Int(max(0, end - start)) + remainder + 4
        try handle.seek(toOffset: UInt64(start - Int64(remainder)))
        let raw = try handle.read(upToCount: frameBytes) ?? Data()
        guard raw.count >= frameBytes - 4 else { throw APEError.invalid("文件不完整") }
        // 码流以小端 32 位字为单位、每字从高位读起：把每 4 字节倒序后即可按字节顺序读
        var stream = [UInt8](repeating: 0, count: (raw.count + 3) / 4 * 4 + 16)
        raw.withUnsafeBytes { p in
            for i in 0..<p.count { stream[(i & ~3) + 3 - (i & 3)] = p[i] }
        }
        let blocks = blocks(inFrame: index)
        if let pcm = decode(stream: stream, skip: remainder, blocks: blocks, interim: interim) { return pcm }
        if bitsPerSample == 24, !interim, let pcm = decode(stream: stream, skip: remainder, blocks: blocks, interim: true) {
            interim = true
            return pcm
        }
        Log.write(nil, "APE 第 \(index) 帧校验失败：\(url.lastPathComponent)")
        let silence: UInt8 = bitsPerSample == 8 ? 128 : 0
        return [UInt8](repeating: silence, count: blocks * blockAlign)
    }

    /// 解一帧码流；失败（越界、校验不符）返回 nil。
    private func decode(stream: [UInt8], skip: Int, blocks: Int, interim: Bool) -> [UInt8]? {
        var rc = RangeDecoder(stream: stream, position: skip)
        var storedCRC = rc.uint32()
        var special: UInt32 = 0
        if storedCRC & 0x8000_0000 != 0 { special = rc.uint32() }
        storedCRC &= 0x7FFF_FFFF
        rc.start()

        let wide = bitsPerSample == 32
        var states = [RangeDecoder.State](repeating: .init(), count: channels)
        var narrow: [Predictor32] = wide ? [] : (0..<channels).map { _ in
            Predictor32(level: compressionLevel, interim: interim && bitsPerSample > 16) }
        var wideP: [Predictor64] = wide ? (0..<channels).map { _ in Predictor64(level: compressionLevel) } : []
        func predict(_ ch: Int, _ a: Int64, _ b: Int64) -> Int32 {
            wide ? wideP[ch].decompress(a, b) : narrow[ch].decompress(a, b)
        }

        var values = [Int32](repeating: 0, count: max(channels, 2))
        var samples = [Int32](repeating: 0, count: blocks * channels)
        var ok = true
        samples.withUnsafeMutableBufferPointer { out in
            var o = 0
            func emit() {
                // 中/侧换回左右（与官方解码器相同的声道组合方式）
                if channels == 2 {
                    let r = values[0] &- values[1] / 2
                    out[o] = r; out[o + 1] = r &+ values[1]
                } else if channels > 2, bitsPerSample == 16 || bitsPerSample == 24, channels == 4 || channels >= 6 {
                    func pair(_ i: Int) { let r = values[i] &- values[i + 1] / 2; out[o + i] = r; out[o + i + 1] = r &+ values[i + 1] }
                    pair(0)
                    if channels == 4 { pair(2) } else {
                        out[o + 2] = values[2]; out[o + 3] = values[3]
                        pair(4)
                        if channels >= 8 { pair(6) }
                        for c in 8 ..< max(8, channels) { out[o + c] = values[c] }
                        if channels == 7 { out[o + 6] = values[6] }
                    }
                } else {
                    for c in 0..<channels { out[o + c] = values[c] }
                }
                o += channels
            }
            if channels > 2 {
                for _ in 0..<blocks {
                    for c in 0..<channels { values[c] = predict(c, rc.value(&states[c]), 0) }
                    emit()
                }
            } else if channels == 2 {
                if special & 3 == 3 {
                    values[0] = 0; values[1] = 0
                    for _ in 0..<blocks { emit() }
                } else if special & 4 != 0 {
                    values[1] = 0
                    for _ in 0..<blocks { values[0] = predict(0, rc.value(&states[0]), 0); emit() }
                } else {
                    var lastX: Int32 = 0
                    for _ in 0..<blocks {
                        let y = rc.value(&states[1])
                        let x = rc.value(&states[0])
                        let yv = predict(1, y, Int64(lastX))
                        let xv = predict(0, x, Int64(yv))
                        lastX = xv
                        values[0] = xv; values[1] = yv
                        emit()
                    }
                }
            } else {
                if special & 1 != 0 {
                    values[0] = 0
                    for _ in 0..<blocks { emit() }
                } else {
                    for _ in 0..<blocks { values[0] = predict(0, rc.value(&states[0]), 0); emit() }
                }
            }
            if rc.failed { ok = false }
        }
        guard ok else { return nil }
        if bitsPerSample == 16, samples.contains(where: { $0 < -32768 || $0 > 32767 }) { return nil }

        // 写成小端 PCM 字节
        let bps = bytesPerSample
        var pcm = [UInt8](repeating: 0, count: samples.count * bps)
        pcm.withUnsafeMutableBufferPointer { p in
            for (i, v) in samples.enumerated() {
                if bps == 1 { p[i] = UInt8(truncatingIfNeeded: v &+ 128); continue }
                let u = UInt32(bitPattern: v)
                for b in 0..<bps { p[i * bps + b] = UInt8(truncatingIfNeeded: u >> (8 * b)) }
            }
        }
        // 校验：标准 CRC-32（与压缩包等相同），取反后右移一位；浮点变换在校验之后
        let crc = (CRC32.update(0xFFFF_FFFF, pcm) ^ 0xFFFF_FFFF) >> 1
        guard crc == storedCRC else { return nil }
        if isFloat, bps == 4 {
            pcm.withUnsafeMutableBytes { raw in
                let w = raw.bindMemory(to: UInt32.self)
                for i in w.indices {
                    let u = UInt32(littleEndian: w[i])
                    var t = (u & 0xC3FF_FFFF) | (~(u & 0x3C00_0000) ^ 0xC3FF_FFFF)
                    if t & 0x8000_0000 != 0 { t = ~t | 0x8000_0000 }
                    w[i] = t.littleEndian
                }
            }
        }
        return pcm
    }

    // MARK: 文件头与标签

    /// 跳过文件开头可能有的 ID3v2 标签，找到 “MAC ” 或 “MACF” 标记。
    static func findDescriptor(_ fh: FileReader) throws -> Int64 {
        try fh.seek(toOffset: 0)
        var junk: Int64 = 0
        let id3 = try fh.read(upToCount: 10) ?? Data()
        if id3.count == 10, id3.prefix(3) == Data("ID3".utf8) {
            let size = Int64(id3[6] & 0x7F) << 21 | Int64(id3[7] & 0x7F) << 14 | Int64(id3[8] & 0x7F) << 7 | Int64(id3[9] & 0x7F)
            let footer = id3[5] & 16 != 0
            junk = size + (footer ? 20 : 10)
            if !footer {
                try fh.seek(toOffset: UInt64(junk))
                while let b = try fh.read(upToCount: 1), b.first == 0 { junk += 1 }
            }
        }
        try fh.seek(toOffset: UInt64(junk))
        let window = try fh.read(upToCount: 1024 * 1024 + 4) ?? Data()
        let bytes = [UInt8](window)
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i] == 0x4D, bytes[i + 1] == 0x41, bytes[i + 2] == 0x43, bytes[i + 3] == 0x20 || bytes[i + 3] == 0x46 {
                return junk + Int64(i)
            }
            i += 1
        }
        throw APEError.invalid("不是 APE 文件")
    }

    static func read(_ h: FileReader, _ n: Int) throws -> Data {
        guard let d = try h.read(upToCount: n), d.count == n else { throw APEError.invalid("文件不完整") }
        return d
    }

    /// 文件末尾的 APEv2 标签（可能其后还有 128 字节的 ID3v1）。
    private func readAPETag() {
        for tail: Int64 in [32, 160] where fileSize >= tail {
            guard (try? handle.seek(toOffset: UInt64(fileSize - tail))) != nil,
                  let f = try? handle.read(upToCount: 32), f.count == 32, f.prefix(8) == Data("APETAGEX".utf8) else { continue }
            let size = Int(f.le32(12)), items = Int(f.le32(16))
            guard size > 32, Int64(size) <= fileSize - tail + 32,
                  (try? handle.seek(toOffset: UInt64(fileSize - tail + 32 - Int64(size)))) != nil,
                  let body = try? handle.read(upToCount: size - 32) else { return }
            let b = [UInt8](body)
            var i = 0
            for _ in 0..<items {
                guard i + 8 < b.count else { break }
                let len = Int(UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24)
                i += 8
                guard let nul = b[i...].firstIndex(of: 0) else { break }
                let key = String(decoding: b[i..<nul], as: UTF8.self).lowercased()
                let vs = nul + 1, ve = min(b.count, vs + len)
                guard vs <= ve else { break }
                let value = String(decoding: b[vs..<ve], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
                // APEv2 的多个值用 \0 分隔
                rawTags[key.uppercased(), default: []] += value.split(separator: "\0").map(String.init)
                switch key {
                case "title": title = value
                case "artist": artist = value
                case "album": album = value
                case "track": trackNumber = Int(value.split(separator: "/").first ?? "")
                default: break
                }
                i = ve
            }
            return
        }
    }
}

// MARK: - 区间解码器

/// 残差的区间（算术）解码，对应官方 CUnBitArray（3.99 起的格式）。
struct RangeDecoder {
    struct State { var k: Int = 10; var kSum: UInt32 = 1 << 14 }

    static let rangeTotal: [UInt32] = [0, 19578, 36160, 48417, 56323, 60899, 63265, 64435, 64971, 65232, 65351, 65416, 65447, 65466, 65476,
        65482, 65485, 65488, 65490, 65491, 65492, 65493, 65494, 65495, 65496, 65497, 65498, 65499, 65500, 65501, 65502, 65503, 65504,
        65505, 65506, 65507, 65508, 65509, 65510, 65511, 65512, 65513, 65514, 65515, 65516, 65517, 65518, 65519, 65520, 65521, 65522,
        65523, 65524, 65525, 65526, 65527, 65528, 65529, 65530, 65531, 65532, 65533, 65534, 65535, 65536]
    static let rangeWidth: [UInt32] = (0..<64).map { rangeTotal[$0 + 1] - rangeTotal[$0] }
    /// 0…65535 → 落在哪个区间。
    static let overflowTable: [UInt8] = {
        var t = [UInt8](repeating: 0, count: 65536)
        var o = 0
        for z in 0..<65536 {
            if UInt32(z) >= rangeTotal[o + 1] { o += 1 }
            t[z] = UInt8(o)
        }
        return t
    }()
    static let kSumMinBoundary: [UInt32] = [0, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144,
        524288, 1048576, 2097152, 4194304, 8388608, 16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824,
        2147483648, 0, 0, 0, 0]

    static let bottom: UInt32 = (1 << 31) >> 8

    let stream: [UInt8]
    var pos: Int
    var low: UInt32 = 0
    var range: UInt32 = 0
    var buffer: UInt32 = 0
    /// 读过头或数据不合理。
    var failed = false

    init(stream: [UInt8], position: Int) {
        self.stream = stream
        pos = position
    }

    @inline(__always) mutating func byte() -> UInt32 {
        guard pos < stream.count else { failed = true; return 0 }
        defer { pos += 1 }
        return UInt32(stream[pos])
    }

    mutating func uint32() -> UInt32 { byte() << 24 | byte() << 16 | byte() << 8 | byte() }

    /// 每帧开头：跳过 1 个占位字节，载入初始状态。
    mutating func start() {
        _ = byte()
        buffer = byte()
        low = buffer >> 1
        range = 1 << 7
    }

    @inline(__always) mutating func normalize() {
        while range <= Self.bottom {
            buffer = (buffer &<< 8) | byte()
            low = (low &<< 8) | ((buffer >> 1) & 0xFF)
            range = range &<< 8
            if range == 0 { failed = true; return }
        }
    }

    @inline(__always) mutating func decodeFast(_ shift: Int) -> UInt32 {
        normalize()
        range >>= UInt32(shift)
        guard range != 0 else { failed = true; return 0 }
        return low / range
    }

    @inline(__always) mutating func decodeWithUpdate(_ shift: Int) -> UInt32 {
        let r = decodeFast(shift)
        guard range != 0 else { return 0 }
        low %= range
        return r
    }

    mutating func overflow(_ pivot: inout UInt32) -> UInt32 {
        var depth = 0
        while true {
            let total = decodeFast(16)
            guard !failed, total < 65536 else { failed = true; return 0 }
            var o = UInt32(Self.overflowTable[Int(total)])
            low = low &- range &* Self.rangeTotal[Int(o)]
            range = range &* Self.rangeWidth[Int(o)]
            if o == 63 {
                o = decodeWithUpdate(16) << 16
                o |= decodeWithUpdate(16)
                if o == 1, depth < 4 {
                    pivot = 32768
                    depth += 1
                    continue
                }
            }
            return o
        }
    }

    /// 解出一个残差值，并更新该声道的自适应参数。
    @inline(__always) mutating func value(_ s: inout State) -> Int64 {
        var pivot = max(s.kSum / 32, 1)
        let over = overflow(&pivot)
        var base: UInt32 = 0
        if pivot >= 1 << 16 {
            var bits: UInt32 = 0
            while (pivot >> bits) > 0 { bits += 1 }
            let shift = bits >= 16 ? bits - 16 : 0
            let split: UInt32 = 1 << shift
            let a = pivot / split + 1, b = split
            normalize()
            range /= a
            guard range != 0 else { failed = true; return 0 }
            let baseA = low / range
            low %= range
            normalize()
            range /= b
            guard range != 0 else { failed = true; return 0 }
            let baseB = low / range
            low %= range
            base = baseA &* split &+ baseB
        } else {
            normalize()
            range /= pivot
            guard range != 0 else { failed = true; return 0 }
            base = low / range
            low %= range
        }
        let v = Int64(base) + Int64(over) * Int64(pivot)
        s.kSum = s.kSum &+ (UInt32(truncatingIfNeeded: (v + 1) / 2) &- ((s.kSum &+ 16) >> 5))
        if s.kSum < Self.kSumMinBoundary[s.k] {
            s.k = max(0, s.k - 1)
        } else if s.k + 1 < 32, Self.kSumMinBoundary[s.k + 1] != 0, s.kSum >= Self.kSumMinBoundary[s.k + 1] {
            s.k += 1
        }
        return v & 1 != 0 ? (v >> 1) + 1 : -(v >> 1)
    }
}

// MARK: - 神经网络滤波器

/// 16 位存储的自适应滤波器（8/16/24 位音频），对应官方 CNNFilter<int, short>。
final class NNFilter16 {
    let order: Int
    let shift: Int32
    let round: Int32
    let interim: Bool
    static let window = 512
    let m: UnsafeMutablePointer<Int16>
    let input: UnsafeMutablePointer<Int16>
    let delta: UnsafeMutablePointer<Int16>
    var cur: Int
    var average: Int32 = 0

    init(order: Int, shift: Int, interim: Bool) {
        self.order = order
        self.shift = Int32(shift)
        round = 1 << (Int32(shift) - 1)
        self.interim = interim
        m = .allocate(capacity: order)
        m.initialize(repeating: 0, count: order)
        input = .allocate(capacity: order + Self.window)
        input.initialize(repeating: 0, count: order + Self.window)
        delta = .allocate(capacity: order + Self.window)
        delta.initialize(repeating: 0, count: order + Self.window)
        cur = order
    }

    deinit { m.deallocate(); input.deallocate(); delta.deallocate() }

    @inline(__always) func decompress(_ value: Int32) -> Int32 {
        let x = input + (cur - order), d = delta + (cur - order)
        var dot: Int32 = 0
        for i in 0..<order { dot = dot &+ Int32(x[i]) &* Int32(m[i]) }
        let output: Int32 = interim
            ? Int32(truncatingIfNeeded: Int64(value) + ((Int64(dot) + Int64(round)) >> Int64(shift)))
            : value &+ ((dot &+ round) >> shift)
        if value < 0 {
            for i in 0..<order { m[i] = m[i] &+ d[i] }
        } else if value > 0 {
            for i in 0..<order { m[i] = m[i] &- d[i] }
        }
        let a = Int32(truncatingIfNeeded: output.magnitude)
        let dc: Int32
        if a > average &* 3 { dc = ((output >> 25) & 64) - 32 }
        else if a > (average &* 4) / 3 { dc = ((output >> 26) & 32) - 16 }
        else if a > 0 { dc = ((output >> 27) & 16) - 8 }
        else { dc = 0 }
        delta[cur] = Int16(truncatingIfNeeded: dc)
        average = average &+ (a &- average) / 16
        delta[cur - 1] >>= 1
        delta[cur - 2] >>= 1
        delta[cur - 8] >>= 1
        input[cur] = Int16(truncatingIfNeeded: output) == output ? Int16(truncatingIfNeeded: output)
            : Int16(truncatingIfNeeded: (output >> 31) ^ 0x7FFF)
        cur += 1
        if cur == order + Self.window {
            (input).update(from: input + (cur - order), count: order)
            (delta).update(from: delta + (cur - order), count: order)
            cur = order
        }
        return output
    }
}

/// 32 位存储的滤波器（32 位音频），对应官方 CNNFilter<int64, int>。
final class NNFilter32 {
    let order: Int
    let shift: Int64
    let round: Int64
    static let window = 512
    let m: UnsafeMutablePointer<Int32>
    let input: UnsafeMutablePointer<Int32>
    let delta: UnsafeMutablePointer<Int32>
    var cur: Int
    var average: Int64 = 0

    init(order: Int, shift: Int) {
        self.order = order
        self.shift = Int64(shift)
        round = 1 << (Int64(shift) - 1)
        m = .allocate(capacity: order)
        m.initialize(repeating: 0, count: order)
        input = .allocate(capacity: order + Self.window)
        input.initialize(repeating: 0, count: order + Self.window)
        delta = .allocate(capacity: order + Self.window)
        delta.initialize(repeating: 0, count: order + Self.window)
        cur = order
    }

    deinit { m.deallocate(); input.deallocate(); delta.deallocate() }

    @inline(__always) func decompress(_ value: Int64) -> Int64 {
        let x = input + (cur - order), d = delta + (cur - order)
        var dot: Int64 = 0
        for i in 0..<order { dot = dot &+ Int64(x[i] &* m[i]) }
        let output = value &+ ((dot &+ round) >> shift)
        if value < 0 {
            for i in 0..<order { m[i] = m[i] &+ d[i] }
        } else if value > 0 {
            for i in 0..<order { m[i] = m[i] &- d[i] }
        }
        let a = Int64(truncatingIfNeeded: output.magnitude)
        let dc: Int64
        if a > average &* 3 { dc = ((output >> 25) & 64) - 32 }
        else if a > (average &* 4) / 3 { dc = ((output >> 26) & 32) - 16 }
        else if a > 0 { dc = ((output >> 27) & 16) - 8 }
        else { dc = 0 }
        delta[cur] = Int32(truncatingIfNeeded: dc)
        average = average &+ (a &- average) / 16
        delta[cur - 1] >>= 1
        delta[cur - 2] >>= 1
        delta[cur - 8] >>= 1
        let s16 = Int16(truncatingIfNeeded: output)
        input[cur] = Int64(s16) == output ? Int32(s16) : Int32(Int16(truncatingIfNeeded: (output >> 63) ^ 0x7FFF))
        cur += 1
        if cur == order + Self.window {
            input.update(from: input + (cur - order), count: order)
            delta.update(from: delta + (cur - order), count: order)
            cur = order
        }
        return output
    }
}

/// 各压缩级别使用的滤波器（阶数, 移位），按解码顺序（最后加上的先解）。
private func filterSpecs(_ level: Int) -> [(Int, Int)] {
    switch level {
    case 2000: [(16, 11)]
    case 3000: [(64, 11)]
    case 4000: [(32, 10), (256, 13)]
    case 5000: [(16, 11), (256, 13), (1024 + 256, 15)]
    default: []
    }
}

// MARK: - 预测器

/// 自适应预测器（8/16/24 位），对应官方 CPredictorDecompress3950toCurrent<int, short>；
/// `interim` 为 24 位文件的兼容算法（CPredictorDecompressInterim）。
struct Predictor32 {
    static let window = 256, history = 8
    var filters: [NNFilter16]
    let interim: Bool
    var predA = [Int32](repeating: 0, count: window + history)
    var predB = [Int32](repeating: 0, count: window + history)
    var adaptA = [Int32](repeating: 0, count: window + history)
    var adaptB = [Int32](repeating: 0, count: window + history)
    var ma: (Int32, Int32, Int32, Int32) = (360, 317, -109, 98)
    var mb: (Int32, Int32, Int32, Int32, Int32) = (0, 0, 0, 0, 0)
    var lastA: Int32 = 0
    var stage1A: Int32 = 0
    var stage1B: Int32 = 0
    var cur = history
    var index = 0

    init(level: Int, interim: Bool) {
        self.interim = interim
        filters = filterSpecs(level).map { NNFilter16(order: $0.0, shift: $0.1, interim: interim) }
    }

    @inline(__always) static func sign(_ v: Int32) -> Int32 { v != 0 ? ((v >> 30) & 2) - 1 : 0 }

    mutating func decompress(_ nA: Int64, _ nB: Int64) -> Int32 {
        if index == Self.window {
            for i in 0..<Self.history {
                predA[i] = predA[cur - Self.history + i]; predB[i] = predB[cur - Self.history + i]
                adaptA[i] = adaptA[cur - Self.history + i]; adaptB[i] = adaptB[cur - Self.history + i]
            }
            cur = Self.history
            index = 0
        }
        var a = Int32(truncatingIfNeeded: nA)
        let b = Int32(truncatingIfNeeded: nB)
        for f in filters { a = f.decompress(a) }
        let c = cur
        predA[c] = lastA
        predA[c - 1] = predA[c] &- predA[c - 1]
        predB[c] = b &- ((stage1B &* 31) >> 5)
        stage1B = b
        predB[c - 1] = predB[c] &- predB[c - 1]
        let current: Int32
        if interim {
            let pa = Int64(predA[c]) * Int64(ma.0) + Int64(predA[c - 1]) * Int64(ma.1) + Int64(predA[c - 2]) * Int64(ma.2) + Int64(predA[c - 3]) * Int64(ma.3)
            let pb = Int64(predB[c]) * Int64(mb.0) + Int64(predB[c - 1]) * Int64(mb.1) + Int64(predB[c - 2]) * Int64(mb.2)
                + Int64(predB[c - 3]) * Int64(mb.3) + Int64(predB[c - 4]) * Int64(mb.4)
            current = a &+ Int32(truncatingIfNeeded: (pa + (pb >> 1)) >> 10)
        } else {
            let pa = predA[c] &* ma.0 &+ predA[c - 1] &* ma.1 &+ predA[c - 2] &* ma.2 &+ predA[c - 3] &* ma.3
            let pb = predB[c] &* mb.0 &+ predB[c - 1] &* mb.1 &+ predB[c - 2] &* mb.2 &+ predB[c - 3] &* mb.3 &+ predB[c - 4] &* mb.4
            current = a &+ ((pa &+ (pb >> 1)) >> 10)
        }
        adaptA[c] = Self.sign(predA[c]); adaptA[c - 1] = Self.sign(predA[c - 1])
        adaptB[c] = Self.sign(predB[c]); adaptB[c - 1] = Self.sign(predB[c - 1])
        let dir: Int32 = (a < 0 ? 1 : 0) - (a > 0 ? 1 : 0)
        ma.0 = ma.0 &+ adaptA[c] &* dir; ma.1 = ma.1 &+ adaptA[c - 1] &* dir
        ma.2 = ma.2 &+ adaptA[c - 2] &* dir; ma.3 = ma.3 &+ adaptA[c - 3] &* dir
        mb.0 = mb.0 &+ adaptB[c] &* dir; mb.1 = mb.1 &+ adaptB[c - 1] &* dir
        mb.2 = mb.2 &+ adaptB[c - 2] &* dir; mb.3 = mb.3 &+ adaptB[c - 3] &* dir
        mb.4 = mb.4 &+ adaptB[c - 4] &* dir
        stage1A = current &+ ((stage1A &* 31) >> 5)
        lastA = current
        cur += 1
        index += 1
        return stage1A
    }
}

/// 32 位音频的预测器，对应官方 CPredictorDecompress3950toCurrent<int64, int>。
struct Predictor64 {
    static let window = 256, history = 8
    var filters: [NNFilter32]
    var predA = [Int64](repeating: 0, count: window + history)
    var predB = [Int64](repeating: 0, count: window + history)
    var adaptA = [Int64](repeating: 0, count: window + history)
    var adaptB = [Int64](repeating: 0, count: window + history)
    var ma: (Int64, Int64, Int64, Int64) = (360, 317, -109, 98)
    var mb: (Int64, Int64, Int64, Int64, Int64) = (0, 0, 0, 0, 0)
    var lastA: Int64 = 0
    var stage1A: Int32 = 0
    var stage1B: Int32 = 0
    var cur = history
    var index = 0

    init(level: Int) {
        filters = filterSpecs(level).map { NNFilter32(order: $0.0, shift: $0.1) }
    }

    @inline(__always) static func sign(_ v: Int64) -> Int64 { v != 0 ? ((v >> 30) & 2) - 1 : 0 }

    mutating func decompress(_ nA: Int64, _ nB: Int64) -> Int32 {
        if index == Self.window {
            for i in 0..<Self.history {
                predA[i] = predA[cur - Self.history + i]; predB[i] = predB[cur - Self.history + i]
                adaptA[i] = adaptA[cur - Self.history + i]; adaptB[i] = adaptB[cur - Self.history + i]
            }
            cur = Self.history
            index = 0
        }
        var a = nA
        let b = Int32(truncatingIfNeeded: nB)
        for f in filters { a = f.decompress(a) }
        let c = cur
        predA[c] = lastA
        predA[c - 1] = predA[c] &- predA[c - 1]
        predB[c] = Int64(b) &- ((Int64(stage1B) &* 31) >> 5)
        stage1B = b
        predB[c - 1] = predB[c] &- predB[c - 1]
        let pa = predA[c] &* ma.0 &+ predA[c - 1] &* ma.1 &+ predA[c - 2] &* ma.2 &+ predA[c - 3] &* ma.3
        let pb = predB[c] &* mb.0 &+ predB[c - 1] &* mb.1 &+ predB[c - 2] &* mb.2 &+ predB[c - 3] &* mb.3 &+ predB[c - 4] &* mb.4
        let current = a &+ ((pa &+ (pb >> 1)) >> 10)
        adaptA[c] = Self.sign(predA[c]); adaptA[c - 1] = Self.sign(predA[c - 1])
        adaptB[c] = Self.sign(predB[c]); adaptB[c - 1] = Self.sign(predB[c - 1])
        let dir: Int64 = (a < 0 ? 1 : 0) - (a > 0 ? 1 : 0)
        ma.0 = ma.0 &+ adaptA[c] &* dir; ma.1 = ma.1 &+ adaptA[c - 1] &* dir
        ma.2 = ma.2 &+ adaptA[c - 2] &* dir; ma.3 = ma.3 &+ adaptA[c - 3] &* dir
        mb.0 = mb.0 &+ adaptB[c] &* dir; mb.1 = mb.1 &+ adaptB[c - 1] &* dir
        mb.2 = mb.2 &+ adaptB[c - 2] &* dir; mb.3 = mb.3 &+ adaptB[c - 3] &* dir
        mb.4 = mb.4 &+ adaptB[c - 4] &* dir
        stage1A = Int32(truncatingIfNeeded: current &+ ((Int64(stage1A) &* 31) >> 5))
        lastA = current
        cur += 1
        index += 1
        return stage1A
    }
}

// MARK: - CRC-32

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var c = crc
        bytes.withUnsafeBufferPointer { p in
            table.withUnsafeBufferPointer { t in
                for b in p { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            }
        }
        return c
    }
}

extension Data {
    func le16(_ i: Int) -> UInt16 { UInt16(self[startIndex + i]) | UInt16(self[startIndex + i + 1]) << 8 }
}
