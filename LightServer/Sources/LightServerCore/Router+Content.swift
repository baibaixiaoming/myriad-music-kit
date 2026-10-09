import Foundation
import MusicAPI
import ProviderKit
import SecureTransport

/// 内容接口：服务器信息、当前用户、来源列表、搜索、资料库、曲目、专辑与歌手、歌词、封面。
extension Router {
    /// 不是内容接口时返回 nil。
    func content(_ request: HTTPRequest, user: API.UserInfo) async throws -> SecureServer.Response? {
        let q = request.query
        switch (request.method, request.path) {
        case ("GET", API.Path.server):
            // 收藏、歌单、历史、下载等都不提供，所以不声明任何服务器功能（客户端据此不显示那些页面）
            return Responses.json(API.ServerInfo(serverVersion: serverVersion, protocolVersion: API.protocolVersion, features: []))

        case ("GET", API.Path.me):
            let d = queries.descriptor
            let status = API.PlatformStatus(platform: d.platform, displayName: d.displayName, supportsLogin: false,
                                            mode: .guest, current: nil, own: nil, borrowable: [])
            return Responses.json(API.MeResponse(user: user, platforms: [status], members: []))

        case ("GET", API.Path.providers):
            return Responses.json([queries.descriptor])

        case ("POST", API.Path.providerIDs):
            // 只有一个来源，编号从来没变过：没有要换算的旧编号
            _ = try API.decoder.decode(API.SourceIDsRequest.self, from: request.body)
            return Responses.json(API.SourceIDsResponse(ids: [:]))

        case ("GET", API.Path.search):
            try checkSource(q["platform"])
            guard let text = q["q"], let kind = q["kind"].flatMap(SearchKind.init(rawValue:)) else { throw Self.badRequest }
            guard LibraryQueries.searchKinds.contains(kind) else { return Responses.unsupported("搜索歌单") }
            return Self.page(try await queries.search(text, kind: kind))

        case ("GET", API.Path.searchAll):
            // 只有一个来源，统一搜索就是这个来源的搜索（未声明 rankedSearch，客户端不会调用；给其他客户端留个正常结果）
            guard let text = q["q"], let kind = q["kind"].flatMap(SearchKind.init(rawValue:)) else { throw Self.badRequest }
            let items = LibraryQueries.searchKinds.contains(kind) ? try await queries.search(text, kind: kind) : []
            return Responses.json(API.SearchAllResponse(items: items, failures: []))

        case ("GET", API.Path.library):
            try checkSource(q["platform"])
            guard let section = q["section"].flatMap(LibrarySection.init(rawValue:)) else { throw Self.badRequest }
            guard LibraryQueries.sections.contains(section) else { return Responses.unsupported("这个资料库栏目") }
            return Self.page(try await queries.section(section))

        case ("GET", API.Path.track):
            try checkSource(q["platform"])
            return Responses.json(try await queries.track(try requiredID(request)))

        case ("GET", API.Path.albumTracks):
            try checkSource(q["platform"])
            return Self.page(try await queries.albumTracks(try requiredID(request)))

        case ("GET", API.Path.playlistTracks):
            try checkSource(q["platform"])
            return Responses.unsupported("歌单")

        case ("GET", API.Path.artistTracks):
            try checkSource(q["platform"])
            return Self.page(try await queries.artistTracks(try requiredID(request)))

        case ("GET", API.Path.artistAlbums):
            try checkSource(q["platform"])
            return Self.page(try await queries.artistAlbums(try requiredID(request)))

        case ("GET", API.Path.lyrics):
            try checkSource(q["platform"])
            return Responses.json(try await queries.lyrics(try requiredID(request)))

        case ("POST", API.Path.lyricsForTrack):
            // 未声明 lyricsForTrack；客户端在播放来源没有歌词时仍会来问：本来源的歌照常查，其他来源的回“没有”
            let track = try API.decoder.decode(API.TrackRequest.self, from: request.body).track
            guard track.ref.platform == MusicLibraryService.sourceID else {
                return Responses.json(LyricsResult(status: .noResult, tracks: [], matchedRef: nil))
            }
            return Responses.json(try await queries.lyrics(track.ref.platformID))

        case ("GET", API.Path.artwork):
            guard let raw = q["url"], let image = await queries.service.artwork.image(for: raw) else {
                return Responses.error(404, .resourceRemoved, "没有这张封面")
            }
            return .full(HTTPResponseHead(status: 200, headers: ["content-type": image.type, "cache-control": "max-age=86400"]), image.data)

        default:
            return nil
        }
    }
}
