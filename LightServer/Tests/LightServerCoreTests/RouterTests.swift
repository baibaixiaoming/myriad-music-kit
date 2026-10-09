import Foundation
import MusicAPI
import ProviderKit
import SecureTransport
import Testing
@testable import LightServerCore

/// 接口分派：身份、登录、内容、不支持的功能。不经网络，直接调用分派。
@Suite struct RouterTests {
    @Test func identitiesAndLogin() async throws {
        let h = try await Harness.make()
        #expect(await h.call("d:不存在", "GET", API.Path.server).status == 401)
        #expect(await h.call("u:someone", "GET", API.Path.server).status == 401)
        // 密码身份只能登录
        #expect(await h.call("u:demo", "GET", API.Path.server).status == 403)

        let device = try await h.login()
        // 回复前已把含新设备的密钥表装进加密端口
        #expect(h.installed.last?.contains { $0.identity == device } == true)
        #expect(h.installed.last?.contains { $0.identity == "u:demo" } == true)
        let info = try await h.call(device, "GET", API.Path.server).decode(API.ServerInfo.self)
        #expect(info.protocolVersion == API.protocolVersion)
        #expect(info.features == [])
        // 设备表落盘、权限 600
        let attributes = try FileManager.default.attributesOfItem(atPath: h.home.paths.devicesFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func loginRollsBackWhenKeysCannotBeInstalled() async throws {
        let h = try await Harness.make(withSamples: false, failInstall: true)
        let r = await h.call("u:demo", "POST", API.Path.login, body: try API.encoder.encode(API.LoginRequest(deviceName: "x")))
        #expect(r.status == 500)
        #expect(await h.accounts.deviceCount == 0)
    }

    @Test func concurrentLoginsAllEndUpInKeyTable() async throws {
        let h = try await Harness.make(withSamples: false)
        let devices = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await h.login() } }
            var all: [String] = []
            for try await d in group { all.append(d) }
            return all
        }
        let last = Set(h.installed.last?.map(\.identity) ?? [])
        #expect(devices.allSatisfy { last.contains($0) })
    }

    @Test func providersAndMe() async throws {
        let h = try await Harness.make(withSamples: false)
        let device = try await h.login()
        let providers = try await h.call(device, "GET", API.Path.providers).decode([ProviderDescriptor].self)
        #expect(providers.count == 1)
        #expect(providers[0].platform.rawValue == "1")
        #expect(providers[0].displayName == "本地音乐")
        #expect(providers[0].role == .musicLibrary)
        #expect(providers[0].mayExpose(.search(.album)) && providers[0].mayExpose(.resolveStream))
        let me = try await h.call(device, "GET", API.Path.me).decode(API.MeResponse.self)
        #expect(me.user.username == "demo")
        #expect(me.platforms.map(\.platform.rawValue) == ["1"])
    }

    @Test func browsingSearchLyricsAndArtwork() async throws {
        let h = try await Harness.make()
        let device = try await h.login()
        let albums = try await h.call(device, "GET", API.Path.library, query: ["platform": "1", "section": "savedAlbums"])
            .decode(API.PageResponse<SearchItem>.self).items.compactMap { item -> PlatformAlbum? in
                if case .album(let a) = item { a } else { nil }
            }
        #expect(Set(albums.map(\.title)) == ["晨光小品集", "夜行列车", "风吹过的路", "Daisy Bell"])
        #expect(albums.allSatisfy { $0.artworkURL != nil })

        // 专辑曲目：编号是音乐文件夹里的相对路径，不带文件地址
        let night = try #require(albums.first { $0.title == "夜行列车" })
        let tracks = try await h.call(device, "GET", API.Path.albumTracks, query: ["platform": "1", "id": night.ref.platformID])
            .decode(API.PageResponse<PlatformTrack>.self).items
        #expect(tracks.map(\.metadata.title) == ["零点出发", "城市脉搏", "霓虹回声"])
        #expect(tracks.allSatisfy { !$0.ref.platformID.hasPrefix("/") && $0.metadata.originalURL == nil && $0.metadata.artworkURL != nil })
        let one = try await h.call(device, "GET", API.Path.track, query: ["platform": "1", "id": tracks[1].ref.platformID])
            .decode(PlatformTrack.self)
        #expect(one.metadata.title == "城市脉搏")

        // 封面
        let art = await h.call(device, "GET", API.Path.artwork, query: ["url": night.artworkURL!.absoluteString])
        #expect(art.status == 200 && art.headers["content-type"] == "image/jpeg" && art.body.count > 10_000)
        #expect(await h.call(device, "GET", API.Path.artwork, query: ["url": "lightmusic://artwork/000000000000000000000000"]).status == 404)
        #expect(await h.call(device, "GET", API.Path.artwork, query: ["url": "file:///etc/passwd"]).status == 404)

        // 歌词：同名 .lrc
        let lyrics = try await h.call(device, "GET", API.Path.lyrics, query: ["platform": "1", "id": tracks[1].ref.platformID])
            .decode(LyricsResult.self)
        #expect(lyrics.status == .available)
        #expect(lyrics.tracks.first?.lines.contains { $0.text.contains("零点的街灯") } == true)
        #expect(lyrics.matchedRef?.platformID == tracks[1].ref.platformID)
        let none = try await h.call(device, "GET", API.Path.lyrics, query: ["platform": "1", "id": tracks[0].ref.platformID])
            .decode(LyricsResult.self)
        #expect(none.status == .noResult)

        // 搜索：歌曲、专辑、歌手（繁体也能搜到）
        func search(_ q: String, _ kind: String) async throws -> [SearchItem] {
            try await h.call(device, "GET", API.Path.search, query: ["platform": "1", "q": q, "kind": kind])
                .decode(API.PageResponse<SearchItem>.self).items
        }
        #expect(try await search("篝火", "track").count == 1)
        #expect(try await search("夜行", "album").count == 1)
        #expect(try await search("霓虹回路", "artist").count == 1)
        #expect(try await search("霓虹回路", "track").count == 3)
        #expect(try await search("風吹過", "album").count == 1)
        #expect(await h.call(device, "GET", API.Path.search, query: ["platform": "1", "q": "x", "kind": "playlist"]).status == 501)

        // 歌手的歌与专辑
        let artists = try await h.call(device, "GET", API.Path.library, query: ["platform": "1", "section": "followedArtists"])
            .decode(API.PageResponse<SearchItem>.self).items
        #expect(artists.count == 4)
        guard case .artist(let folk) = try #require(artists.first(where: { if case .artist(let a) = $0 { a.name == "麦田旅人" } else { false } })) else { return }
        let folkSongs = try await h.call(device, "GET", API.Path.artistTracks, query: ["platform": "1", "id": folk.ref.platformID])
            .decode(API.PageResponse<PlatformTrack>.self).items
        #expect(folkSongs.count == 3)
        let folkAlbums = try await h.call(device, "GET", API.Path.artistAlbums, query: ["platform": "1", "id": folk.ref.platformID])
            .decode(API.PageResponse<PlatformAlbum>.self).items
        #expect(folkAlbums.map(\.title) == ["风吹过的路"])

        // 别的来源编号
        #expect(await h.call(device, "GET", API.Path.library, query: ["platform": "2", "section": "savedAlbums"]).status == 404)
        #expect(await h.call(device, "GET", API.Path.library, query: ["platform": "1", "section": "likedTracks"]).status == 501)
    }

    @Test func unsupportedFeaturesAnswerClearly() async throws {
        let h = try await Harness.make(withSamples: false)
        let device = try await h.login()
        let track = PlatformTrack(ref: PlatformResourceRef(platform: PlatformID("1"), kind: .track, platformID: "a.flac"),
                                  metadata: TrackMetadata(title: "a", artists: []))
        let add = await h.call(device, "POST", API.Path.favoritesAdd, body: try API.encoder.encode(API.TracksRequest(tracks: [track])))
        #expect(add.status == 501)
        #expect(try add.decode(API.ErrorResponse.self).message.contains("不支持"))
        #expect(await h.call(device, "POST", API.Path.playlistCreate, body: try API.encoder.encode(API.PlaylistRequest(name: "x"))).status == 501)
        #expect(try await h.call(device, "GET", API.Path.favorites).decode([API.LibraryEntry].self).isEmpty)
        #expect(try await h.call(device, "GET", API.Path.playlists).decode([API.PlaylistSummary].self).isEmpty)
        #expect(try await h.call(device, "GET", API.Path.history).decode([API.HistoryEntry].self).isEmpty)
        #expect(await h.call(device, "POST", API.Path.historyAdd, body: try API.encoder.encode(API.TracksRequest(tracks: [track]))).status == 204)
        #expect(await h.call(device, "POST", API.Path.downloadCandidates, body: Data("{}".utf8)).status == 501)
        #expect(await h.call(device, "POST", API.Path.qrLogin, body: Data("{}".utf8)).status == 501)
        let catalog = try await h.call(device, "GET", API.Path.catalogInfo).decode(API.CatalogInfo.self)
        #expect(catalog.configured == false)
        #expect(await h.call(device, "GET", "/v1/nothing").status == 404)
        // 其他来源的歌问歌词：回“没有”，不报错
        let other = PlatformTrack(ref: PlatformResourceRef(platform: PlatformID("9"), kind: .track, platformID: "x"),
                                  metadata: TrackMetadata(title: "x", artists: []))
        let lyrics = await h.call(device, "POST", API.Path.lyricsForTrack, body: try API.encoder.encode(API.TrackRequest(track: other)))
        #expect(lyrics.status == 200)
        #expect(try lyrics.decode(LyricsResult.self).status == .noResult)
    }
}
