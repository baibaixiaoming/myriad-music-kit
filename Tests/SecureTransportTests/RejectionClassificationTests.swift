import Foundation
import Network
import Testing
@testable import SecureTransport

/// 客户端能区分“服务器拒绝密钥”（设备被吊销、密码错）与网络层失败（连不上、被暂时限速）：
/// 只有前者才可以让客户端自动退出，没网或被限速时绝不能退出。
extension TransportServerSuites {
@Suite(.serialized) struct RejectionClassificationTests {
    @Test func rejectionIsDistinguishedFromNetworkFailures() async throws {
        let device = TransportSecurity.KeyEntry(identity: "d:dev", key: TransportSecurity.randomKey())
        let server = SecureServer(port: 0) { _, _ in .status(200) }
        try await server.start(keys: [device])
        let port = try #require(server.port)
        func attempt(_ key: TransportSecurity.KeyEntry) async -> TransportError? {
            do { _ = try await SecureClient(host: "127.0.0.1", port: port, key: key).send(HTTPRequest(method: "GET", path: "/")); return nil }
            catch { return error as? TransportError }
        }
        func isRejected(_ e: TransportError?) -> Bool { if case .rejected = e { true } else { false } }
        func isNetwork(_ e: TransportError?) -> Bool { if case .handshakeFailed = e { true } else { false } }
        #expect(await attempt(device) == nil)
        #expect(isRejected(await attempt(.init(identity: "d:revoked", key: TransportSecurity.randomKey()))))   // 被吊销
        #expect(isRejected(await attempt(.init(identity: "d:dev", key: TransportSecurity.randomKey()))))       // 密钥不对
        let saved = SecureServer.failureLimit
        SecureServer.failureLimit = 2
        defer { SecureServer.failureLimit = saved }
        #expect(isNetwork(await attempt(device)))                                                             // 被暂时限速
        server.stop()
        try await Task.sleep(for: .milliseconds(200))
        #expect(isNetwork(await attempt(device)))                                                             // 服务器没开
    }
}
}
