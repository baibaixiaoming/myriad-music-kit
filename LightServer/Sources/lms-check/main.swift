import Foundation
import MusicAPI
import ProviderKit
import SecureTransport

// 连接测试：像播放器一样连一台服务器——用密码登录换设备密钥，再用设备密钥读服务器信息、来源、专辑、
// 一张专辑的曲目、封面、歌词，并完整读一首歌（先 bytes=0- 开放结尾，再分段按 Range 读，核对两次内容一致）。
// 用法：lms-check <地址> <端口> <用户名> <密码>
// 只连给定的服务器，不保存任何东西；密码与密钥不打印。

let args = CommandLine.arguments
guard args.count == 5, let port = UInt16(args[2]) else {
    print("用法：lms-check <地址> <端口> <用户名> <密码>")
    exit(2)
}
let host = args[1], username = args[3], password = args[4]

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print((ok ? "通过：" : "失败：") + what)
    if !ok { failures += 1 }
}

@MainActor func run() async throws {
    // 1. 密码登录
    let entry = TransportSecurity.passwordEntry(username: username, password: password)
    let first = SecureClient(host: host, port: port, key: entry)
    let (loginHead, loginBody) = try await first.send(HTTPRequest(method: "POST", path: API.Path.login,
        body: try API.encoder.encode(API.LoginRequest(deviceName: "连接测试"))))
    check(loginHead.status == 200, "密码登录（状态 \(loginHead.status)）")
    let login = try API.decoder.decode(API.LoginResponse.self, from: loginBody)
    guard let key = Data(base64Encoded: login.deviceKey) else { check(false, "设备密钥格式"); return }
    let client = SecureClient(host: host, port: port, key: .init(identity: "d:\(login.deviceID)", key: key))

    func get(_ path: String, _ query: [String: String] = [:], headers: [String: String] = [:]) async throws -> (HTTPResponseHead, Data) {
        try await client.send(HTTPRequest(method: "GET", path: path, query: query, headers: headers))
    }
    func post<B: Encodable>(_ path: String, _ body: B) async throws -> (HTTPResponseHead, Data) {
        try await client.send(HTTPRequest(method: "POST", path: path, body: try API.encoder.encode(body)))
    }

    // 2. 服务器信息与来源
    let (sh, sb) = try await get(API.Path.server)
    let info = try API.decoder.decode(API.ServerInfo.self, from: sb)
    check(sh.status == 200 && info.protocolVersion == API.protocolVersion, "服务器信息：版本 \(info.serverVersion)，协议 \(info.protocolVersion)，功能 \(info.features ?? [])")
    let (_, pb) = try await get(API.Path.providers)
    let providers = try API.decoder.decode([ProviderDescriptor].self, from: pb)
    check(providers.count == 1, "来源：\(providers.map { "\($0.platform.rawValue) \($0.displayName)" })")
    guard let source = providers.first?.platform.rawValue else { return }
    let (mh, _) = try await get(API.Path.me)
    check(mh.status == 200, "当前用户")

    // 3. 专辑、曲目
    let (_, ab) = try await get(API.Path.library, ["platform": source, "section": "savedAlbums"])
    let albums = try API.decoder.decode(API.PageResponse<SearchItem>.self, from: ab).items.compactMap { item -> PlatformAlbum? in
        if case .album(let a) = item { return a } else { return nil }
    }
    check(!albums.isEmpty, "专辑 \(albums.count) 张：\(albums.map(\.title).joined(separator: "、"))")
    guard let album = albums.first else { return }
    let (_, tb) = try await get(API.Path.albumTracks, ["platform": source, "id": album.ref.platformID])
    let tracks = try API.decoder.decode(API.PageResponse<PlatformTrack>.self, from: tb).items
    check(!tracks.isEmpty, "《\(album.title)》曲目 \(tracks.count) 首：\(tracks.map(\.metadata.title).joined(separator: "、"))")

    // 4. 封面
    if let art = album.artworkURL {
        let (h, data) = try await get(API.Path.artwork, ["url": art.absoluteString])
        check(h.status == 200 && data.count > 1000, "封面 \(data.count) 字节，类型 \(h.headers["content-type"] ?? "")")
    } else {
        check(false, "专辑没有封面地址")
    }

    // 5. 搜索
    let word = String(album.title.prefix(2))
    let (_, qb) = try await get(API.Path.search, ["platform": source, "q": word, "kind": "album"])
    let found = try API.decoder.decode(API.PageResponse<SearchItem>.self, from: qb).items.count
    check(found >= 1, "搜索专辑“\(word)”：\(found) 个结果")

    // 6. 歌词（找一首有歌词的）
    var lyricLines = 0
    for album in albums {
        let (_, tb) = try await get(API.Path.albumTracks, ["platform": source, "id": album.ref.platformID])
        for t in try API.decoder.decode(API.PageResponse<PlatformTrack>.self, from: tb).items {
            let (_, lb) = try await get(API.Path.lyrics, ["platform": source, "id": t.ref.platformID])
            let lyrics = try API.decoder.decode(LyricsResult.self, from: lb)
            if lyrics.status == .available { lyricLines = lyrics.tracks.first?.lines.count ?? 0; break }
        }
        if lyricLines > 0 { break }
    }
    check(lyricLines > 0, "歌词：找到一首带时间轴的歌词，\(lyricLines) 行")

    // 7. 完整读一首歌
    let track = tracks[0]
    let (oh, ob) = try await post(API.Path.streamOpen, API.StreamOpenRequest(platform: track.ref.platform, id: track.ref.platformID, level: nil))
    let opened = try API.decoder.decode(API.StreamOpenResponse.self, from: ob)
    check(oh.status == 200, "打开《\(track.metadata.title)》：\(opened.quality.codec ?? "") \(opened.quality.sampleRateHz ?? 0) Hz \(opened.quality.bitDepth ?? 0) 位")
    let streamPath = API.Path.streamData + opened.streamID
    let (fh, whole) = try await get(streamPath, headers: ["range": "bytes=0-"])
    let total = fh.headers["content-range"].flatMap { $0.split(separator: "/").last }.flatMap { Int($0) } ?? -1
    check(fh.status == 206 && whole.count == total, "bytes=0- 开放结尾：状态 \(fh.status)，收到 \(whole.count) 字节，文件 \(total) 字节")
    var pieces = Data()
    var offset = 0
    let step = 1_000_000
    while offset < total {
        let end = min(offset + step, total) - 1
        let (h, d) = try await get(streamPath, headers: ["range": "bytes=\(offset)-\(end)"])
        guard h.status == 206, d.count == end - offset + 1 else { check(false, "分段读取 \(offset)-\(end)"); return }
        pieces.append(d)
        offset = end + 1
    }
    check(pieces == whole, "分段读取 \(Int((Double(total) / Double(step)).rounded(.up))) 段，拼起来与整读一致")
    let (th, _) = try await get(streamPath, headers: ["range": "bytes=-1000"])
    check(th.status == 206, "末尾 1000 字节（bytes=-1000）")

    // 8. 不支持的功能有明确说明
    let (uh, ub) = try await post(API.Path.favoritesAdd, API.TracksRequest(tracks: [track]))
    let message = (try? API.decoder.decode(API.ErrorResponse.self, from: ub).message) ?? ""
    check(uh.status == 501 && !message.isEmpty, "加入收藏：\(uh.status)，“\(message)”")
}

do {
    try await run()
} catch {
    print("出错：\(error)")
    failures += 1
}
print(failures == 0 ? "全部通过" : "有 \(failures) 项失败")
exit(failures == 0 ? 0 : 1)
