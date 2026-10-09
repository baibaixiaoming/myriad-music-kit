import Foundation
import Testing
@testable import SecureTransport

extension TransportServerSuites {
@Suite(.serialized) struct ClientConnectionLifetimeTests {
    /// 公共客户端路径：流和迭代器一直存活，服务器停止后不再调用 next()。
    /// 和前门测试串行，避免全进程 FD 计数被其他本机服务器干扰。
    @Test func retainedIdleBodyReleasesConnectionWhenServerStops() async throws {
        let fixture = KernelFrontDoorTests()
        do {
            let warm = fixture.makeServer()
            try await warm.start(keys: [fixture.device])
            defer { warm.stop() }
            _ = try await SecureClient(host: "127.0.0.1", port: try #require(warm.port), key: fixture.device)
                .send(HTTPRequest(method: "GET", path: "/host"))
        }
        try await Task.sleep(for: .milliseconds(300))
        let fdBefore = fixture.openFDCount()
        #expect(fdBefore >= 0)
        let server = fixture.makeServer()
        try await server.start(keys: [fixture.device])
        defer { server.stop() }
        let client = SecureClient(host: "127.0.0.1", port: try #require(server.port), key: fixture.device)
        let (_, retained) = try await client.open(HTTPRequest(method: "GET", path: "/big"))
        var iterator = retained.makeAsyncIterator()
        _ = try #require(try await iterator.next())
        server.stop()
        #expect(await fixture.eventually { fixture.openFDCount() <= fdBefore })
        // 用最后的存活检查排除提前析构流或迭代器替我们关闭连接。
        withExtendedLifetime(retained) {}
        withExtendedLifetime(iterator) {}
    }

    /// 服务器停止前已经送到客户端的数据，停止后客户端照样能完整读出；之后以错误结束（不是正常结束），
    /// 使用方能分辨出这是中断而不是整首读完。服务器停止时对外连接用重置关闭（先等最多 200 毫秒让已发出的数据被确认）：
    /// 到那时还没送出的数据会被丢弃，这是停止时的预期（这里服务器只发一段前缀，停止前已全部送到）。
    @Test func bytesDeliveredBeforeStopSurviveAbortiveClose() async throws {
        let prefix = Data((0..<(100 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ $0 >> 8) })
        let device = TransportSecurity.KeyEntry(identity: "d:device-1", key: TransportSecurity.randomKey())
        let server = SecureServer(port: 0) { _, _ in
            // 先送一段前缀，然后不再发、也不结束，直到服务器停止
            let (stream, c) = AsyncThrowingStream<Data, Error>.makeStream()
            c.yield(prefix)
            return .stream(HTTPResponseHead(status: 200), stream)
        }
        try await server.start(keys: [device])
        defer { server.stop() }
        let client = SecureClient(host: "127.0.0.1", port: try #require(server.port), key: device)
        let (_, body) = try await client.open(HTTPRequest(method: "GET", path: "/prefix"))
        var iterator = body.makeAsyncIterator()
        var received = try #require(try await iterator.next())
        // 等前缀全部到达客户端一侧，再停服务器
        try await Task.sleep(for: .milliseconds(300))
        server.stop()
        var endedWithError = false
        do {
            while received.count < prefix.count, let chunk = try await iterator.next() { received.append(chunk) }
            _ = try await iterator.next()
        } catch {
            endedWithError = true
        }
        #expect(received == prefix)
        #expect(endedWithError)
    }
}
}
