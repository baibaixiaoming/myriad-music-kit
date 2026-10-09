import AVFoundation
import Foundation
import Testing
import ProviderKit
@testable import LocalMusic

@Suite struct LocalMusicTests {
    /// 生成 1 秒的正弦波音频文件。
    func writeTone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for i in 0..<44100 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
        try file.write(from: buffer)
    }

    @Test func scanSearchLyricsAndStream() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-local-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐/专辑", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try writeTone(music.appending(path: "测试歌曲.caf"))
        try "[00:00.50]第一句\n[00:01.00]第二句".write(to: music.appending(path: "测试歌曲.lrc"), atomically: true, encoding: .utf8)
        try "不是音频".write(to: music.appending(path: "说明.txt"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = LocalMusicLibrary(paths: AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory)))
        try await library.addFolder(root.appending(path: "音乐", directoryHint: .isDirectory))
        #expect(try await library.rescan() == 1)

        let provider = LocalMusicProvider(library: library)
        let ctx = RequestContext(platform: .local, account: nil)
        let page = try await provider.search("测试", kind: .track, cursor: nil, context: ctx)
        guard case .track(let t)? = page.items.first else { Issue.record("没有搜到"); return }
        #expect(t.metadata.title == "测试歌曲")
        #expect(t.metadata.duration.map { $0 >= .milliseconds(900) && $0 <= .milliseconds(1100) } == true)

        let lyrics = try await provider.lyrics(for: LyricsQuery(unifiedTrack: UnifiedTrackID(), metadata: t.metadata, platformRef: t.ref), context: ctx)
        #expect(lyrics.status == .available)
        #expect(lyrics.tracks.first?.lines.map(\.text) == ["第一句", "第二句"])

        let stream = try await provider.resolveStream(t.ref, preferredLevel: nil, context: ctx)
        #expect(stream.url.isFileURL)
        #expect(stream.previewRange == nil)

        // 重新加载索引（模拟重启）后仍在
        let reloaded = LocalMusicLibrary(paths: AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory)))
        #expect(await reloaded.trackCount == 1)
    }

    /// 按实际采样率、位深归档：16bit/44.1kHz 为“无损”，24bit/96kHz 为“高解析 96”。
    @Test func streamCarriesQualityTierFromActualFormat() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-tier-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func wav(_ name: String, rate: Double, bits: Int) throws {
            let file = try AVAudioFile(forWriting: music.appending(path: name), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 4))!
            buffer.frameLength = buffer.frameCapacity
            try file.write(from: buffer)
        }
        try wav("cd.wav", rate: 44100, bits: 16)
        try wav("hires.wav", rate: 96000, bits: 24)
        let library = LocalMusicLibrary(paths: AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory)))
        try await library.addFolder(music)
        #expect(try await library.rescan() == 2)
        let provider = LocalMusicProvider(library: library)
        let ctx = RequestContext(platform: .local, account: nil)
        var tiers: [String: QualityTier] = [:]
        for name in ["cd", "hires"] {
            let page = try await provider.search(name, kind: .track, cursor: nil, context: ctx)
            guard case .track(let t)? = page.items.first else { Issue.record("没有搜到 \(name)"); continue }
            tiers[name] = try await provider.resolveStream(t.ref, preferredLevel: nil, context: ctx).quality.tier
        }
        #expect(tiers["cd"] == .lossless)
        #expect(tiers["hires"] == .hiRes96)
        // 服务器音乐库带上用途，客户端据此单独显示
        #expect(LocalMusicProvider(library: library, platform: .serverLibrary, role: .musicLibrary).descriptor.role == .musicLibrary)
        #expect(provider.descriptor.role == nil)
    }
}
