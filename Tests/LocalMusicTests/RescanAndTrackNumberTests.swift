import AVFoundation
import Foundation
import Testing
import ProviderKit
@testable import LocalMusic

/// 重新扫描后整理结果跟着变；iTunes 二进制音轨号能读出来。
@Suite struct RescanAndTrackNumberTests {
    func writeTone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for i in 0..<4410 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.2 }
        try file.write(from: buffer)
    }

    /// 曾经的问题：整理结果（专辑、歌曲、歌手）第一次查询后就缓存住，之后重新扫描加进来的歌要等重启才出现。
    @Test func albumsAndSongsFollowRescan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-rescan-\(UUID())", directoryHint: .isDirectory)
        let music = root.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalMusicLibrary(store: JSONLibraryStore(file: root.appending(path: "index.json")))
        try await library.addFolder(path: music.path(percentEncoded: false))
        try await library.rescan()
        let provider = LocalMusicProvider(library: library)
        let ctx = RequestContext(platform: .local, account: nil)
        #expect(try await provider.library(.savedTracks, cursor: nil, context: ctx).items.isEmpty)

        try FileManager.default.createDirectory(at: music.appending(path: "专辑"), withIntermediateDirectories: true)
        try writeTone(music.appending(path: "专辑/01 第一首.caf"))
        try await library.rescan()
        #expect(try await provider.library(.savedTracks, cursor: nil, context: ctx).items.count == 1)
        #expect(try await provider.library(.savedAlbums, cursor: nil, context: ctx).items.count == 1)

        try FileManager.default.removeItem(at: music.appending(path: "专辑/01 第一首.caf"))
        try writeTone(music.appending(path: "专辑/02 第二首.caf"))
        try await library.rescan()
        let titles = try await provider.library(.savedTracks, cursor: nil, context: ctx).items.compactMap { item -> String? in
            if case .track(let t) = item { t.metadata.title } else { nil }
        }
        #expect(titles == ["第二首"])
    }

    @Test func iTunesBinaryTrackNumber() {
        #expect(TagValues.iTunesNumberPair(Data([0, 0, 0, 2, 0, 3, 0, 0])) == "2/3")
        #expect(TagValues.iTunesNumberPair(Data([0, 0, 0, 12, 0, 0])) == "12")
        #expect(TagValues.iTunesNumberPair(Data([0, 0, 1, 0, 0, 0])) == "256")
        #expect(TagValues.iTunesNumberPair(Data([0, 0, 0, 0, 0, 3])) == nil)
        #expect(TagValues.iTunesNumberPair(Data([0, 0, 0])) == nil)
        #expect(TagValues.iTunesNumberPair(nil) == nil)
        #expect(TagValues(["TRACKNUMBER": ["2/3"]]).trackNumber == 2)
    }
}
