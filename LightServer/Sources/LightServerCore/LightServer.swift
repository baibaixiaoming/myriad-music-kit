import Foundation
import SecureTransport

/// 组装：账号、音乐库、文件夹监听、接口分派、加密端口。菜单栏应用只和它打交道。
/// 回调可能在任意线程上调用，界面要自己切回主线程。
public final class LightServer: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(String)
    }

    public static let defaultPort: UInt16 = 7710

    public let paths: ServerPaths
    public let requestedPort: UInt16
    public let serverVersion: String

    private let lock = NSLock()
    private var _state: State = .stopped
    private var _account: Account?
    private var _songCount = 0
    /// 每次 start / stop 加一：启动途中被停止的，作废这次启动。
    private var generation = 0
    private var secure: SecureServer?
    private var watcher: FolderWatcher?
    private var router: Router?
    private lazy var library = MusicLibraryService(root: paths.music, indexFile: paths.libraryIndexFile)

    private var stateHandler: (@Sendable (State) -> Void)?
    private var libraryHandler: (@Sendable (Int) -> Void)?

    public init(paths: ServerPaths = .standard(), port: UInt16 = defaultPort, serverVersion: String = "1.0") {
        self.paths = paths
        requestedPort = port
        self.serverVersion = serverVersion
    }

    public var state: State { lock.withLock { _state } }
    public var account: Account? { lock.withLock { _account } }
    public var songCount: Int { lock.withLock { _songCount } }
    /// 实际监听的端口（请求端口为 0 时由系统分配，测试用）。
    public var port: UInt16? { lock.withLock { secure?.port } }

    public func setStateHandler(_ handler: (@Sendable (State) -> Void)?) { lock.withLock { stateHandler = handler } }
    public func setLibraryHandler(_ handler: (@Sendable (Int) -> Void)?) { lock.withLock { libraryHandler = handler } }

    // MARK: 启动与停止

    /// 启动；已在运行或正在启动时什么也不做。失败时状态为 `.failed(原因)`，可以再调一次重试。
    public func start() async {
        let myGeneration: Int? = lock.withLock {
            switch _state {
            case .starting, .running: return nil
            default:
                generation += 1
                return generation
            }
        }
        guard let myGeneration else { return }
        setState(.starting)
        var created: SecureServer?
        do {
            let musicCreated = try paths.prepare()
            ServerLog.shared.configure(directory: paths.logs)
            serverLog("启动", "轻量音乐服务器 \(serverVersion) 启动，端口 \(requestedPort)\(musicCreated ? "，已新建音乐文件夹" : "")")
            let paths = paths
            // 密码派生密钥要 60 万次运算，放到后台
            let accounts = try await Task.detached { try AccountService(paths: paths) }.value
            lock.withLock { _account = accounts.account }

            let library = lock.withLock { self.library }
            let box = ServerBox()
            let router = Router(accounts: accounts, queries: LibraryQueries(service: library), serverVersion: serverVersion) { keys in
                guard let server = box.server else { throw TransportError.closed }
                try await server.start(keys: keys)
            }
            let secure = SecureServer(port: requestedPort) { peer, request in
                await router.handle(identity: peer.identity, request: request)
            }
            secure.onSecurityEvent = { serverLog("安全", $0) }
            box.server = secure
            created = secure
            try await secure.start(keys: await accounts.keyTable())

            let watcher = FolderWatcher(folder: paths.music) { [weak self] in self?.rescan() }
            let current = lock.withLock { () -> Bool in
                guard generation == myGeneration else { return false }
                self.secure = secure
                self.router = router
                self.watcher = watcher
                return true
            }
            guard current else { secure.stop(); return }
            if !watcher.start() { serverLog("音乐库", "无法监听音乐文件夹的变化，拷入文件后需要重新启动才能看到") }
            await library.setOnChange { [weak self] count in self?.libraryChanged(count) }
            let port = secure.port ?? requestedPort
            serverLog("启动", "已在端口 \(port) 上监听")
            setState(.running(port: port), ifGeneration: myGeneration)
            rescan()
        } catch {
            created?.stop()
            let reason = Self.describe(error, port: requestedPort)
            serverLog("启动", "启动失败：\(reason)")
            setState(.failed(reason), ifGeneration: myGeneration)
        }
    }

    public func stop() {
        let (s, w): (SecureServer?, FolderWatcher?) = lock.withLock {
            generation += 1
            defer { secure = nil; watcher = nil; router = nil }
            return (secure, watcher)
        }
        w?.stop()
        s?.stop()
        setState(.stopped)
        serverLog("启动", "已停止")
        ServerLog.shared.flush()
    }

    /// 重新扫描音乐文件夹（文件夹变化时自动调用）。
    public func rescan() {
        let library = lock.withLock { self.library }
        Task { await library.rescan() }
    }

    /// 等扫描结束（测试用）。
    func rescanNow() async {
        let library = lock.withLock { self.library }
        await library.rescan()
    }

    // MARK: 示例音乐

    public var hasSampleMusic: Bool { SampleMusic.isInstalled(in: paths.music) }

    public func installSampleMusic(from bundled: URL) throws {
        try SampleMusic.install(from: bundled, paths: paths)
        rescan()
    }

    // MARK: 内部

    private func libraryChanged(_ count: Int) {
        let handler = lock.withLock { () -> (@Sendable (Int) -> Void)? in
            _songCount = count
            return libraryHandler
        }
        handler?(count)
    }

    private func setState(_ state: State, ifGeneration expected: Int? = nil) {
        let handler = lock.withLock { () -> (@Sendable (State) -> Void)?? in
            if let expected, expected != generation { return .none }
            _state = state
            return .some(stateHandler)
        }
        if case .some(let h) = handler { h?(state) }
    }

    static func describe(_ error: Error, port: UInt16) -> String {
        if let e = error as? POSIXError {
            switch e.code {
            case .EADDRINUSE: return "端口 \(port) 已被占用（可能已经开着一个轻量音乐服务器）"
            case .EACCES, .EPERM: return "没有权限使用端口 \(port)"
            default: break
            }
        }
        if let e = error as? CocoaError, let path = e.filePath { return "无法读写 \(path)" }
        return error.localizedDescription
    }
}

/// 让“换密钥表”能找到加密服务器，又不形成循环引用。
private final class ServerBox: @unchecked Sendable {
    weak var server: SecureServer?
}
