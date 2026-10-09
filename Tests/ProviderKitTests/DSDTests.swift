import Foundation
import Testing
@testable import ProviderKit

@Suite struct DSDTests {
    /// 用二阶 Σ-Δ 调制生成 DSD64 的 1 kHz 正弦（幅度 0.5），写成标准 DSF 文件。
    static func writeDSF(_ url: URL, seconds: Double = 0.5, amplitude: Double = 0.5) throws {
        let rate = 2_822_400, channels = 2, block = 4096
        let samples = Int(Double(rate) * seconds) / (block * 8) * (block * 8)   // 凑整为整块
        var bits = [UInt8](repeating: 0, count: samples / 8)
        var i1 = 0.0, i2 = 0.0, y = 0.0
        for n in 0..<samples {
            let x = amplitude * sin(2 * .pi * 1000 * Double(n) / Double(rate))
            i1 += x - y; i2 += i1 - y
            let bit = i2 >= 0
            y = bit ? 1 : -1
            if bit { bits[n / 8] |= 1 << (n % 8) }                             // DSF：最低位在前
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataSize = UInt64(bits.count * channels)
        d.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(28 + 52 + 12 + dataSize); u64(0)
        d.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0); u32(2); u32(UInt32(channels))
        u32(UInt32(rate)); u32(1); u64(UInt64(samples)); u32(UInt32(block)); u32(0)
        d.append(contentsOf: Array("data".utf8)); u64(12 + dataSize)
        for b in stride(from: 0, to: bits.count, by: block) {
            for _ in 0..<channels { d.append(contentsOf: bits[b..<b + block]) }
        }
        try d.write(to: url)
    }

    @Test func readsDSFAndConvertsToPCM() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "t-\(UUID()).dsf")
        try Self.writeDSF(url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try DSDFile(url: url)
        #expect(file.sampleRate == 2_822_400)
        #expect(file.channels == 2)
        #expect(file.rateName == "DSD64")
        #expect(abs(file.duration - 1_409_024.0 / 2_822_400) < 0.001)   // 0.5 秒凑整为整块

        var conv = DSDToPCM(channels: 2, dsdRate: file.sampleRate)
        let bytes = try file.read(fromByte: 0, count: Int(file.sampleCount / 8))
        let pcm = conv.convert(bytes)
        // 176.4 kHz；跳过开头滤波器建立的部分，看稳定后的峰值与过零次数
        let steady = Array(pcm[0][4000..<pcm[0].count - 100])
        let peak = steady.map(abs).max()!
        #expect(abs(peak - 0.5) < 0.05)
        var crossings = 0
        for i in 1..<steady.count where (steady[i - 1] < 0) != (steady[i] < 0) { crossings += 1 }
        let seconds = Double(steady.count) / 176_400
        #expect(abs(Double(crossings) / 2 / seconds - 1000) < 20)          // 约 1000 Hz
        #expect(pcm[0] == pcm[1])                                         // 两声道相同
    }

    @Test func dopPackingIsExact() {
        var packer = DoPPacker()
        let left: [UInt8] = [0x12, 0x34, 0xAB, 0xCD, 0x00, 0xFF]
        let right: [UInt8] = [0xFF, 0x00, 0x69, 0x96, 0x80, 0x01]
        let out = packer.pack([left, right])
        #expect(out[0].count == 3)
        let l = out[0].map(DoPPacker.int24), r = out[1].map(DoPPacker.int24)
        #expect(l == [0x05_1234, 0xFA_ABCD, 0x05_00FF])
        #expect(r == [0x05_FF00, 0xFA_6996, 0x05_8001])
        // 下一次调用接着交替标记
        let next = packer.pack([[0x01, 0x02], [0x03, 0x04]])
        #expect(DoPPacker.int24(next[0][0]) == 0xFA_0102)
    }
}

@Suite struct DSTDecoderTests {
    /// 未压缩帧：第一位为 0，后面 7 位填充，再跟按声道交错的 DSD 字节，应原样还原。
    @Test func uncompressedFrame() throws {
        let decoder = DSTDecoder(channels: 2, dsdRate: 2_822_400)
        var frame = Data([0x00])
        for i in 0..<decoder.bytesPerFrame { frame.append(UInt8(i & 0xFF)); frame.append(UInt8(255 - (i & 0xFF))) }
        let out = try decoder.decode(frame)
        #expect(out[0].count == 4704)
        #expect(out[0][0..<3] == [0, 1, 2])
        #expect(out[1][0..<3] == [255, 254, 253])
    }

    /// 坏数据不能崩溃，只能报错或得到结果。
    @Test func garbageDoesNotCrash() {
        let decoder = DSTDecoder(channels: 2, dsdRate: 2_822_400)
        for seed in 0..<20 {
            var g = SystemRandomNumberGenerator()
            _ = seed
            let junk = Data((0..<200).map { _ in UInt8.random(in: 0...255, using: &g) })
            _ = try? decoder.decode(junk)
        }
    }

    @Test func xBitProbabilityRange() {
        for c in -256..<256 { #expect((1...128).contains(DSTDecoder.xBitProbability(c))) }
    }
}

@Suite struct DSDStreamTests {
    /// 服务器组成的虚拟 DSF，经客户端的网络读取器读出，与原文件逐字节相同（含跨块、跨段、文件末尾）。
    @Test func virtualDSFRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "am-vdsf-\(UUID()).dsf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DSDTests.writeDSF(url, seconds: 1.3)
        let file = try DSDFile(url: url)
        let virtual = VirtualDSF(source: file)
        let remote = try RemoteDSFSource { offset, count in try virtual.bytes(from: offset, count: count) }
        #expect(remote.sampleRate == file.sampleRate && remote.channels == file.channels && remote.sampleCount == file.sampleCount)
        let total = Int(file.sampleCount / 8)
        for (start, count) in [(0, 8192), (4000, 300), (4096 * 63, 9000), (4096 * 64 - 5, 10), (total - 100, 500)] {
            #expect(try remote.read(fromByte: Int64(start), count: count) == file.read(fromByte: Int64(start), count: count))
        }
        // 虚拟文件本身也是合法的 DSF
        let copy = FileManager.default.temporaryDirectory.appending(path: "am-vdsf-copy-\(UUID()).dsf")
        defer { try? FileManager.default.removeItem(at: copy) }
        try virtual.bytes(from: 0, count: Int(virtual.totalLength)).write(to: copy)
        let reread = try DSDFile(url: copy)
        #expect(try reread.read(fromByte: 0, count: total) == file.read(fromByte: 0, count: total))
    }
}
