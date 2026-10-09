import Foundation

/// DST（Direct Stream Transfer，MPEG-4 第 3 部分第 10 子部分）无损压缩 DSD 的解码器。
/// SACD 与压缩的 DFF 文件使用。每帧 1/75 秒；解码结果为每声道 DSD 字节（早的比特在高位）。
///
/// 解码过程：每声道用一组线性预测滤波器（最多 128 个系数）根据前面的比特预测下一个比特，
/// 预测值的大小经概率表换算成概率，再用二进制算术解码器解出“预测是否正确”，得到实际比特。
/// 本实现按公开资料中的算法结构自行编写。
public struct DSTDecoder: Sendable {
    public enum DSTError: Error, Equatable {
        case invalid(String)
        case unsupported(String)
    }

    static let maxChannels = 6
    static let maxElements = 2 * maxChannels

    public let channels: Int
    /// 每帧每声道的比特数（DSD64 为 37632）。
    public let samplesPerFrame: Int

    /// 每帧每声道的字节数。
    public var bytesPerFrame: Int { samplesPerFrame / 8 }

    public init(channels: Int, dsdRate: Int) {
        self.channels = channels
        samplesPerFrame = dsdRate / 75
    }

    // MARK: 系数表

    struct Table {
        var elements = 1
        var length = [Int](repeating: 0, count: DSTDecoder.maxElements)
        var coeff = [[Int]](repeating: [Int](repeating: 0, count: 128), count: DSTDecoder.maxElements)
    }

    /// 系数表的预测编码系数（第 0、1、2 种方法）。
    static let filterPrediction: [[Int]] = [[-8], [-16, 8], [-9, -5, 6]]
    static let probabilityPrediction: [[Int]] = [[-8], [-16, 8], [-24, 24, -8]]

    /// 声道到滤波器（或概率表）的对应关系。
    static func readMap(_ r: inout BitReader, channels: Int) throws -> (elements: Int, map: [Int]) {
        var map = [Int](repeating: 0, count: channels)
        var elements = 1
        if r.bit() == 0 {
            for ch in 1..<max(channels, 1) {
                let bits = Int.bitWidth - (elements).leadingZeroBitCount     // ⌊log2(elements)⌋ + 1
                let v = r.bits(bits)
                if v == elements {
                    elements += 1
                    guard elements < maxElements else { throw DSTError.invalid("元素过多") }
                } else if v > elements {
                    throw DSTError.invalid("对应关系错误")
                }
                map[ch] = v
            }
        }
        return (elements, map)
    }

    /// 读取滤波器系数表或概率表。`signed` 为有符号系数（滤波器）；无符号的值域为 offset ..< offset + 2^coeffBits。
    static func readTable(_ r: inout BitReader, _ t: inout Table, prediction: [[Int]], lengthBits: Int, coeffBits: Int,
                          signed: Bool, offset: Int) throws {
        for i in 0..<t.elements {
            t.length[i] = r.bits(lengthBits) + 1
            func plain() -> Int { signed ? r.signedBits(coeffBits) : r.bits(coeffBits) + offset }
            if r.bit() == 0 {
                for j in 0..<t.length[i] { t.coeff[i][j] = plain() }
            } else {
                let method = r.bits(2)
                guard method < 3 else { throw DSTError.invalid("系数编码方法错误") }
                var j = 0
                while j <= method && j < t.length[i] { t.coeff[i][j] = plain(); j += 1 }
                let k = r.bits(3)
                while j < t.length[i] {
                    var x = 0
                    for m in 0...method { x += prediction[method][m] * t.coeff[i][j - m - 1] }
                    var c = r.signedRice(k)
                    if x >= 0 { c -= (x + 4) / 8 } else { c += (-x + 3) / 8 }
                    if !signed, c < offset || c >= offset + (1 << coeffBits) { throw DSTError.invalid("概率值越界") }
                    t.coeff[i][j] = c
                    j += 1
                }
            }
        }
    }

    // MARK: 解码一帧

    /// 解码一帧。返回各声道的 DSD 字节（每声道 `bytesPerFrame` 个）。
    public func decode(_ frame: Data) throws -> [[UInt8]] {
        guard frame.count > 1 else { throw DSTError.invalid("帧太短") }
        var r = BitReader(frame)
        let n = samplesPerFrame
        var out = [[UInt8]](repeating: [UInt8](repeating: 0, count: n / 8), count: channels)

        // 未压缩帧：后面直接是按声道交错的 DSD 字节
        if r.bit() == 0 {
            _ = r.bit()
            guard r.bits(6) == 0 else { throw DSTError.invalid("未压缩帧格式错误") }
            frame.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<(n / 8) {
                    for ch in 0..<channels {
                        let idx = 1 + i * channels + ch
                        out[ch][i] = idx < p.count ? p[idx] : 0
                    }
                }
            }
            return out
        }

        // 分段：只支持“全部声道一段”（实际文件均如此）
        guard r.bit() == 1 else { throw DSTError.unsupported("分段方式不同") }
        guard r.bit() == 1 else { throw DSTError.unsupported("各声道分段不同") }
        guard r.bit() == 1 else { throw DSTError.unsupported("多段") }

        // 声道 → 滤波器、概率表
        let sameMap = r.bit() == 1
        var fsets = Table(), probs = Table()
        let f = try Self.readMap(&r, channels: channels)
        fsets.elements = f.elements
        var pmap = f.map
        if sameMap {
            probs.elements = f.elements
        } else {
            let p = try Self.readMap(&r, channels: channels)
            probs.elements = p.elements
            pmap = p.map
        }
        let fmap = f.map

        // 各声道开头是否用 1/2 概率
        let halfProb = (0..<channels).map { _ in r.bit() == 1 }

        try Self.readTable(&r, &fsets, prediction: Self.filterPrediction, lengthBits: 7, coeffBits: 9, signed: true, offset: 0)
        try Self.readTable(&r, &probs, prediction: Self.probabilityPrediction, lengthBits: 6, coeffBits: 7, signed: false, offset: 1)

        guard r.bit() == 0 else { throw DSTError.invalid("算术编码数据起始位错误") }

        // 滤波器查表：每 8 个系数一组，按 8 个历史比特的组合预先求和
        var filters = [Int16](repeating: 0, count: fsets.elements * 16 * 256)
        for e in 0..<fsets.elements {
            for g in 0..<16 {
                for v in 0..<256 {
                    var s = 0
                    for l in 0..<8 {
                        let idx = g * 8 + l
                        let c = idx < fsets.length[e] ? fsets.coeff[e][idx] : 0
                        s += ((v >> l) & 1 == 1 ? 1 : -1) * c
                    }
                    filters[(e * 16 + g) * 256 + v] = Int16(truncatingIfNeeded: s)
                }
            }
        }

        var ac = ArithmeticDecoder(&r)
        _ = ac.decode(&r, probability: Self.xBitProbability(fsets.coeff[0][0]))

        // 内层循环每秒要跑几百万次：所有表都展平成连续内存，用指针访问
        let bytesPerChannel = n / 8
        var flatOut = [UInt8](repeating: 0, count: bytesPerChannel * channels)
        var probFlat = [Int](repeating: 0, count: probs.elements * 128)
        for e in 0..<probs.elements { for k in 0..<128 { probFlat[e * 128 + k] = probs.coeff[e][k] } }
        // 每声道：滤波器表起点、概率表起点、概率表最大下标、滤波器长度、是否开头用 1/2 概率
        let fBase = fmap.map { $0 * 16 * 256 }
        let pBase = pmap.map { $0 * 128 }
        let pMax = pmap.map { probs.length[$0] - 1 }
        let fLen = fmap.map { fsets.length[$0] }
        // 历史比特：每声道 128 位（两个 64 位），最新的比特在最低位；每帧开始为 0xAA…
        var lo = [UInt64](repeating: 0xAAAA_AAAA_AAAA_AAAA, count: channels)
        var hi = lo

        filters.withUnsafeBufferPointer { fp in
        probFlat.withUnsafeBufferPointer { pp in
        flatOut.withUnsafeMutableBufferPointer { op in
        lo.withUnsafeMutableBufferPointer { lop in
        hi.withUnsafeMutableBufferPointer { hip in
            for i in 0..<n {
                let byte = i >> 3, mask = UInt8(0x80 >> (i & 7))
                for ch in 0..<channels {
                    let base = fBase[ch]
                    let l = lop[ch], h = hip[ch]
                    var sum: Int = 0
                    var g = 0
                    while g < 8 {
                        sum &+= Int(fp[base &+ (g << 8) &+ Int(truncatingIfNeeded: (l >> UInt64(g << 3)) & 0xFF)])
                        sum &+= Int(fp[base &+ ((g &+ 8) << 8) &+ Int(truncatingIfNeeded: (h >> UInt64(g << 3)) & 0xFF)])
                        g &+= 1
                    }
                    let predict = Int16(truncatingIfNeeded: sum)
                    let prob: Int
                    if !halfProb[ch] || i >= fLen[ch] {
                        let index = Int(predict.magnitude) >> 3
                        prob = pp[pBase[ch] &+ min(index, pMax[ch])]
                    } else {
                        prob = 128
                    }
                    let residual = ac.decode(&r, probability: prob)
                    let bit = (predict < 0 ? 1 : 0) ^ residual
                    if bit == 1 { op[ch &* bytesPerChannel &+ byte] |= mask }
                    hip[ch] = (h << 1) | (l >> 63)
                    lop[ch] = (l << 1) | UInt64(bit)
                }
            }
        }}}}}
        for ch in 0..<channels { out[ch] = Array(flatOut[ch * bytesPerChannel ..< (ch + 1) * bytesPerChannel]) }
        return out
    }

    /// 帧开头一个附加比特的概率（由第一个滤波器的第一个系数得出）。
    static func xBitProbability(_ c: Int) -> Int {
        Int(reverseBits(UInt8(c & 127)) >> 1) + 1
    }

    static func reverseBits(_ v: UInt8) -> UInt8 {
        var r: UInt8 = 0, x = v
        for _ in 0..<8 { r = (r << 1) | (x & 1); x >>= 1 }
        return r
    }
}

/// 按位读取（高位在前）。读过末尾返回 0。用 64 位缓存一次取多位，比逐位读快得多。
struct BitReader {
    let data: [UInt8]
    /// 下一个要装入缓存的字节位置。
    private var next = 0
    /// 缓存的比特（左对齐，最高位是下一个要读的比特）与其中的有效位数。
    private var cache: UInt64 = 0
    private var count = 0
    /// 已读位数（防坏数据死循环用）。
    private(set) var pos = 0

    init(_ d: Data) { data = [UInt8](d) }

    @inline(__always) private mutating func refill() {
        while count <= 56 {
            let b: UInt64 = next < data.count ? UInt64(data[next]) : 0
            next += 1
            cache |= b << UInt64(56 - count)
            count += 8
        }
    }

    @inline(__always) mutating func bits(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        if count < n { refill() }
        let v = Int(cache >> UInt64(64 - n))
        cache <<= UInt64(n)
        count -= n
        pos += n
        return v
    }

    @inline(__always) mutating func bit() -> Int { bits(1) }

    mutating func signedBits(_ n: Int) -> Int {
        let v = bits(n)
        return v >= 1 << (n - 1) ? v - (1 << n) : v
    }

    /// 莱斯码：一串 0 以 1 结束（个数为高位），再跟 k 位低位；非零时再跟一位符号（1 为负）。
    mutating func signedRice(_ k: Int) -> Int {
        var q = 0
        while bit() == 0 {
            q += 1
            if pos > data.count * 8 + 64 { break }     // 防止坏数据死循环
        }
        let v = (q << k) | bits(k)
        return v != 0 && bit() == 1 ? -v : v
    }
}

/// DST 用的二进制算术解码器（12 位精度）。
struct ArithmeticDecoder {
    var a = 4095
    var c: Int

    init(_ r: inout BitReader) { c = r.bits(12) }

    /// 解出一个比特：返回 1 的概率约为 prob/256（prob 取 1…128）。
    mutating func decode(_ r: inout BitReader, probability p: Int) -> Int {
        let k = (a >> 8) | ((a >> 7) & 1)
        let q = k * p
        let aq = a - q
        let e: Int
        if c < aq {
            e = 1
            a = aq
        } else {
            e = 0
            a = q
            c -= aq
        }
        if a < 2048 {
            let shift = 11 - (Int.bitWidth - 1 - a.leadingZeroBitCount)
            a <<= shift
            c = (c << shift) | r.bits(shift)
        }
        return e
    }
}
