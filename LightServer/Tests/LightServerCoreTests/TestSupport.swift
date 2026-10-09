import Foundation
import MusicAPI
import ProviderKit
import SecureTransport
@testable import LightServerCore

/// 测试用的临时环境：一个临时文件夹（数据、日志、音乐），可选地放入仓库里的示例音乐。
final class TestHome: @unchecked Sendable {
    let root: URL
    let paths: ServerPaths

    init(withSamples: Bool) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "lms-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        paths = ServerPaths(home: root)
        try paths.prepare()
        if withSamples { try SampleMusic.install(from: Self.samples, paths: paths) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 仓库里生成好的示例音乐。
    static var samples: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources/示例音乐", directoryHint: .isDirectory)
    }
}

/// 不经网络直接调接口分派的小工具。
struct Harness {
    let home: TestHome
    let router: Router
    let accounts: AccountService
    let library: MusicLibraryService
    let installed: KeyLog

    final class KeyLog: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [[TransportSecurity.KeyEntry]] = []
        func append(_ t: [TransportSecurity.KeyEntry]) { lock.withLock { tables.append(t) } }
        var last: [TransportSecurity.KeyEntry]? { lock.withLock { tables.last } }
        var count: Int { lock.withLock { tables.count } }
    }

    static func make(withSamples: Bool = true, failInstall: Bool = false) async throws -> Harness {
        let home = try TestHome(withSamples: withSamples)
        let paths = home.paths
        let accounts = try await Task.detached { try AccountService(paths: paths) }.value
        let library = MusicLibraryService(root: paths.music, indexFile: paths.libraryIndexFile)
        await library.rescan()
        let log = KeyLog()
        let router = Router(accounts: accounts, queries: LibraryQueries(service: library), serverVersion: "测试") { keys in
            if failInstall { throw TransportError.closed }
            log.append(keys)
        }
        return Harness(home: home, router: router, accounts: accounts, library: library, installed: log)
    }

    /// 用密码身份登录，返回设备身份。
    func login() async throws -> String {
        let r = await call("u:demo", "POST", API.Path.login, body: try API.encoder.encode(API.LoginRequest(deviceName: "测试")))
        guard r.status == 200 else { throw TestFailure("登录失败 \(r.status)") }
        return "d:" + (try API.decoder.decode(API.LoginResponse.self, from: r.body)).deviceID
    }

    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
        func decode<T: Decodable>(_ type: T.Type) throws -> T { try API.decoder.decode(T.self, from: body) }
    }

    func call(_ identity: String, _ method: String, _ path: String, query: [String: String] = [:],
              headers: [String: String] = [:], body: Data = Data()) async -> Reply {
        let response = await router.handle(identity: identity, request: HTTPRequest(method: method, path: path, query: query,
                                                                                     headers: headers, body: body))
        switch response {
        case .full(let head, let data):
            return Reply(status: head.status, headers: head.headers, body: data)
        case .stream(let head, let stream):
            var data = Data()
            do { for try await chunk in stream { data.append(chunk) } } catch {}
            return Reply(status: head.status, headers: head.headers, body: data)
        }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// 等某个条件成立，最多等 `seconds` 秒。
func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}
