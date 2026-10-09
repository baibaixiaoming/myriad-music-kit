import Foundation
import MusicAPI
import ProviderKit
import SecureTransport

/// 回复的统一写法：JSON 正文、错误体 `{category, message}`（协议第 5 节）。
enum Responses {
    static func json<T: Encodable>(_ value: T, status: Int = 200) -> SecureServer.Response {
        guard let data = try? API.encoder.encode(value) else {
            return error(500, .parseFailure, "服务器无法生成回复")
        }
        return .json(status, data)
    }

    static func error(_ status: Int, _ category: MusicErrorCategory, _ message: String) -> SecureServer.Response {
        let body = (try? API.encoder.encode(API.ErrorResponse(category: category, message: message))) ?? Data()
        return .json(status, body)
    }

    /// 本服务器不提供的功能：501，说明里写清是什么不支持，客户端直接显示给用户。
    static func unsupported(_ what: String) -> SecureServer.Response {
        error(501, .moduleUnavailable, "轻量音乐服务器不支持\(what)")
    }

    static var badRequest: SecureServer.Response { error(400, .parseFailure, "请求参数不完整") }

    static func status(for category: MusicErrorCategory) -> Int {
        switch category {
        case .notLoggedIn, .credentialExpired: 401
        case .insufficientEntitlement, .regionOrCopyrightRestricted: 403
        case .resourceRemoved: 404
        case .rateLimited: 429
        case .network, .upstreamChanged, .timeout, .moduleUnavailable: 502
        default: 400
        }
    }
}
