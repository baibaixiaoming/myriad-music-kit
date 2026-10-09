import Foundation
import MusicAPI
import ProviderKit
import Testing
@testable import LightServerCore

/// 打开音频与按 Range 读取。
@Suite struct StreamTests {
    @Test func rangeParsing() {
        #expect(ByteRange.parse(nil, length: 100) == .whole)
        #expect(ByteRange.parse("bytes=0-", length: 100) == .partial(start: 0, end: 99))
        #expect(ByteRange.parse("bytes=10-19", length: 100) == .partial(start: 10, end: 19))
        #expect(ByteRange.parse("bytes=90-200", length: 100) == .partial(start: 90, end: 99))
        #expect(ByteRange.parse("bytes=-10", length: 100) == .partial(start: 90, end: 99))
        #expect(ByteRange.parse("bytes=-500", length: 100) == .partial(start: 0, end: 99))
        #expect(ByteRange.parse("bytes=100-", length: 100) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=0-", length: 0) == .unsatisfiable)
        #expect(ByteRange.parse("bytes=5-1", length: 100) == .whole)
        #expect(ByteRange.parse("items=0-1", length: 100) == .whole)
        #expect(ByteRange.parse("bytes=0-9, 20-29", length: 100) == .partial(start: 0, end: 9))
    }

    @Test func openAndReadWithRanges() async throws {
        let h = try await Harness.make()
        let device = try await h.login()
        let songs = try await h.call(device, "GET", API.Path.library, query: ["platform": "1", "section": "savedTracks"])
            .decode(API.PageResponse<SearchItem>.self).items.compactMap { item -> PlatformTrack? in
                if case .track(let t) = item { t } else { nil }
            }
        #expect(songs.count == 10)
        for title in ["窗边的雨", "城市脉搏"] {   // 一首 FLAC、一首 ALAC
            let song = try #require(songs.first { $0.metadata.title == title })
            let file = h.home.paths.music.appending(path: song.ref.platformID)
            let original = try Data(contentsOf: file)
            let open = await h.call(device, "POST", API.Path.streamOpen,
                                    body: try API.encoder.encode(API.StreamOpenRequest(platform: song.ref.platform, id: song.ref.platformID, level: nil)))
            #expect(open.status == 200)
            let opened = try open.decode(API.StreamOpenResponse.self)
            #expect(opened.quality.tier == .lossless)
            #expect(opened.quality.codec == (title == "窗边的雨" ? "flac" : "m4a"))
            let path = API.Path.streamData + opened.streamID

            // bytes=0- 开放结尾：206，整首
            let whole = await h.call(device, "GET", path, headers: ["range": "bytes=0-"])
            #expect(whole.status == 206)
            #expect(whole.headers["content-range"] == "bytes 0-\(original.count - 1)/\(original.count)")
            #expect(whole.body == original)
            // 中间一段
            let middle = await h.call(device, "GET", path, headers: ["range": "bytes=1000-300999"])
            #expect(middle.status == 206 && middle.body == original[1000...300999])
            // 末尾
            let tail = await h.call(device, "GET", path, headers: ["range": "bytes=-100"])
            #expect(tail.status == 206 && tail.body == original.suffix(100))
            // 不带 Range：200
            let plain = await h.call(device, "GET", path)
            #expect(plain.status == 200 && plain.body == original)
            // 超出范围
            let beyond = await h.call(device, "GET", path, headers: ["range": "bytes=\(original.count)-"])
            #expect(beyond.status == 416)
        }
        // 别的设备也属于同一用户：可以读；不存在的编号：404
        #expect(await h.call(device, "GET", API.Path.streamData + "nope").status == 404)
        // 别的来源
        let other = await h.call(device, "POST", API.Path.streamOpen,
                                 body: try API.encoder.encode(API.StreamOpenRequest(platform: PlatformID("3"), id: "x", level: nil)))
        #expect(other.status == 404)
        // 已不存在的歌
        let gone = await h.call(device, "POST", API.Path.streamOpen,
                                body: try API.encoder.encode(API.StreamOpenRequest(platform: PlatformID("1"), id: "没有/这首.flac", level: nil)))
        #expect(gone.status == 404)
    }

    @Test func fileRemovedAfterOpenGivesClearError() async throws {
        let h = try await Harness.make()
        let device = try await h.login()
        let song = try await h.call(device, "GET", API.Path.search, query: ["platform": "1", "q": "篝火", "kind": "track"])
            .decode(API.PageResponse<SearchItem>.self).items.first
        guard case .track(let t) = try #require(song) else { return }
        let opened = try await h.call(device, "POST", API.Path.streamOpen,
                                      body: try API.encoder.encode(API.StreamOpenRequest(platform: t.ref.platform, id: t.ref.platformID, level: nil)))
            .decode(API.StreamOpenResponse.self)
        try FileManager.default.removeItem(at: h.home.paths.music.appending(path: t.ref.platformID))
        let read = await h.call(device, "GET", API.Path.streamData + opened.streamID, headers: ["range": "bytes=0-"])
        #expect(read.status == 404)
        #expect(try read.decode(API.ErrorResponse.self).message.isEmpty == false)
    }
}
