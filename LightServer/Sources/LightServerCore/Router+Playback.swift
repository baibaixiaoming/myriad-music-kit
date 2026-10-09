import Foundation
import MusicAPI
import ProviderKit
import SecureTransport

/// 播放：打开音频流、按 Range 读取。只直接转发普通音频文件；DSD、APE、光盘镜像回明确的“不支持”。
extension Router {
    static let playableExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "mp4"]

    /// 不是播放接口时返回 nil。
    func playback(_ request: HTTPRequest, user: API.UserInfo) async throws -> SecureServer.Response? {
        switch (request.method, request.path) {
        case ("POST", API.Path.streamOpen):
            let body = try API.decoder.decode(API.StreamOpenRequest.self, from: request.body)
            try checkSource(body.platform.rawValue)
            guard !body.id.isEmpty else { throw Self.badRequest }
            let resolved = try await queries.resolve(body.id)
            let url = resolved.url
            guard url.isFileURL, url.fragment == nil, Self.playableExtensions.contains(url.pathExtension.lowercased()) else {
                return Responses.unsupported("播放这种格式（DSD、APE、光盘镜像），请换成 FLAC、ALAC、MP3、AAC 或 WAV")
            }
            let id = await streams.open(owner: user.id, file: url)
            return Responses.json(API.StreamOpenResponse(
                streamID: id, quality: resolved.quality, duration: resolved.duration,
                previewStart: nil, previewEnd: nil,
                clipStart: resolved.clipRange?.lowerBound, clipEnd: resolved.clipRange?.upperBound))

        case ("GET", let path) where path.hasPrefix(API.Path.streamData):
            let id = String(path.dropFirst(API.Path.streamData.count))
            guard !id.isEmpty, !id.contains("/") else { return Responses.error(404, .resourceRemoved, "没有这个接口") }
            return await streams.read(id: id, owner: user.id, range: request.headers["range"])

        default:
            return nil
        }
    }
}
