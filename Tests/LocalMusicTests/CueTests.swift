import AVFoundation
import Foundation
import Testing
import ProviderKit
@testable import LocalMusic

@Suite struct CueTests {
    @Test func parsesCommonSheet() throws {
        let sheet = try #require(CueSheet.parse("""
        REM DATE 2003
        PERFORMER "周杰伦"
        TITLE "叶惠美"
        FILE "整轨.wav" WAVE
          TRACK 01 AUDIO
            TITLE "以父之名"
            INDEX 00 00:00:00
            INDEX 01 00:00:33
          TRACK 02 AUDIO
            TITLE "晴天"
            PERFORMER "周杰伦"
            INDEX 01 05:42:15
        """))
        #expect(sheet.title == "叶惠美")
        #expect(sheet.performer == "周杰伦")
        #expect(sheet.date == "2003")
        #expect(sheet.tracks.map(\.title) == ["以父之名", "晴天"])
        #expect(sheet.tracks.map(\.startMS) == [440, 342_200])
        #expect(sheet.tracks.allSatisfy { $0.file == "整轨.wav" })
    }

    /// 3 秒整轨 WAV + GBK 编码的 CUE（CUE 里写的是 .flac，实际是 .wav，也要找到）。
    @Test func scansCueAlbumIntoTracksAlbumsArtists() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-cue-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        do {
            let file = try AVAudioFile(forWriting: music.appending(path: "整轨.wav"), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3)!
            buf.frameLength = 44100 * 3
            try file.write(from: buf)
        }
        let cue = """
        PERFORMER "测试歌手"
        TITLE "测试专辑"
        FILE "整轨.flac" WAVE
          TRACK 01 AUDIO
            TITLE "第一首"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "第二首"
            PERFORMER "客串歌手"
            INDEX 01 00:01:00
          TRACK 03 AUDIO
            TITLE "第三首"
            INDEX 01 00:02:00
        """
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        try cue.data(using: gbk)!.write(to: music.appending(path: "整轨.cue"))

        let library = LocalMusicLibrary(paths: AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory)))
        try await library.addFolder(music)
        #expect(try await library.rescan() == 3)          // 整轨文件本身不再单独列出

        let provider = LocalMusicProvider(library: library)
        let ctx = RequestContext(platform: .local, account: nil)
        let songs = try await provider.library(.savedTracks, cursor: nil, context: ctx).items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        #expect(songs.map(\.metadata.title).sorted() == ["第一首", "第三首", "第二首"].sorted())

        let albums = try await provider.library(.savedAlbums, cursor: nil, context: ctx).items.compactMap { if case .album(let a) = $0 { a } else { nil } }
        #expect(albums.count == 1)
        #expect(albums.first?.title == "测试专辑")
        let albumTracks = try await provider.albumTracks(albums[0].ref, cursor: nil, context: ctx).items
        #expect(albumTracks.map(\.metadata.title) == ["第一首", "第二首", "第三首"])

        let artists = try await provider.library(.followedArtists, cursor: nil, context: ctx).items.compactMap { if case .artist(let a) = $0 { a.name } else { nil } }
        #expect(Set(artists) == ["测试歌手", "客串歌手"])

        let second = albumTracks[1]
        let stream = try await provider.resolveStream(second.ref, preferredLevel: nil, context: ctx)
        #expect(stream.clipRange == Duration.milliseconds(1000) ..< Duration.milliseconds(2000))
        #expect(stream.duration == .milliseconds(1000))
        #expect(stream.url.lastPathComponent == "整轨.wav")
    }
}

@Suite struct DSDLibraryTests {
    @Test func indexesDSF() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-dsd-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 最小 DSF：一个块组的静音
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let blocks = 70, size = UInt64(4096 * 2 * blocks)
        d.append(contentsOf: Array("DSD ".utf8)); u64(28); u64(92 + size); u64(0)
        d.append(contentsOf: Array("fmt ".utf8)); u64(52); u32(1); u32(0); u32(2); u32(2); u32(2_822_400); u32(1)
        u64(UInt64(4096 * 8 * blocks)); u32(4096); u32(0)
        d.append(contentsOf: Array("data".utf8)); u64(12 + size)
        d.append(Data(repeating: 0x69, count: Int(size)))
        try d.write(to: music.appending(path: "测试 DSD.dsf"))

        let library = LocalMusicLibrary(paths: AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory)))
        try await library.addFolder(music)
        #expect(try await library.rescan() == 1)
        let provider = LocalMusicProvider(library: library)
        let ctx = RequestContext(platform: .local, account: nil)
        let songs = try await provider.library(.savedTracks, cursor: nil, context: ctx).items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        #expect(songs.first?.metadata.title == "测试 DSD")
        #expect(songs.first?.metadata.duration.map { $0 > .milliseconds(800) && $0 < .milliseconds(900) } == true)
        let stream = try await provider.resolveStream(songs[0].ref, preferredLevel: nil, context: ctx)
        #expect(stream.quality.sampleRateHz == 2_822_400)
    }
}

@Suite struct SACDLibraryTests {
    /// 真实 SACD 镜像（只在设置了环境变量 AM_SACD_SAMPLE 时运行）：收录成一张专辑，曲目有时长，播放地址带区与曲目号。
    @Test func indexesSACDImage() async throws {
        guard let path = ProcessInfo.processInfo.environment["AM_SACD_SAMPLE"] else { return }
        let tracks = LocalMusicLibrary.indexSACD(URL(fileURLWithPath: path), folderID: "测试")
        #expect(!tracks.isEmpty)
        print("SACD 收录：\(tracks.count) 首，专辑“\(tracks[0].album ?? "")”，第 1 首“\(tracks[0].title)”，\((tracks[0].durationMS ?? 0) / 1000) 秒")
        #expect(tracks[0].id.hasSuffix("#sacd=2,1"))
        #expect(tracks.allSatisfy { ($0.durationMS ?? 0) > 1000 })
    }
}

@Suite struct APELibraryTests {
    static let dir = ProcessInfo.processInfo.environment["AM_APE_DIR"]

    /// 单个 APE（读 APEv2 标签）与 APE 加 CUE 分轨（只在设置了 AM_APE_DIR 时运行）。
    @Test(.enabled(if: dir != nil)) func indexesAPEAndCue() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-ape-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: Self.dir!).appending(path: "s16_c2000.ape")
        // 单曲：末尾加 APEv2 标签
        var single = try Data(contentsOf: source)
        var items = Data()
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for (key, value) in [("Title", "标签歌名"), ("Artist", "标签歌手"), ("Album", "标签专辑"), ("Track", "3/10")] {
            let v = Data(value.utf8)
            u32(UInt32(v.count), &items); u32(0, &items)
            items.append(contentsOf: Array(key.utf8) + [0]); items.append(v)
        }
        single.append(items)
        single.append(contentsOf: Array("APETAGEX".utf8)); u32(2000, &single); u32(UInt32(items.count + 32), &single)
        u32(4, &single); u32(0, &single); single.append(Data(count: 8))
        try single.write(to: music.appending(path: "单曲.ape"))
        // 整轨加 CUE（CUE 里写的是 .wav）
        try FileManager.default.copyItem(at: source, to: music.appending(path: "整轨.ape"))
        try """
        PERFORMER "整轨歌手"
        TITLE "整轨专辑"
        FILE "整轨.wav" WAVE
          TRACK 01 AUDIO
            TITLE "上半"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "下半"
            INDEX 01 00:20:00
        """.write(to: music.appending(path: "整轨.cue"), atomically: true, encoding: .utf8)

        let library = LocalMusicLibrary(paths: AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory)))
        try await library.addFolder(music)
        #expect(try await library.rescan() == 3)
        let provider = LocalMusicProvider(library: library)
        let ctx = RequestContext(platform: .local, account: nil)
        let songs = try await provider.library(.savedTracks, cursor: nil, context: ctx).items.compactMap { if case .track(let t) = $0 { t } else { nil } }
        let tagged = try #require(songs.first { $0.metadata.title == "标签歌名" })
        #expect(tagged.metadata.artists == ["标签歌手"])
        #expect(tagged.metadata.album == "标签专辑")
        #expect(tagged.metadata.trackNumber == 3)
        #expect(tagged.metadata.duration == .milliseconds(40000))
        let second = try #require(songs.first { $0.metadata.title == "下半" })
        #expect(second.metadata.duration == .milliseconds(20000))
        let stream = try await provider.resolveStream(second.ref, preferredLevel: nil, context: ctx)
        #expect(stream.url.scheme == SliceAssetLoader.scheme)
        #expect(stream.clipRange == Duration.milliseconds(20000) ..< Duration.milliseconds(40000))
        #expect(stream.quality.codec == "ape")
        #expect(stream.quality.bitDepth == 16)
    }
}

@Suite struct IncrementalScanTests {
    static func writeWAV(_ url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ])
        let frames = AVAudioFrameCount(44100 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
    }

    /// 没变的文件不重读；新增、修改、删除都能反映；文件夹读不到时保留原索引。
    @Test func onlyChangedFilesAreReindexed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-inc-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["一", "二", "三"] { try Self.writeWAV(music.appending(path: "\(name).wav"), seconds: 1) }
        let paths = AppPaths(root: root.appending(path: "data", directoryHint: .isDirectory))
        let library = LocalMusicLibrary(paths: paths)
        try await library.addFolder(path: music.path(percentEncoded: false))
        #expect(try await library.rescan() == 3)
        #expect(await library.lastScanStats.reindexed == 3)
        // 扫描时记下音频格式（整理资料库时区分音质版本用）
        let first = try #require(await library.allTracks().first)
        #expect(first.sampleRate == 44100 && first.bitDepth == 16 && first.codec == "wav" && first.lossless == true)

        #expect(try await library.rescan() == 3)
        #expect(await library.lastScanStats.reindexed == 0)

        try Self.writeWAV(music.appending(path: "四.wav"), seconds: 1)
        try FileManager.default.removeItem(at: music.appending(path: "一.wav"))
        try Self.writeWAV(music.appending(path: "二.wav"), seconds: 2)
        #expect(try await library.rescan() == 3)
        #expect(await library.lastScanStats.reindexed == 2)
        let titles = await library.allTracks().map(\.title).sorted()
        #expect(titles == ["三", "二", "四"].sorted())
        #expect(await library.allTracks().first { $0.title == "二" }?.durationMS == 2000)

        // 重新打开（从保存的索引读回），结果相同、无需重读
        let reopened = LocalMusicLibrary(paths: paths)
        #expect(await reopened.trackCount == 3)
        #expect(try await reopened.rescan() == 3)
        #expect(await reopened.lastScanStats.reindexed == 0)

        // 文件夹暂时读不到（像网络盘没挂载）：索引保留
        let moved = root.appending(path: "暂时移走", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: music, to: moved)
        #expect(try await reopened.rescan() == 3)
        let folder = try #require(await reopened.folders.first)
        #expect(await reopened.folderStatus[folder.id] == .unavailable)
        try FileManager.default.moveItem(at: moved, to: music)
        #expect(try await reopened.rescan() == 3)
        #expect(await reopened.folderStatus[folder.id] == .ok)
    }
}
