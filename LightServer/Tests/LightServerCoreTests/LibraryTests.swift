import Foundation
import LocalMusic
import ProviderKit
import Testing
@testable import LightServerCore

/// 音乐库：示例音乐的标签能被认出；文件夹变化后自动重扫；文件夹清空后不再列出旧歌。
@Suite struct LibraryTests {
    @Test func sampleTagsAreRecognized() async throws {
        let home = try TestHome(withSamples: true)
        let library = MusicLibraryService(root: home.paths.music, indexFile: home.paths.libraryIndexFile)
        await library.rescan()
        let tracks = await library.library.allTracks()
        #expect(tracks.count == 10)
        struct Expected { let title: String; let artist: String; let album: String; let number: Int; let year: Int; let genre: String; let codec: String }
        let expected = [
            Expected(title: "窗边的雨", artist: "白石小屋", album: "晨光小品集", number: 1, year: 2024, genre: "钢琴", codec: "flac"),
            Expected(title: "旧书页", artist: "白石小屋", album: "晨光小品集", number: 2, year: 2024, genre: "钢琴", codec: "flac"),
            Expected(title: "傍晚散步", artist: "白石小屋", album: "晨光小品集", number: 3, year: 2024, genre: "钢琴", codec: "flac"),
            Expected(title: "零点出发", artist: "霓虹回路", album: "夜行列车", number: 1, year: 2025, genre: "电子", codec: "alac"),
            Expected(title: "城市脉搏", artist: "霓虹回路", album: "夜行列车", number: 2, year: 2025, genre: "电子", codec: "alac"),
            Expected(title: "霓虹回声", artist: "霓虹回路", album: "夜行列车", number: 3, year: 2025, genre: "电子", codec: "alac"),
            Expected(title: "南方小站", artist: "麦田旅人", album: "风吹过的路", number: 1, year: 2026, genre: "民谣", codec: "flac"),
            Expected(title: "风吹过的路", artist: "麦田旅人", album: "风吹过的路", number: 2, year: 2026, genre: "民谣", codec: "alac"),
            Expected(title: "篝火边", artist: "麦田旅人", album: "风吹过的路", number: 3, year: 2026, genre: "民谣", codec: "flac"),
        ]
        for e in expected {
            let t = try #require(tracks.first { $0.title == e.title }, "找不到 \(e.title)")
            #expect(t.artists == [e.artist], "\(e.title) 歌手")
            #expect(t.album == e.album, "\(e.title) 专辑")
            #expect(t.trackNumber == e.number, "\(e.title) 音轨号")
            #expect(t.year == e.year, "\(e.title) 年份")
            #expect(t.genres == [e.genre], "\(e.title) 流派")
            #expect(t.codec == e.codec, "\(e.title) 编码")
            #expect(t.sampleRate == 44100 && t.bitDepth == 16, "\(e.title) 采样率与位深")
            let seconds = Double(t.durationMS ?? 0) / 1000
            #expect(abs(seconds - 30) < 0.5, "\(e.title) 时长 \(seconds)")
        }
        // 每首歌都找到封面（专辑文件夹里的 cover.jpg）
        #expect(await library.artwork.trackCount == 10)
    }

    @Test func embeddedArtworkIsFound() async throws {
        let samples = TestHome.samples
        let flac = samples.appending(path: "白石小屋 - 晨光小品集/01 窗边的雨.flac")
        let m4a = samples.appending(path: "霓虹回路 - 夜行列车/01 零点出发.m4a")
        for file in [flac, m4a] {
            #expect(await EmbeddedArtwork.exists(in: file), "\(file.lastPathComponent)")
            let data = try #require(await EmbeddedArtwork.read(from: file))
            #expect(ArtworkIndex.mime(data) == "image/jpeg")
        }
        // 文件夹里没有图片时，用内嵌封面
        let home = try TestHome(withSamples: false)
        try FileManager.default.copyItem(at: flac, to: home.paths.music.appending(path: "a.flac"))
        let library = MusicLibraryService(root: home.paths.music, indexFile: home.paths.libraryIndexFile)
        await library.rescan()
        let url = try #require(await library.artwork.url(forTrackPath: home.paths.music.appending(path: "a.flac").path(percentEncoded: false)))
        let image = try #require(await library.artwork.image(for: url.absoluteString))
        #expect(image.type == "image/jpeg" && image.data.count > 10_000)
    }

    @Test func folderChangesTriggerRescan() async throws {
        let home = try TestHome(withSamples: false)
        let library = MusicLibraryService(root: home.paths.music, indexFile: home.paths.libraryIndexFile)
        await library.rescan()
        #expect(await library.count == 0)
        let watcher = FolderWatcher(folder: home.paths.music, debounce: 0.5) { Task { await library.rescan() } }
        #expect(watcher.start())
        defer { watcher.stop() }

        // 拷进一张专辑：自动出现
        let album = TestHome.samples.appending(path: "麦田旅人 - 风吹过的路", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: album, to: home.paths.music.appending(path: "新专辑", directoryHint: .isDirectory))
        #expect(await waitUntil(15) { await library.count == 3 })

        // 删掉一首：自动消失
        try FileManager.default.removeItem(at: home.paths.music.appending(path: "新专辑/03 篝火边.flac"))
        #expect(await waitUntil(15) { await library.count == 2 })

        // 全部删掉：旧索引也清掉，不再列出
        try FileManager.default.removeItem(at: home.paths.music.appending(path: "新专辑", directoryHint: .isDirectory))
        #expect(await waitUntil(15) { await library.count == 0 })
        #expect(await library.library.trackCount == 0)
    }

    /// 曾经的问题：登记的文件夹带末尾斜杠，比较不上，每次扫描都把文件夹删掉重加、全部重读。
    @Test func rescanIsIncremental() async throws {
        let home = try TestHome(withSamples: true)
        let library = MusicLibraryService(root: home.paths.music, indexFile: home.paths.libraryIndexFile)
        await library.rescan()
        #expect(await library.library.lastScanStats.reindexed == 10)
        await library.rescan()
        #expect(await library.library.lastScanStats.checked == 10)
        #expect(await library.library.lastScanStats.reindexed == 0)
        #expect(await library.library.folders.count == 1)
    }

    @Test func sampleInstallOnlyOnce() throws {
        let home = try TestHome(withSamples: false)
        #expect(!SampleMusic.isInstalled(in: home.paths.music))
        try SampleMusic.install(from: TestHome.samples, paths: home.paths)
        #expect(SampleMusic.isInstalled(in: home.paths.music))
        #expect(throws: SampleMusic.InstallError.self) { try SampleMusic.install(from: TestHome.samples, paths: home.paths) }
        // 中转处没有留下东西
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: home.paths.stagingFolder.path(percentEncoded: false))) ?? []
        #expect(staging.isEmpty)
    }
}
