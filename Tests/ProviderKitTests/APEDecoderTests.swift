import AVFoundation
import Foundation
import Testing
@testable import ProviderKit

/// APE 解码与官方解码器逐字节比对。
/// 需要环境变量 AM_APE_DIR：目录里每个 x.ape 旁边放官方工具解出的 x.ref.wav。
@Suite struct APEDecoderTests {
    static let dir = ProcessInfo.processInfo.environment["AM_APE_DIR"]

    /// WAV 文件中 data 块的内容。
    static func wavData(_ url: URL) throws -> [UInt8] {
        let d = [UInt8](try Data(contentsOf: url))
        var i = 12
        while i + 8 <= d.count {
            let id = String(decoding: d[i..<i + 4], as: UTF8.self)
            let len = Int(UInt32(d[i + 4]) | UInt32(d[i + 5]) << 8 | UInt32(d[i + 6]) << 16 | UInt32(d[i + 7]) << 24)
            if id == "data" { return Array(d[i + 8 ..< min(d.count, i + 8 + len)]) }
            i += 8 + len + (len & 1)
        }
        return []
    }

    @Test(.enabled(if: dir != nil)) func matchesReference() throws {
        let folder = URL(fileURLWithPath: Self.dir!)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".ape") }.sorted()
        #expect(!files.isEmpty)
        for name in files {
            let ape = try APEFile(url: folder.appending(path: name))
            let reference = try Self.wavData(folder.appending(path: name.replacingOccurrences(of: ".ape", with: ".ref.wav")))
            let start = Date()
            let pcm = try ape.read(fromBlock: 0, count: Int(ape.totalBlocks))
            let seconds = Date().timeIntervalSince(start)
            let firstDiff = zip(pcm, reference).enumerated().first { $0.element.0 != $0.element.1 }?.offset
            print("\(name)：\(ape.bitsPerSample) 位 \(ape.channels) 声道 级别 \(ape.compressionLevel)，"
                  + "长度 \(pcm.count)/\(reference.count)，首个差异 \(firstDiff.map(String.init) ?? "无")，"
                  + String(format: "%.1f 倍实时", ape.duration / seconds))
            #expect(pcm == reference, "\(name)")
        }
    }

    /// 跳到任意位置读出的内容与顺序读取一致。
    @Test(.enabled(if: dir != nil)) func randomAccess() throws {
        let folder = URL(fileURLWithPath: Self.dir!)
        let ape = try APEFile(url: folder.appending(path: "s16_c3000.ape"))
        let reference = try Self.wavData(folder.appending(path: "s16_c3000.ref.wav"))
        for block in [Int64(0), 73_727, 73_728, 1_000_000, ape.totalBlocks - 10] {
            let pcm = try ape.read(fromBlock: block, count: 5000)
            let start = Int(block) * ape.blockAlign
            #expect(pcm == Array(reference[start ..< min(reference.count, start + 5000 * ape.blockAlign)]))
        }
    }

    /// 经虚拟 WAV 交给系统读取（与播放时相同的路径），读出的 PCM 与官方解码一致。
    @Test(.enabled(if: dir != nil)) func playsThroughSystemReader() async throws {
        let folder = URL(fileURLWithPath: Self.dir!)
        for name in ["s16_c2000.ape", "s24_c4000.ape", "s24_6ch_c3000.ape", "u8m_c2000.ape"] {
            let path = folder.appending(path: name).path(percentEncoded: false)
            let ape = try APEFile(url: URL(fileURLWithPath: path))
            let (asset, loader) = try #require(SliceAssetLoader.asset(for: SliceAssetLoader.apeURL(path: path, file: ape)))
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            var pcm = [UInt8]()
            while let buffer = output.copyNextSampleBuffer() {
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                var length = 0, pointer: UnsafeMutablePointer<CChar>?
                CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
                if let pointer, CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
                    pcm += UnsafeRawBufferPointer(start: pointer, count: length)
                } else {
                    var copy = [UInt8](repeating: 0, count: length)
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &copy)
                    pcm += copy
                }
            }
            let reference = try Self.wavData(folder.appending(path: name.replacingOccurrences(of: ".ape", with: ".ref.wav")))
            print("\(name)：系统读出 \(pcm.count)/\(reference.count) 字节，状态 \(reader.status.rawValue)")
            #expect(pcm == reference, "\(name)")
            _ = loader
        }
    }
}
