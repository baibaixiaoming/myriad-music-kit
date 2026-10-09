import Foundation
import Network
import Testing
@testable import SecureTransport

extension TransportServerSuites {
@Suite(.serialized) struct SecureTransportTests {
    /// 回显服务：返回对方身份；/stream 分 3 段推送；/echo 原样返回请求体。
    func makeServer() -> SecureServer {
        SecureServer(port: 0) { peer, request in
            switch request.path {
            case "/whoami":
                return .full(HTTPResponseHead(status: 200), Data(peer.identity.utf8))
            case "/echo":
                return .full(HTTPResponseHead(status: 200), request.body)
            case "/stream":
                let stream = AsyncThrowingStream<Data, Error> { c in
                    Task {
                        for i in 1...3 {
                            c.yield(Data("data: 第\(i)段\n\n".utf8))
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        c.finish()
                    }
                }
                return .stream(HTTPResponseHead(status: 200, headers: ["content-type": "text/event-stream"]), stream)
            default:
                return .status(404)
            }
        }
    }

    let alice = TransportSecurity.passwordEntry(username: "Alice", password: "correct horse battery")
    let device = TransportSecurity.KeyEntry(identity: "d:device-1", key: TransportSecurity.randomKey())

    /// 播放时客户端会频繁打开又主动关闭连接（切歌、跳转），这不能被当成攻击而封掉整台设备。
    @Test func clientCancelledConnectionsDoNotTriggerBlocking() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        for _ in 0..<15 {
            let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                 using: TransportSecurity.clientParameters(device))
            c.start(queue: .global())
            try await Task.sleep(for: .milliseconds(30))
            c.cancel()
        }
        try await Task.sleep(for: .milliseconds(300))
        let client = SecureClient(host: "127.0.0.1", port: port, key: device)
        let (head, body) = try await client.send(HTTPRequest(method: "GET", path: "/whoami"))
        #expect(head.status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "d:device-1")
    }

    @Test func passwordAndDeviceKeysAuthenticate() async throws {
        let server = makeServer()
        try await server.start(keys: [alice, device])
        defer { server.stop() }
        let port = try #require(server.port)

        let viaPassword = SecureClient(host: "127.0.0.1", port: port,
            key: TransportSecurity.passwordEntry(username: " alice ", password: "correct horse battery"))
        let (h1, b1) = try await viaPassword.send(HTTPRequest(method: "GET", path: "/whoami"))
        #expect(h1.status == 200)
        #expect(String(decoding: b1, as: UTF8.self) == "u:alice")

        let viaDevice = SecureClient(host: "127.0.0.1", port: port, key: device)
        let (_, b2) = try await viaDevice.send(HTTPRequest(method: "GET", path: "/whoami"))
        #expect(String(decoding: b2, as: UTF8.self) == "d:device-1")
    }

    @Test func wrongPasswordAndUnknownIdentityAreRejected() async throws {
        let server = makeServer()
        try await server.start(keys: [alice])
        defer { server.stop() }
        let port = try #require(server.port)

        let wrong = SecureClient(host: "127.0.0.1", port: port,
            key: TransportSecurity.passwordEntry(username: "alice", password: "wrong password!!"))
        await #expect(throws: TransportError.self) { _ = try await wrong.send(HTTPRequest(method: "GET", path: "/whoami")) }

        let unknown = SecureClient(host: "127.0.0.1", port: port,
            key: TransportSecurity.KeyEntry(identity: "d:nobody", key: TransportSecurity.randomKey()))
        await #expect(throws: TransportError.self) { _ = try await unknown.send(HTTPRequest(method: "GET", path: "/whoami")) }
    }

    /// 同一地址连续失败到上限后被拒绝，连正确的设备密钥也进不来；并报告安全事件。
    @Test func repeatedFailuresBlockAddress() async throws {
        let saved = SecureServer.failureLimit
        SecureServer.failureLimit = 3
        defer { SecureServer.failureLimit = saved }
        final class Events: @unchecked Sendable { var list: [String] = [] }
        let events = Events()
        let server = makeServer()
        server.onSecurityEvent = { events.list.append($0) }
        try await server.start(keys: [alice, device])
        defer { server.stop() }
        let port = try #require(server.port)
        for _ in 0..<3 {
            let wrong = SecureClient(host: "127.0.0.1", port: port,
                key: TransportSecurity.KeyEntry(identity: "d:device-1", key: TransportSecurity.randomKey()))
            _ = try? await wrong.send(HTTPRequest(method: "GET", path: "/whoami"))
        }
        let good = SecureClient(host: "127.0.0.1", port: port, key: device)
        await #expect(throws: (any Error).self) { _ = try await good.send(HTTPRequest(method: "GET", path: "/whoami")) }
        #expect(events.list.contains { $0.contains("127.0.0.1") && $0.contains("已拒绝") })
    }

    /// 同一用户名的密码登录次数到上限后暂停（即使密码正确）；已登录设备的密钥照常可用。
    @Test func passwordAttemptsLimitedPerAccount() async throws {
        let savedLimit = SecureServer.passwordAttemptLimit, savedFailures = SecureServer.failureLimit
        SecureServer.passwordAttemptLimit = 3
        SecureServer.failureLimit = 100
        defer { SecureServer.passwordAttemptLimit = savedLimit; SecureServer.failureLimit = savedFailures }
        final class Events: @unchecked Sendable { var list: [String] = [] }
        let events = Events()
        let server = makeServer()
        server.onSecurityEvent = { events.list.append($0) }
        try await server.start(keys: [alice, device])
        defer { server.stop() }
        let port = try #require(server.port)
        for _ in 0..<3 {
            let wrong = SecureClient(host: "127.0.0.1", port: port,
                key: TransportSecurity.passwordEntry(username: "alice", password: "guess-\(UUID())"))
            _ = try? await wrong.send(HTTPRequest(method: "GET", path: "/whoami"))
        }
        let right = SecureClient(host: "127.0.0.1", port: port,
            key: TransportSecurity.passwordEntry(username: "alice", password: "correct horse battery"))
        await #expect(throws: (any Error).self) { _ = try await right.send(HTTPRequest(method: "GET", path: "/whoami")) }
        let viaDevice = SecureClient(host: "127.0.0.1", port: port, key: device)
        let (h, b) = try await viaDevice.send(HTTPRequest(method: "GET", path: "/whoami"))
        #expect(h.status == 200 && String(decoding: b, as: UTF8.self) == "d:device-1")
        #expect(events.list.contains { $0.contains("alice") && $0.contains("暂停") })
    }

    /// IPv6 按 /64 网段计数，IPv4 与 IPv4 映射地址按单个地址。
    @Test func limitKeyGroupsIPv6Networks() {
        #expect(SecureServer.limitKey("2001:db8:1:2:aaaa::1") == SecureServer.limitKey("2001:db8:1:2:bbbb::9"))
        #expect(SecureServer.limitKey("2001:db8:1:2::1") != SecureServer.limitKey("2001:db8:1:3::1"))
        #expect(SecureServer.limitKey("192.168.1.5") == "192.168.1.5")
        #expect(SecureServer.limitKey("::ffff:192.168.1.5") == "192.168.1.5")
        #expect(SecureServer.limitKey("fe80::1%en0") == SecureServer.limitKey("fe80::2%en0"))
    }

    @Test func streamArrivesInParts() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let client = SecureClient(host: "127.0.0.1", port: try #require(server.port), key: device)
        let (head, stream) = try await client.open(HTTPRequest(method: "GET", path: "/stream"))
        #expect(head.headers["content-type"] == "text/event-stream")
        var text = ""
        for try await chunk in stream { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text == "data: 第1段\n\ndata: 第2段\n\ndata: 第3段\n\n")
    }

    @Test func keyUpdateKeepsSamePort() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        let second = TransportSecurity.KeyEntry(identity: "d:device-2", key: TransportSecurity.randomKey())
        try await server.start(keys: [device, second])
        #expect(server.port == port)
        let (_, body) = try await SecureClient(host: "127.0.0.1", port: port, key: second)
            .send(HTTPRequest(method: "GET", path: "/whoami"))
        #expect(String(decoding: body, as: UTF8.self) == "d:device-2")
        // 吊销：去掉 device-2 后无法再连
        try await server.start(keys: [device])
        await #expect(throws: TransportError.self) {
            _ = try await SecureClient(host: "127.0.0.1", port: port, key: second).send(HTTPRequest(method: "GET", path: "/whoami"))
        }
    }

    @Test func largeBodyRoundTrip() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
        let (head, body) = try await SecureClient(host: "127.0.0.1", port: try #require(server.port), key: device)
            .send(HTTPRequest(method: "POST", path: "/echo", body: payload))
        #expect(head.status == 200)
        #expect(body == payload)
    }

    @Test func requestQueryRoundTrip() throws {
        let r = HTTPRequest(method: "GET", path: "/v1/search", query: ["q": "孤勇者 陈奕迅", "kind": "track"])
        let text = String(decoding: r.serialized(), as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let parsed = try HTTPParser.request(lines: Array(lines.prefix(while: { !$0.isEmpty })))
        #expect(parsed.path == "/v1/search")
        #expect(parsed.query["q"] == "孤勇者 陈奕迅")
    }

    /// 表单里出现未编码的中文、残缺的百分号也不能让服务端崩溃（曾经崩溃过）。
    @Test func formParsingToleratesRawAndMalformedInput() {
        func form(_ body: String) -> [String: String] {
            HTTPRequest(method: "POST", path: "/x", body: Data(body.utf8)).form
        }
        #expect(form("username=tester&displayName=测试&password=a+b%21") ==
                ["username": "tester", "displayName": "测试", "password": "a b!"])
        #expect(form("a=%E6%B5%8B%E8%AF%95&b=%ZZ&c&=x")["a"] == "测试")
        #expect(form("a=%E6%B5%8B%E8%AF%95&b=%ZZ&c&=x")["b"] == "%ZZ")
        #expect(form("a=%E6%B5%8B%E8%AF%95&b=%ZZ&c&=x")["c"] == "")
    }
}
}
