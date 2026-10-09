import Foundation
import Network

public enum TransportError: Error, Sendable, Equatable {
    case handshakeFailed(String)   // 对方不可达、连接被重置（例如暂时被限速）等网络层失败
    /// 服务器明确拒绝了密钥：身份未登记（设备被吊销、密码登录被暂停）或密钥不对（密码错误）。
    case rejected(String)
    case insecureSuite             // 协商出的不是要求的加密套件
    case timeout
    case closed
    case malformed
}

extension TransportError {
    /// 区分“服务器拒绝了密钥”与网络层失败：只有加密层报“未知的预共享密钥身份”(-9864) 或“校验码不对”(-9820) 才算拒绝。
    static func classify(_ e: NWError) -> TransportError {
        if case .tls(let status) = e, status == -9864 || status == -9820 { return .rejected("\(e)") }
        return .handshakeFailed("\(e)")
    }
}

/// 把 NWConnection 的回调包装成 async 接口。
final class ConnectionIO: @unchecked Sendable {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var finished = false
    private let clientMode: Bool
    private let clock: TransportClock
    private let hooks: ClientIOHooks?
    private var pending: [UUID: @Sendable (any Error) -> Void] = [:]
    private var terminal: (any Error)?
    private var clientReadEnded = false
    /// 客户端：握手已完成；有一次 receive 正在等网络回调；连接失败后正在把 Network 框架里已收下的数据取出来。
    private var clientReady = false
    private var receiving = false
    private var salvaging = false
    private var salvaged: [Data] = []
    private var salvageWaiters: [UUID: @Sendable () -> Void] = [:]
    // 测试在请求发出前安装，精确复现 pending 与残余等待之间的竞争。
    var residualWaitRegistered: (@Sendable () -> Void)?
    private var salvageTimer: Task<Void, Never>?

    init(_ connection: NWConnection, queue: DispatchQueue, clientMode: Bool = false, clock: TransportClock = .continuous, hooks: ClientIOHooks? = nil) {
        self.connection = connection
        self.queue = queue
        self.clientMode = clientMode
        self.clock = clock
        self.hooks = hooks
    }

    /// 启动并等待握手完成（客户端使用）。
    func start(timeout: Duration) async throws {
        if clientMode {
            try await operation(timeout: timeout) { [self] (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
                // 握手的等待只能完成一次；连接生命周期不能跟着这个等待结束。
                // 用弱引用避免 connection → handler → IO → connection 环。
                connection.stateUpdateHandler = { [weak self] state in
                    self?.clientStateChanged(state)
                    if case .ready = state { done(.success(())) }
                }
                if let hooks { hooks.start(done); return }
                connection.start(queue: queue)
            }
            guard hooks != nil || TransportSecurity.hasRequiredSuite(connection) else { cancel(); throw TransportError.insecureSuite }
            return
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.withLock { readyContinuation = c }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.resumeReady(nil)
                case .failed(let e), .waiting(let e): self?.resumeReady(TransportError.classify(e))
                case .cancelled: self?.resumeReady(TransportError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { [weak self] in
                self?.resumeReady(TransportError.timeout)
            }
        }
        guard TransportSecurity.hasRequiredSuite(connection) else {
            connection.cancel()
            throw TransportError.insecureSuite
        }
    }

    private func resumeReady(_ error: Error?) {
        let c: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { readyContinuation = nil }
            return readyContinuation
        }
        guard let c else { return }
        if let error { connection.cancel(); c.resume(throwing: error) } else { c.resume() }
    }

    /// 读取下一段数据；对方关闭且无更多数据时返回 nil。
    func receive(timeout: Duration? = nil) async throws -> Data? {
        if clientMode {
            try Task.checkCancellation()
            let deadline = timeout.map { clock.now() + $0 }
            // 连接失败前已经到达本机的数据先交出去（见 salvage），取完再报失败
            while true {
                let (chunk, wait) = lock.withLock { () -> (Data?, Bool) in
                    if !salvaged.isEmpty { return (salvaged.removeFirst(), false) }
                    return (nil, salvaging)
                }
                if let chunk { return chunk }
                guard wait else { break }
                let id = UUID()
                defer { _ = lock.withLock { salvageWaiters.removeValue(forKey: id) } }
                do {
                    try await operation(timeout: deadline.map { $0 - clock.now() }) { [self] (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
                        residualWaitRegistered?()
                        let ready = lock.withLock { () -> Bool in
                            if salvaging, terminal == nil { salvageWaiters[id] = { done(.success(())) }; return false }
                            return true
                        }
                        if ready { done(.success(())) }
                    }
                } catch {
                    // 失败可能发生在 pending 已登记、残余等待尚未登记的窗口。
                    // 网络终止不能抢走已经收下的字节；取消和期限仍立即生效。
                    if Task.isCancelled || error is CancellationError || error as? TransportError == .timeout { throw error }
                    if lock.withLock({ !salvaged.isEmpty }) { continue }
                    throw error
                }

            }
            if lock.withLock({ clientReadEnded }) { return nil }
            return try await operation(timeout: deadline.map { $0 - clock.now() }) { [self] done in
                if let hooks {
                    hooks.receive { result in
                        switch result {
                        case .success(let data): self.clientReceived(data, complete: data == nil, error: nil, done: done)
                        case .failure(let error): done(.failure(error))
                        }
                    }
                    return
                }
                lock.withLock { receiving = true }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    self.lock.withLock { self.receiving = false }
                    self.clientReceived(data, complete: complete, error: error.map(TransportError.classify), done: done)
                }
            }
        }
        return try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty { c.resume(returning: data) }
                else if isComplete { c.resume(returning: nil) }
                else if let error { c.resume(throwing: TransportError.handshakeFailed("\(error)")) }
                else { c.resume(returning: nil) }
            }
        }
    }

    func send(_ data: Data, timeout: Duration? = nil) async throws {
        if clientMode {
            try await operation(timeout: timeout) { [connection, hooks] (done: @escaping @Sendable (Result<Void, Error>) -> Void) in
                if let hooks { hooks.send(data, done); return }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { done(.failure(TransportError.classify(error))) } else { done(.success(())) }
                })
            }
            return
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: TransportError.handshakeFailed("\(error)")) } else { c.resume() }
            })
        }
    }

    /// 发送结束标志并关闭写方向。
    func finish() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in c.resume() })
        }
    }

    func cancel() {
        if clientMode { cancelClient(CancellationError()) }
        else { connection.cancel() }
    }

    /// 持续监听客户端连接，消费者没有挂起的 next() 也要释放失败的连接。
    /// 服务端仍使用原来的握手回调，不经过这里。
    func clientStateChanged(_ state: NWConnection.State) {
        guard clientMode else { return }
        switch state {
        case .ready: lock.withLock { clientReady = true }
        case .failed(let error):
            // 握手后连接失败（例如服务器停止时重置）：正有读取在等的，由那次读取先交数据再报错；
            // 没人在读的，先把 Network 框架里已收下的数据取出来再关连接，免得丢掉对方失败前已经送到的数据，
            // 也不让一个没人读的失败连接一直占着。
            let mode = lock.withLock { () -> Int in
                guard terminal == nil, clientReady else { return 0 }   // 握手前失败：直接关
                if receiving || salvaging { return 1 }                  // 交给正在进行的读取
                salvaging = true
                return 2
            }
            if mode == 0 { cancelClient(TransportError.classify(error)) }
            else if mode == 2 {
                let deadline = clock.now() + .seconds(10)
                let timer = Task { [weak self, clock] in
                    do { while clock.now() < deadline { try await clock.sleep(deadline - clock.now()) } } catch { return }
                    self?.cancelClient(TransportError.timeout)
                }
                let installed = lock.withLock { () -> Bool in
                    guard terminal == nil else { return false }
                    salvageTimer = timer; return true
                }
                if !installed { timer.cancel() }
                else { salvage(after: TransportError.classify(error)) }
            }
        case .waiting(let error): cancelClient(TransportError.classify(error))
        case .cancelled: cancelClient(TransportError.closed)
        default: break
        }
    }

    /// 连接已失败、没人在读：把 Network 框架已收下的数据读进内存（量以它已经缓冲的为限，连接已断不会再多），
    /// 读到出错或结束就关连接；之后 receive 先交这些数据，再报失败。
    private func salvage(after failure: any Error) {
        let consume: @Sendable (Data?, Bool, (any Error)?) -> Void = { [self] data, complete, error in
            let more = lock.withLock { () -> Bool in
                guard terminal == nil else { return false }
                if let data, !data.isEmpty { salvaged.append(data) }
                return !complete && error == nil && (data?.isEmpty == false)
            }
            if more { salvage(after: failure); return }
            let waits = lock.withLock { () -> [@Sendable () -> Void] in
                salvaging = false
                defer { salvageWaiters.removeAll() }
                return Array(salvageWaiters.values)
            }
            // 先让取残余数据的等待成功，下一轮 receive 先交已有字节，再报终止错误。
            waits.forEach { $0() }
            cancelClient(failure)
        }
        if let hooks {
            hooks.receive { result in
                switch result {
                case .success(let data): consume(data, data == nil, nil)
                case .failure(let error): consume(nil, false, error)
                }
            }
        } else {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                consume(data, complete, error.map(TransportError.classify))
            }
        }
    }

    /// EOF 可以和最后一块数据同时到达：先交付数据，再独立收尾，后续读取仍返回正常 EOF。
    func clientReceived(_ data: Data?, complete: Bool, error: (any Error)?,
        done: @escaping @Sendable (Result<Data?, Error>) -> Void) {
        // 先登记 EOF，避免恢复消费者后它立即再读而错过结束状态。
        if complete && error == nil { lock.withLock { if terminal == nil { clientReadEnded = true } } }
        if let data, !data.isEmpty { done(.success(data)) }
        else if let error { done(.failure(error)) }
        else if complete { done(.success(nil)) }
        else { done(.failure(TransportError.closed)) }
        if let error { cancelClient(error) }
        else if complete { cancelClient(TransportError.closed) }
    }

    private func cancelClient(_ error: any Error) {
        let taken = lock.withLock { () -> ([@Sendable (any Error) -> Void], [@Sendable () -> Void], Task<Void, Never>?)? in
            // 包括取消引发的 .cancelled 回调在内，只有第一个终止事件执行物理关闭。
            guard terminal == nil else { return nil }
            terminal = error
            let waits = Array(pending.values)
            pending.removeAll()
            let salvage = Array(salvageWaiters.values)
            salvageWaiters.removeAll(); salvaging = false
            let timer = salvageTimer; salvageTimer = nil
            return (waits, salvage, timer)
        }
        guard let taken else { return }
        taken.2?.cancel()
        for resume in taken.0 { resume(error) }
        taken.1.forEach { $0() }
        hooks?.cancel()
        connection.cancel()
    }

    var clientWaitCount: Int { lock.withLock { pending.count } }

    /// 客户端等待的共同出口：取消可早于登记，迟到的网络回调或计时器不能再次恢复。
    func operation<T: Sendable>(timeout: Duration?,
        begin: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let deadline = timeout.map { clock.now() + max(.zero, $0) }
        let id = UUID()
        let wait = TransportWait<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let deadline, clock.now() >= deadline { cancelClient(TransportError.timeout); throw TransportError.timeout }
            return try await withCheckedThrowingContinuation { continuation in
                wait.install(continuation)
                let error = lock.withLock { () -> (any Error)? in
                    if let terminal { return terminal }
                    pending[id] = { wait.complete(.failure($0)) }
                    return nil
                }
                if let error { wait.complete(.failure(error)); return }
                if let deadline {
                    let timer = Task { [self, clock] in
                        do { while clock.now() < deadline { try await clock.sleep(deadline - clock.now()) } } catch { return }
                        if wait.complete(.failure(TransportError.timeout)) { cancelClient(TransportError.timeout) }
                    }
                    wait.installTimer(timer)
                }
                if wait.isFinished { return }
                begin { [weak self, clock] result in
                    let result: Result<T, Error> = deadline.map { clock.now() >= $0 } == true ? .failure(TransportError.timeout) : result
                    if case .failure(let error) = result { self?.cancelClient(error) }
                    if wait.complete(result) { self?.lock.withLock { _ = self?.pending.removeValue(forKey: id) } }
                }
            }
        } onCancel: { [self] in cancelClient(CancellationError()) }
    }
}

/// 可注入时钟；连接的等待不依赖墙钟，测试无需实际等十秒。
public struct TransportClock: Sendable {
    public let now: @Sendable () -> Duration
    public let sleep: @Sendable (Duration) async throws -> Void
    public init(now: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now; self.sleep = sleep
    }
    public static var continuous: Self {
        let origin = ContinuousClock.now
        return Self(now: { ContinuousClock.now - origin }, sleep: { try await ContinuousClock().sleep(for: $0) })
    }
}

/// 所有出口（成功、失败、取消、超时）共享一把锁，不依赖 NWConnection 必须回调。
final class TransportWait<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var timer: Task<Void, Never>?
    var isFinished: Bool { lock.withLock { result != nil } }
    func install(_ value: CheckedContinuation<T, Error>) {
        let finished = lock.withLock { () -> Result<T, Error>? in
            if let result { return result }
            continuation = value; return nil
        }
        if let finished { value.resume(with: finished) }
    }
    func installTimer(_ value: Task<Void, Never>) {
        let finished = lock.withLock { () -> Bool in
            if result != nil { return true }
            timer = value; return false
        }
        if finished { value.cancel() }
    }
    @discardableResult func complete(_ value: Result<T, Error>) -> Bool {
        let taken = lock.withLock { () -> (Bool, CheckedContinuation<T, Error>?, Task<Void, Never>?) in
            guard result == nil else { return (false, nil, nil) }
            result = value
            defer { continuation = nil; timer = nil }
            return (true, continuation, timer)
        }
        taken.2?.cancel()
        taken.1?.resume(with: value)
        return taken.0
    }
}

/// 仅客户端的回调边界，测试使用不连接网络的替身；服务端从不设置它。
struct ClientIOHooks: Sendable {
    let start: @Sendable (@escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    let send: @Sendable (Data, @escaping @Sendable (Result<Void, Error>) -> Void) -> Void
    let receive: @Sendable (@escaping @Sendable (Result<Data?, Error>) -> Void) -> Void
    let cancel: @Sendable () -> Void
}
