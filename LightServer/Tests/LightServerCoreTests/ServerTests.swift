import Foundation
import MusicAPI
import ProviderKit
import SecureTransport
import Testing
@testable import LightServerCore

/// 整台服务器：账号文件、真实加密端口上的登录与读取、端口被占用时的说明。
@Suite(.serialized) struct ServerTests {
    @Test func accountIsGeneratedOnceWithPrivateFile() throws {
        let home = try TestHome(withSamples: false)
        let a = try Account.loadOrCreate(at: home.paths.accountFile)
        #expect(a.username == "demo")
        #expect(a.password.count == 14 && a.password.count >= TransportSecurity.minimumPasswordLength)
        #expect(a.password.wholeMatch(of: /[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}/) != nil)
        let b = try Account.loadOrCreate(at: home.paths.accountFile)
        #expect(a == b)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.paths.accountFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let dir = try FileManager.default.attributesOfItem(atPath: home.paths.support.path(percentEncoded: false))
        #expect((dir[.posixPermissions] as? Int) == 0o700)
        // 坏掉的文件：留底后重新生成
        try Data("坏了".utf8).write(to: home.paths.accountFile)
        let c = try Account.loadOrCreate(at: home.paths.accountFile)
        #expect(c.password != a.password)
        let names = try FileManager.default.contentsOfDirectory(atPath: home.paths.support.path(percentEncoded: false))
        #expect(names.contains { $0.hasPrefix("account.json.damaged-") })
    }

    @Test func loginOverEncryptedPortThenUseDeviceKey() async throws {
        let home = try TestHome(withSamples: true)
        let server = LightServer(paths: home.paths, port: 0, serverVersion: "测试")
        await server.start()
        defer { server.stop() }
        guard case .running = server.state, let port = server.port, let account = server.account else {
            Issue.record("没有启动：\(server.state)"); return
        }
        // 密码登录换设备密钥，马上用设备密钥连（密钥表必须已经换好）
        let first = SecureClient(host: "127.0.0.1", port: port, key: TransportSecurity.passwordEntry(username: account.username, password: account.password))
        let (head, body) = try await first.send(HTTPRequest(method: "POST", path: API.Path.login,
                                                            body: try API.encoder.encode(API.LoginRequest(deviceName: "测试"))))
        #expect(head.status == 200)
        let login = try API.decoder.decode(API.LoginResponse.self, from: body)
        let device = SecureClient(host: "127.0.0.1", port: port,
                                  key: .init(identity: "d:\(login.deviceID)", key: try #require(Data(base64Encoded: login.deviceKey))))
        let (sh, _) = try await device.send(HTTPRequest(method: "GET", path: API.Path.server))
        #expect(sh.status == 200)
        // 等首次扫描结束，再完整读一首
        await server.rescanNow()
        let (_, lb) = try await device.send(HTTPRequest(method: "GET", path: API.Path.search, query: ["platform": "1", "q": "零点", "kind": "track"]))
        guard case .track(let t) = try #require(try API.decoder.decode(API.PageResponse<SearchItem>.self, from: lb).items.first) else { return }
        let (_, ob) = try await device.send(HTTPRequest(method: "POST", path: API.Path.streamOpen,
            body: try API.encoder.encode(API.StreamOpenRequest(platform: t.ref.platform, id: t.ref.platformID, level: nil))))
        let opened = try API.decoder.decode(API.StreamOpenResponse.self, from: ob)
        let (rh, data) = try await device.send(HTTPRequest(method: "GET", path: API.Path.streamData + opened.streamID, headers: ["range": "bytes=0-"]))
        #expect(rh.status == 206)
        let original = try Data(contentsOf: home.paths.music.appending(path: t.ref.platformID))
        #expect(data == original)
        // 错误的密码被拒
        let wrong = SecureClient(host: "127.0.0.1", port: port, key: TransportSecurity.passwordEntry(username: "demo", password: "wrong-password-x"))
        await #expect(throws: TransportError.self) {
            _ = try await wrong.send(HTTPRequest(method: "POST", path: API.Path.login, body: Data("{}".utf8)))
        }
    }

    @Test func portInUseIsReported() async throws {
        let home = try TestHome(withSamples: false)
        let a = LightServer(paths: home.paths, port: 0, serverVersion: "测试")
        await a.start()
        defer { a.stop() }
        let port = try #require(a.port)
        let other = try TestHome(withSamples: false)
        let b = LightServer(paths: other.paths, port: port, serverVersion: "测试")
        await b.start()
        guard case .failed(let reason) = b.state else { Issue.record("应当启动失败：\(b.state)"); b.stop(); return }
        #expect(reason.contains("端口 \(port) 已被占用"))
        // 端口空出来后可以重试
        a.stop()
        await b.start()
        if case .running = b.state {} else { Issue.record("重试应当成功：\(b.state)") }
        b.stop()
    }
}
