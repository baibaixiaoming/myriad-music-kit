import Foundation

/// DoP（DSD over PCM，标准 1.1）打包：每 16 个 DSD 比特装进一个 24 位 PCM 采样，
/// 最高字节是标记（0x05 与 0xFA 逐帧交替），下面两个字节是 DSD 数据（早的比特在高位）。
/// 输出采样率 = DSD 采样率 ÷ 16（DSD64 → 176.4kHz）。PCM 数值以 32 位浮点表示，24 位整数可无损往返。
public struct DoPPacker: Sendable {
    private var markerHigh = false

    public init() {}

    /// `bytes` 为各声道的 DSD 字节（每声道字节数相同，必须为偶数）；返回各声道的浮点采样。
    public mutating func pack(_ bytes: [[UInt8]]) -> [[Float]] {
        let frames = (bytes.first?.count ?? 0) / 2
        var out = bytes.map { _ in [Float](repeating: 0, count: frames) }
        for f in 0..<frames {
            let marker: Int32 = markerHigh ? 0xFA : 0x05
            markerHigh.toggle()
            for c in 0..<bytes.count {
                var v = marker << 16 | Int32(bytes[c][2 * f]) << 8 | Int32(bytes[c][2 * f + 1])
                if v & 0x80_0000 != 0 { v -= 0x100_0000 }          // 24 位有符号
                out[c][f] = Float(v) / 8_388_608
            }
        }
        return out
    }

    /// 从浮点采样还原 24 位整数（测试与校验用）。
    public static func int24(_ x: Float) -> Int32 { Int32((x * 8_388_608).rounded()) & 0xFF_FFFF }
}

/// DSD 转 PCM：每 16 个比特（2 个字节）出一个采样，即降到 DSD 采样率 ÷ 16（DSD64 → 176.4kHz）。
/// 低通滤波用 512 抽头（64 字节）布莱克曼窗 sinc，截止约 40kHz；按字节查表计算，速度快。
public struct DSDToPCM: Sendable {
    static let tapBytes = 64
    /// 查表（展平）：第 k 个历史字节取值 v 时对输出的贡献在 table[k * 256 + v]。
    private let table: [Float]
    /// 每声道的历史字节，存两份（长度 2n），任何位置开始的 n 个字节都连续，省去取模。
    private var history: [[UInt8]]
    private var pos = 0

    public init(channels: Int, dsdRate: Int) {
        let n = Self.tapBytes * 8
        let fc = 40_000.0 / Double(dsdRate)                     // 截止频率（相对采样率）
        var taps = (0..<n).map { i -> Double in
            let m = Double(i) - Double(n - 1) / 2
            let sinc = m == 0 ? 2 * fc : sin(2 * .pi * fc * m) / (.pi * m)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return sinc * w
        }
        let sum = taps.reduce(0, +)
        taps = taps.map { $0 / sum }
        var t = [Float](repeating: 0, count: Self.tapBytes * 256)
        for k in 0..<Self.tapBytes {
            for v in 0..<256 {
                var s = 0.0
                for b in 0..<8 { s += taps[k * 8 + b] * ((v >> (7 - b)) & 1 == 1 ? 1 : -1) }
                t[k * 256 + v] = Float(s)
            }
        }
        table = t
        // 开头用“静音”字节（0x69 = 01101001，比特平衡）填充，避免起始冲击
        history = Array(repeating: Array(repeating: 0x69, count: Self.tapBytes * 2), count: channels)
    }

    public mutating func convert(_ bytes: [[UInt8]]) -> [[Float]] {
        let frames = (bytes.first?.count ?? 0) / 2
        let n = Self.tapBytes
        var out: [[Float]] = []
        table.withUnsafeBufferPointer { tbl in
            for c in 0..<bytes.count {
                var result = [Float](repeating: 0, count: frames)
                var p = pos
                history[c].withUnsafeMutableBufferPointer { h in
                    bytes[c].withUnsafeBufferPointer { src in
                        result.withUnsafeMutableBufferPointer { dst in
                            for f in 0..<frames {
                                let b0 = src[2 * f], b1 = src[2 * f + 1]
                                h[p] = b0; h[p + n] = b0
                                h[(p + 1) % n] = b1; h[(p + 1) % n + n] = b1
                                p = (p + 2) % n
                                // 窗口：h[p ..< p+n]，最旧的字节在前
                                var s: Float = 0
                                var k = 0
                                while k < n {
                                    s += tbl[k &* 256 &+ Int(h[p &+ k])]
                                    k &+= 1
                                }
                                dst[f] = s
                            }
                        }
                    }
                }
                if c == bytes.count - 1 { pos = p }
                out.append(result)
            }
        }
        return out
    }
}
