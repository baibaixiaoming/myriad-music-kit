import Foundation
import MusicAPI
import SecureTransport

/// 本服务器不提供的功能（/v1/server 里都没有声明）。
/// 客户端有些地方不看功能声明也会来调用（例如记播放历史、打开收藏页），所以：
/// - 读取类回空列表，播放历史的记录与清空回 204（不保存），客户端照常工作；
/// - 写入类回 501 和一句说明（客户端直接显示），不会卡住。
extension Router {
    func unsupported(_ request: HTTPRequest) -> SecureServer.Response? {
        let path = request.path
        switch (request.method, path) {
        // 软件资料库：读取回空
        case ("GET", API.Path.favorites): return Responses.json([API.LibraryEntry]())
        case ("GET", API.Path.playlists): return Responses.json([API.PlaylistSummary]())
        case ("GET", API.Path.history): return Responses.json([API.HistoryEntry]())
        case ("GET", API.Path.playlist): return Responses.error(404, .resourceRemoved, "找不到这个歌单")
        case ("POST", API.Path.historyAdd), ("POST", API.Path.historyClear): return .status(204)

        // 软件资料库：写入
        case ("POST", API.Path.favoritesAdd), ("POST", API.Path.favoritesRemove): return Responses.unsupported("软件收藏")
        case ("POST", let p) where p.hasPrefix("/v1/my/playlist/"): return Responses.unsupported("软件歌单")

        // 平台账户、平台资料库写入、借用
        case ("POST", API.Path.smsSend), ("POST", API.Path.smsLogin), ("POST", API.Path.qrLogin),
             ("POST", API.Path.platformLogout), ("POST", API.Path.platformChoice), ("POST", API.Path.lending):
            return Responses.unsupported("登录音乐平台账户")
        case ("POST", API.Path.platformWrite), ("POST", API.Path.platformPlaylist):
            return Responses.unsupported("修改资料库")

        // 下载、光盘查询、诊断上传
        case ("POST", API.Path.downloadCandidates), ("POST", API.Path.downloadOpen): return Responses.unsupported("下载")
        case ("POST", API.Path.discLookup): return Responses.unsupported("查询光盘信息")
        case ("POST", API.Path.diagnosticsUpload): return Responses.unsupported("接收诊断信息")

        // 唱片资料：按协议，没配置资料库时 info 回“未配置”，其余回 502
        case ("GET", API.Path.catalogInfo): return Responses.json(API.CatalogInfo(configured: false))
        case (_, let p) where p.hasPrefix("/v1/catalog/"):
            return Responses.error(502, .moduleUnavailable, "轻量音乐服务器没有唱片资料库")

        default: return nil
        }
    }
}
