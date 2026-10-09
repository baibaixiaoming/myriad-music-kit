import Foundation
import Network

/// 加密端口的服务端。只接受 TLS 预共享密钥连接（套件 0xCCAC），每条连接都能确定对方身份。
public final class SecureServer: @unchecked Sendable {
    public struct Peer: Sendable {
        public let identity: String
        public let remoteHost: String
    }

    public enum Response: Sendable {
        case full(HTTPResponseHead, Data)
        /// 无长度、以关闭连接结束（事件流、音频转发）。
        case stream(HTTPResponseHead, AsyncThrowingStream<Data, Error>)

        public static func json(_ status: Int, _ body: Data) -> Response {
            .full(HTTPResponseHead(status: status, headers: ["content-type": "application/json; charset=utf-8"]), body)
        }
        public static func status(_ status: Int) -> Response { .full(HTTPResponseHead(status: status), Data()) }
    }

    public typealias Handler = @Sendable (Peer, HTTPRequest) async -> Response

    public static let maxRequestBody = 4 * 1024 * 1024
    /// 失败握手限速：同一来源 10 分钟内失败 10 次，则拒绝 10 分钟。IPv6 按 /64 网段算（防止在网段里换地址）。
    nonisolated(unsafe) static var failureLimit = 10
    nonisolated(unsafe) static var failureWindow: TimeInterval = 600
    /// 按账号限制密码登录：同一用户名 10 分钟内最多 10 次（无论来自哪里、成功与否），超过则暂停该用户名的密码登录。
    /// 已登录设备用各自的设备密钥连接，不受影响。
    nonisolated(unsafe) static var passwordAttemptLimit = 10
    /// 安全事件（地址被拒绝、账号密码登录暂停），由使用方写进日志。
    public var onSecurityEvent: (@Sendable (String) -> Void)?
    private var passwordAttempts: [String: [Date]] = [:]
    private var reported: Set<String> = []

    private let handler: Handler
    private let queue = DispatchQueue(label: "AccessibleMusic.SecureServer")
    private let lock = NSLock()
    private var listener: NWListener?
    private var frontDoor: KernelFrontDoor?
    private let gate = SerialGate()
    /// 每次 stop 加一；启动途中发现变了就作废。
    private var epoch = 0
    /// 内部监听的代次。
    private var nextGeneration = 0
    private var requestedPort: NWEndpoint.Port
    private var identities: [ObjectIdentifier: String] = [:]
    private var failures: [String: [Date]] = [:]

    public init(port: UInt16, handler: @escaping Handler) {
        self.requestedPort = NWEndpoint.Port(rawValue: port) ?? .any
        self.handler = handler
    }

    /// 实际对外监听的端口（请求端口为 0 时由系统分配）。
    public var port: UInt16? { lock.withLock { frontDoor?.port } }
    /// 内部加密监听的端口（只绑 127.0.0.1，测试用）。
    var internalPort: UInt16? { lock.withLock { listener?.port?.rawValue } }
    /// 当前前门（测试用：停止后仍可拿它核对线程是否都已退出）。
    var frontDoorForTesting: KernelFrontDoor? { lock.withLock { frontDoor } }

    /// 握手（认证）时限：连上后这么久还没完成加密握手就断开。
    nonisolated(unsafe) static var handshakeSeconds: Double = 10
    /// 请求时限：握手后这么久还没收齐请求头与请求体就断开。
    nonisolated(unsafe) static var requestSeconds: Double = 30

    /// 以给定的密钥表启动；已在运行时换一个新的内部监听，对外端口不变，已建立的连接不受影响。
    /// 对外端口由内核套接字接受、经本机回环转给内部监听（原因见 KernelFrontDoor）。
    /// 多次调用按顺序一个一个执行；执行中途被 `stop()` 的，新建的监听作废并抛出 `TransportError.closed`。
    public func start(keys: [TransportSecurity.KeyEntry]) async throws {
        try await gate.run { try await self.startSerially(keys: keys) }
    }

    private func startSerially(keys: [TransportSecurity.KeyEntry]) async throws {
        let (myEpoch, generation) = lock.withLock { () -> (Int, Int) in
            nextGeneration += 1
            return (epoch, nextGeneration)
        }
        let parameters = TransportSecurity.serverParameters(keys: keys, allow: { [weak self] identity in
            self?.allowIdentity(identity) ?? false
        }) { [weak self] meta, identity in
            self?.lock.withLock { self?.identities[meta] = identity }
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let new = try NWListener(using: parameters)
        new.newConnectionHandler = { [weak self] in self?.accept($0, generation: generation) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            new.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { c.resume() }
                case .failed(let e): if once.set() { c.resume(throwing: e) }
                default: break
                }
            }
            new.start(queue: queue)
        }
        guard let internalPort = new.port?.rawValue else { new.cancel(); throw TransportError.closed }

        var created: KernelFrontDoor?
        if lock.withLock({ frontDoor }) == nil {
            do {
                created = try KernelFrontDoor(port: requestedPort.rawValue) { [weak self] host in
                    !(self?.isBlocked(host) ?? true)
                }
            } catch {
                new.cancel()
                throw error
            }
        }
        // 目标端口与内部监听作为同一代一起发布
        let (published, old): (Bool, NWListener?) = lock.withLock {
            guard epoch == myEpoch else { return (false, nil) }
            if let created { frontDoor = created }
            frontDoor?.setTarget(port: internalPort, generation: generation)
            defer { listener = new }
            return (true, listener)
        }
        guard published else {
            new.cancel()
            created?.stop()
            throw TransportError.closed
        }
        created?.resume()   // 前门已保存、来源查询已可用，才开始取连接
        old?.cancel()
    }

    /// 停止：关对外端口、内部监听与全部转发。正在进行的启动或换密钥随之作废。
    public func stop() {
        let (door, l) = lock.withLock { () -> (KernelFrontDoor?, NWListener?) in
            epoch += 1
            defer { frontDoor = nil; listener = nil }
            return (frontDoor, listener)
        }
        door?.stop()
        l?.cancel()
    }

    // MARK: 连接

    private func accept(_ connection: NWConnection, generation: Int) {
        // 经前门转来的连接查回真实来源；本机程序直接连内部端口的照实记为本机地址
        let host = lock.withLock { frontDoor }?.origin(of: connection.endpoint, generation: generation) ?? Self.host(of: connection.endpoint)
        if isBlocked(host) { connection.cancel(); return }
        let io = ConnectionIO(connection, queue: queue)
        let readyOnce = OnceFlag()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // 同一连接的就绪通知可能到达多次，只处理第一次
                guard readyOnce.set() else { return }
                guard TransportSecurity.hasRequiredSuite(connection),
                      let meta = TransportSecurity.metadata(connection),
                      let identity = self.lock.withLock({ self.identities.removeValue(forKey: ObjectIdentifier(meta as AnyObject)) })
                else { connection.cancel(); return }
                Task { await self.serve(io, peer: Peer(identity: identity, remoteHost: host)) }
            case .failed(let error):
                // 只有加密握手本身失败（密码或密钥不对）才计入限速；客户端自己断开、网络中断不算。
                // 曾把切歌、跳转时客户端主动关闭的连接也算进去，播放一阵后整台设备被拒绝 10 分钟（2026-10-05）。
                if case .tls = error { self.recordFailure(host) }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        // 认证前时限：到时还没完成握手就断开（不计入登录失败）
        queue.asyncAfter(deadline: .now() + Self.handshakeSeconds) {
            if !readyOnce.isSet { connection.cancel() }
        }
    }

    private func serve(_ io: ConnectionIO, peer: Peer) async {
        defer { io.cancel() }
        do {
            // 请求时限：到时还没收齐就断开
            let timer = Task { [seconds = Self.requestSeconds] in
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { io.cancel() }
            }
            defer { timer.cancel() }
            var buffer = Data()
            var head: (lines: [String], rest: Data)?
            while head == nil {
                guard let chunk = try await io.receive() else { return }
                buffer.append(chunk)
                head = try HTTPParser.splitHead(buffer)
            }
            let parsed = try HTTPParser.request(lines: head!.lines)
            let length = parsed.headers["content-length"].flatMap { Int($0) } ?? 0
            guard length <= Self.maxRequestBody else {
                timer.cancel()
                try await write(io, .status(413)); return
            }
            var body = head!.rest
            while body.count < length {
                guard let chunk = try await io.receive() else { return }
                body.append(chunk)
            }
            timer.cancel()
            let request = HTTPRequest(method: parsed.method, path: parsed.path, query: parsed.query,
                                      headers: parsed.headers, body: body.prefix(length))
            try await write(io, await handler(peer, request))
        } catch {
            try? await write(io, .status(400))
        }
    }

    private func write(_ io: ConnectionIO, _ response: Response) async throws {
        switch response {
        case .full(var head, let body):
            head.headers["content-length"] = String(body.count)
            try await io.send(Self.serialize(head) + body)
        case .stream(var head, let stream):
            head.headers.removeValue(forKey: "content-length")
            try await io.send(Self.serialize(head))
            for try await chunk in stream { try await io.send(chunk) }
        }
        await io.finish()
    }

    static func serialize(_ head: HTTPResponseHead) -> Data {
        var headers = head.headers
        headers["connection"] = "close"
        var text = "HTTP/1.1 \(head.status) \(HTTPParser.reason(head.status))\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { text += "\(k): \(v)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    // MARK: 限速

    private func recordFailure(_ host: String) {
        let key = Self.limitKey(host)
        let event: String? = lock.withLock {
            let now = Date()
            failures[key, default: []].append(now)
            failures[key] = failures[key]!.filter { now.timeIntervalSince($0) < Self.failureWindow }
            // 记录太多时清掉过期的，防止被大量地址撑大
            if failures.count > 5000 {
                failures = failures.filter { $0.value.contains { now.timeIntervalSince($0) < Self.failureWindow } }
            }
            guard failures[key]!.count >= Self.failureLimit, reported.insert("ip:" + key).inserted else { return nil }
            return "加密端口：\(key) 连续登录失败，已拒绝 \(Int(Self.failureWindow / 60)) 分钟"
        }
        if let event { onSecurityEvent?(event) }
    }

    private func isBlocked(_ host: String) -> Bool {
        let key = Self.limitKey(host)
        return lock.withLock {
            let now = Date()
            let recent = (failures[key] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
            failures[key] = recent.isEmpty ? nil : recent
            if recent.count < Self.failureLimit { reported.remove("ip:" + key) }
            return recent.count >= Self.failureLimit
        }
    }

    /// 选密钥前的检查：用户名密码身份（u:）计数，超过上限就暂停；设备身份（d:）不限。
    private func allowIdentity(_ identity: String) -> Bool {
        guard identity.hasPrefix("u:") else { return true }
        let (allowed, event): (Bool, String?) = lock.withLock {
            let now = Date()
            var recent = (passwordAttempts[identity] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
            guard recent.count < Self.passwordAttemptLimit else {
                passwordAttempts[identity] = recent
                let first = reported.insert(identity).inserted
                return (false, first ? "加密端口：用户 \(identity.dropFirst(2)) 的密码登录尝试过多，已暂停 \(Int(Self.failureWindow / 60)) 分钟（已登录的设备不受影响）" : nil)
            }
            recent.append(now)
            passwordAttempts[identity] = recent
            reported.remove(identity)
            return (true, nil)
        }
        if let event { onSecurityEvent?(event) }
        return allowed
    }

    static func host(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    /// 计数用的来源：IPv4 按单个地址；IPv6 按前 64 位（同一网段可以随意换地址）。
    static func limitKey(_ host: String) -> String {
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        var v6 = in6_addr()
        guard bare.contains(":"), inet_pton(AF_INET6, bare, &v6) == 1 else { return bare }
        let b = withUnsafeBytes(of: v6) { Array($0) }
        // IPv4 映射地址按 IPv4 算
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return "\(b[12]).\(b[13]).\(b[14]).\(b[15])" }
        return stride(from: 0, to: 8, by: 2).map { String(format: "%02x%02x", b[$0], b[$0 + 1]) }.joined(separator: ":") + "::/64"
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// 第一次调用返回 true。
    func set() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    var isSet: Bool { lock.withLock { done } }
}
