import Foundation
import Network

/// 不加密的 HTTP 服务器，只用于家庭内网的网页管理端口（ADR-0003 第 12 节）。
/// 默认只接受私有网段与本机地址的访问。
public final class PlainHTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ remoteHost: String, HTTPRequest) async -> SecureServer.Response

    private let handler: Handler
    private let queue = DispatchQueue(label: "AccessibleMusic.PlainHTTP")
    private let lock = NSLock()
    private var listener: NWListener?
    private var frontDoor: KernelFrontDoor?
    private let gate = SerialGate()
    private var epoch = 0
    private var nextGeneration = 0
    private let port: NWEndpoint.Port
    public var allowPublicAddresses = false

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = NWEndpoint.Port(rawValue: port) ?? .any
        self.handler = handler
    }

    public var actualPort: UInt16? { lock.withLock { frontDoor?.port } }
    /// 当前前门（测试用）。
    var frontDoorForTesting: KernelFrontDoor? { lock.withLock { frontDoor } }
    /// 请求时限：连上后这么久还没收齐请求头与请求体就断开。
    nonisolated(unsafe) static var requestSeconds: Double = 15

    /// 对外端口由内核套接字接受、经本机回环转给只绑 127.0.0.1 的内部监听（原因见 KernelFrontDoor；
    /// 网页数据量不大，但服务器 Mac mini 上 Network 框架对外发送几乎发不动，一个页面也要等好几秒）。
    /// 多次调用按顺序执行；执行中途被 `stop()` 的作废并抛出 `TransportError.closed`。
    public func start() async throws {
        try await gate.run { try await self.startSerially() }
    }

    private func startSerially() async throws {
        let (myEpoch, generation) = lock.withLock { () -> (Int, Int) in
            nextGeneration += 1
            return (epoch, nextGeneration)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: parameters)
        l.newConnectionHandler = { [weak self] in self?.accept($0, generation: generation) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.set() { c.resume() }
                case .failed(let e): if once.set() { c.resume(throwing: e) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        guard let internalPort = l.port?.rawValue else { l.cancel(); throw TransportError.closed }
        var created: KernelFrontDoor?
        if lock.withLock({ frontDoor }) == nil {
            do {
                created = try KernelFrontDoor(port: port.rawValue) { [weak self] host in
                    guard let self else { return false }
                    return self.allowPublicAddresses || Self.isPrivate(host)
                }
            } catch {
                l.cancel()
                throw error
            }
        }
        // 目标端口与内部监听作为同一代一起发布
        let (published, old): (Bool, NWListener?) = lock.withLock {
            guard epoch == myEpoch else { return (false, nil) }
            if let created { frontDoor = created }
            frontDoor?.setTarget(port: internalPort, generation: generation)
            defer { listener = l }
            return (true, listener)
        }
        guard published else {
            l.cancel()
            created?.stop()
            throw TransportError.closed
        }
        created?.resume()
        old?.cancel()
    }

    public func stop() {
        let (door, l) = lock.withLock { () -> (KernelFrontDoor?, NWListener?) in
            epoch += 1
            defer { frontDoor = nil; listener = nil }
            return (frontDoor, listener)
        }
        door?.stop()
        l?.cancel()
    }

    private func accept(_ connection: NWConnection, generation: Int) {
        let host = lock.withLock { frontDoor }?.origin(of: connection.endpoint, generation: generation) ?? SecureServer.host(of: connection.endpoint)
        guard allowPublicAddresses || Self.isPrivate(host) else { connection.cancel(); return }
        let io = ConnectionIO(connection, queue: queue)
        let once = OnceFlag()
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, once.set(), let self else { return }
            Task { await self.serve(io, host: host) }
        }
        connection.start(queue: queue)
    }

    private func serve(_ io: ConnectionIO, host: String) async {
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
            let length = min(parsed.headers["content-length"].flatMap { Int($0) } ?? 0, 256 * 1024)
            var body = head!.rest
            while body.count < length {
                guard let chunk = try await io.receive() else { return }
                body.append(chunk)
            }
            timer.cancel()
            let request = HTTPRequest(method: parsed.method, path: parsed.path, query: parsed.query,
                                      headers: parsed.headers, body: body.prefix(length))
            switch await handler(host, request) {
            case .full(var h, let b):
                h.headers["content-length"] = String(b.count)
                try await io.send(SecureServer.serialize(h) + b)
            case .stream(let h, let s):
                try await io.send(SecureServer.serialize(h))
                for try await chunk in s { try await io.send(chunk) }
            }
            await io.finish()
        } catch {}
    }

    /// 本机、私有网段（10/8、172.16/12、192.168/16）、链路本地与 IPv6 唯一本地地址。
    public static func isPrivate(_ host: String) -> Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? host
        if h == "127.0.0.1" || h == "::1" || h.hasPrefix("::ffff:127.") { return true }
        let v4 = h.hasPrefix("::ffff:") ? String(h.dropFirst(7)) : h
        let parts = v4.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        let lower = h.lowercased()
        return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }
}

extension HTTPRequest {
    /// 解析 `application/x-www-form-urlencoded` 表单。逐项手工解码：
    /// 不能交给 `URLComponents.percentEncodedQuery`，遇到未编码的中文等字符会直接让进程崩溃。
    public var form: [String: String] {
        func decode(_ s: Substring) -> String {
            let plus = s.replacingOccurrences(of: "+", with: " ")
            return plus.removingPercentEncoding ?? plus
        }
        var result: [String: String] = [:]
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first, !name.isEmpty else { continue }
            result[decode(name)] = parts.count > 1 ? decode(parts[1]) : ""
        }
        return result
    }
}
