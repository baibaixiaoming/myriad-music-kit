import Foundation
import MusicAPI
import ProviderKit
import SecureTransport

/// 加密端口上的接口分派。只有一个用户、一个来源（本地音乐，槽位 "1"）。
/// 内容与播放接口见 Router+Content、Router+Playback；本服务器不提供的功能见 Router+Unsupported。
final class Router: Sendable {
    let accounts: AccountService
    let queries: LibraryQueries
    let streams = StreamRegistry()
    let serverVersion: String
    /// 把新的密钥表装进加密端口（登录登记新设备后调用）。
    let installKeys: @Sendable ([TransportSecurity.KeyEntry]) async throws -> Void
    private let loginSerial = AsyncSerial()

    init(accounts: AccountService, queries: LibraryQueries, serverVersion: String,
         installKeys: @escaping @Sendable ([TransportSecurity.KeyEntry]) async throws -> Void) {
        self.accounts = accounts
        self.queries = queries
        self.serverVersion = serverVersion
        self.installKeys = installKeys
    }

    /// 每个请求记一行：谁、方法、路径（不带查询参数）、音频范围、状态、耗时。
    func handle(identity: String, request: HTTPRequest) async -> SecureServer.Response {
        let begin = ContinuousClock.now
        let response = await route(identity: identity, request)
        let ms = Int((ContinuousClock.now - begin) / .milliseconds(1))
        let status: Int = switch response {
        case .full(let head, _): head.status
        case .stream(let head, _): head.status
        }
        let who = identity.hasPrefix("u:") ? "密码登录" : "设备 \(identity.dropFirst(2).prefix(8))"
        let range = request.headers["range"].map { " \($0)" } ?? ""
        serverLog("请求", "\(who) \(request.method) \(request.path)\(range) → \(status)，\(ms) 毫秒")
        return response
    }

    private func route(identity: String, _ request: HTTPRequest) async -> SecureServer.Response {
        guard let caller = await accounts.identify(identity) else {
            return Responses.error(401, .notLoggedIn, "身份无效，请重新登录服务器")
        }
        // 密码身份只能用来换取设备密钥
        guard case .device = caller else {
            guard request.method == "POST", request.path == API.Path.login else {
                return Responses.error(403, .notLoggedIn, "请先完成登录")
            }
            return await login(request)
        }
        let user = await accounts.user
        do {
            if let response = try await content(request, user: user) { return response }
            if let response = try await playback(request, user: user) { return response }
            if let response = unsupported(request) { return response }
            return Responses.error(404, .resourceRemoved, "没有这个接口")
        } catch let e as MusicError {
            serverLog("请求", "失败 \(request.path)：\(e.userMessage)")
            return Responses.error(Responses.status(for: e.category), e.category, e.userMessage)
        } catch let e as API.ErrorResponse {
            return Responses.error(400, e.category, e.message)
        } catch is DecodingError {
            return Responses.error(400, .parseFailure, "请求格式不正确")
        } catch {
            serverLog("请求", "出错 \(request.path)：\(error)")
            return Responses.error(500, .parseFailure, "服务器处理请求时出错")
        }
    }

    // MARK: 登录

    /// 登记设备、保存、把新密钥表装进加密端口，都成功了才回复设备密钥：
    /// 客户端拿到密钥会立刻用它连接，密钥表还没换好就会被当成“已吊销”。
    private func login(_ request: HTTPRequest) async -> SecureServer.Response {
        let name = (try? API.decoder.decode(API.LoginRequest.self, from: request.body))?.deviceName ?? ""
        let accounts = accounts, installKeys = installKeys
        do {
            let device = try await loginSerial.run {
                let device = try await accounts.register(name: name)
                do {
                    try await installKeys(await accounts.keyTable())
                } catch {
                    await accounts.remove(id: device.id)
                    throw error
                }
                return device
            }
            return Responses.json(API.LoginResponse(user: await accounts.user, deviceID: device.id, deviceKey: device.key))
        } catch {
            serverLog("账号", "登记设备失败：\(error)")
            return Responses.error(500, .disk, "登记设备失败，请稍后再试")
        }
    }

    // MARK: 参数

    /// 来源参数：只认本服务器唯一的来源。
    func checkSource(_ raw: String?) throws {
        guard let raw, !raw.isEmpty else { throw Self.badRequest }
        guard raw == MusicLibraryService.sourceID.rawValue else {
            throw MusicError(.resourceRemoved, userMessage: "服务器上没有这个来源")
        }
    }

    func requiredID(_ request: HTTPRequest) throws -> String {
        guard let id = request.query["id"], !id.isEmpty else { throw Self.badRequest }
        return id
    }

    static var badRequest: API.ErrorResponse { .init(category: .parseFailure, message: "请求参数不完整") }

    static func page<T: Codable & Sendable>(_ items: [T]) -> SecureServer.Response {
        Responses.json(API.PageResponse(items: items, nextCursor: nil, total: items.count))
    }
}
