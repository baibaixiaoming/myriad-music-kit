import Foundation
import Network

/// 加密端口的客户端。每个请求一条连接（第一版求简单可靠，之后可加连接复用）。
public struct SecureClient: Sendable {
    public let host: String
    public let port: UInt16
    public let key: TransportSecurity.KeyEntry
    public var connectTimeout: Duration = .seconds(10)

    public init(host: String, port: UInt16, key: TransportSecurity.KeyEntry) {
        self.host = host
        self.port = port
        self.key = key
    }

    /// 发送请求并读完整个响应。
    public func send(_ request: HTTPRequest) async throws -> (HTTPResponseHead, Data) {
        let (head, stream) = try await open(request)
        var body = Data()
        for try await chunk in stream { body.append(chunk) }
        if let length = head.contentLength, body.count < length { throw TransportError.closed }
        return (head, body)
    }

    public var sendTimeout: Duration = .seconds(5)
    public var responseHeadTimeout: Duration = .seconds(10)
    public var bodyIdleTimeout: Duration = .seconds(10)
    public var clock: TransportClock = .continuous
    /// 建立请求到完整响应头的上限；正文由无进展期限和调用者的有效加载预算约束。
    public var requestTimeout: Duration = .seconds(30)
    public var remainingBudget: (@Sendable () -> Duration?)?
    public var onPhase: (@Sendable (String) -> Void)?

    /// 一次请求一条连接；正文按消费需求读，慢消费不会积压或丢弃音频。
    ///
    /// 边界：读取方拿着正文却暂时不读时，服务器那边正常结束（先送完再发结束）的连接，
    /// 要等读取方继续读到结束、或丢掉正文（析构时关闭）才会关掉——结束标记排在 Network 框架已收下的数据后面，
    /// 不读就看不到。服务器停止时用重置关闭，连接会立即失败：已到达本机的数据照样先交给读取方，再报错（见 ConnectionIO）。
    public func open(_ request: HTTPRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: TransportSecurity.clientParameters(key))
        let io = ConnectionIO(connection, queue: DispatchQueue(label: "AccessibleMusic.SecureClient"), clientMode: true, clock: clock)
        return try await open(request, using: io)
    }

    func open(_ request: HTTPRequest, using io: ConnectionIO) async throws -> (HTTPResponseHead, AsyncThrowingStream<Data, Error>) {
        let phases = ClientPhaseLog(clock: clock, sink: onPhase)
        return try await withTaskCancellationHandler {
            do {
                let totalEnd = clock.now() + requestTimeout
                func limit(_ cap: Duration) throws -> Duration {
                    let value = min(cap, totalEnd - clock.now(), remainingBudget?() ?? cap)
                    guard value > .zero else { throw TransportError.timeout }
                    return value
                }
                let connectionLimit = try limit(connectTimeout)
                phases.begin("连接与握手", limit: connectionLimit)
                try await io.start(timeout: connectionLimit)
                phases.finish()
                let sendLimit = try limit(sendTimeout)
                phases.begin("发送", limit: sendLimit)
                try await io.send(request.serialized(), timeout: sendLimit)
                phases.finish()
                let headLimit = try limit(responseHeadTimeout)
                phases.begin("响应头等待", limit: headLimit)
                let deadline = clock.now() + headLimit
                var buffer = Data()
                var parsed: (lines: [String], rest: Data)?
                while parsed == nil {
                    let remaining = min(deadline - clock.now(), try limit(responseHeadTimeout))
                    guard remaining > .zero else { throw TransportError.timeout }
                    guard let chunk = try await io.receive(timeout: remaining) else { throw TransportError.closed }
                    buffer.append(chunk)
                    parsed = try HTTPParser.splitHead(buffer)
                    if let parsed {
                        guard buffer.count - parsed.rest.count <= 64 * 1024 else { throw TransportError.malformed }
                    } else if buffer.count > 64 * 1024 { throw TransportError.malformed }
                }
                let head = try HTTPParser.responseHead(lines: parsed!.lines)
                if let text = head.headers["content-length"], Int(text).map({ $0 >= 0 }) != true { throw TransportError.malformed }
                guard clock.now() < deadline, clock.now() < totalEnd, (remainingBudget?() ?? .seconds(1)) > .zero else { throw TransportError.timeout }
                phases.finish()
                let reader = ClientResponseBody(first: parsed!.rest, length: head.contentLength,
                    receive: {
                        let remaining = min(bodyIdleTimeout, remainingBudget?() ?? bodyIdleTimeout)
                        guard remaining > .zero else { phases.failure(TransportError.timeout, body: true); io.cancel(); throw TransportError.timeout }
                        phases.bodyBegin(limit: remaining)
                        do {
                            let bytes = try await io.receive(timeout: remaining)
                            phases.body(bytes?.count ?? 0)
                            return bytes
                        } catch { phases.failure(error, body: true); throw error }
                    }, cancel: { io.cancel() })
                let stream = AsyncThrowingStream<Data, Error>(unfolding: { try await reader.next() })
                try Task.checkCancellation()
                return (head, stream)
            } catch {
                phases.failure(error)
                io.cancel()
                if error is HTTPParseError { throw TransportError.malformed }
                throw error
            }
        } onCancel: { io.cancel() }
    }
}

/// 不启动生产者任务。只有 iterator.next 才向网络要下一块，最多持有一块（64 KiB）。
actor ClientResponseBody {
    private var first: Data
    private let length: Int?
    private var received = 0
    private var ended = false
    private var reading = false
    private let receive: @Sendable () async throws -> Data?
    private let cancel: @Sendable () -> Void
    init(first: Data, length: Int?, receive: @escaping @Sendable () async throws -> Data?, cancel: @escaping @Sendable () -> Void) {
        self.first = first; self.length = length; self.receive = receive; self.cancel = cancel
    }
    deinit { cancel() }
    func next() async throws -> Data? {
        if Task.isCancelled { cancel(); throw CancellationError() }
        guard !reading else { throw TransportError.malformed }
        guard !ended else { return nil }
        reading = true
        defer { reading = false }
        do {
            return try await withTaskCancellationHandler {
                if let length, received == length {
                    guard first.isEmpty else { throw TransportError.malformed }
                    ended = true; cancel(); return nil
                }
                let piece: Data?
                if first.isEmpty { piece = try await receive() }
                else { piece = first; first = Data() }
                try Task.checkCancellation()
                guard let piece else {
                    ended = true; cancel()
                    if let length, received != length { throw TransportError.closed }
                    return nil
                }
                guard length.map({ piece.count <= $0 - received }) ?? true else { throw TransportError.malformed }
                received += piece.count
                // 不依赖消费者再调用一次 next() 才关闭完整响应。
                if let length, received == length { ended = true; cancel() }
                return piece
            } onCancel: { [cancel] in cancel() }
        } catch { ended = true; cancel(); throw error }
    }
}


/// 只记录客户端阶段、预算和字节数；正文最多每五秒一条，不能挤掉播放诊断。
final class ClientPhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TransportClock
    private let sink: (@Sendable (String) -> Void)?
    private var stage = "连接与握手"
    private var began: Duration = .zero
    private var lastBodyLog: Duration?
    private var lastBodyWaitLog: Duration?
    private var bodyBegan: Duration = .zero
    private var bodyBytes = 0
    init(clock: TransportClock, sink: (@Sendable (String) -> Void)?) { self.clock = clock; self.sink = sink }
    func begin(_ name: String, limit: Duration) {
        lock.withLock { stage = name; began = clock.now() }
        sink?("\(name)开始，剩余阶段预算 \(limit)")
    }
    func finish() {
        let text = lock.withLock { "\(stage)完成，用时 \(clock.now() - began)" }
        sink?(text)
    }
    func bodyBegin(limit: Duration) {
        let log = lock.withLock { () -> Bool in
            bodyBegan = clock.now()
            guard lastBodyWaitLog == nil || bodyBegan - lastBodyWaitLog! >= .seconds(5) else { return false }
            lastBodyWaitLog = bodyBegan
            return true
        }
        if log { sink?("正文按需等待，剩余阶段预算 \(limit)") }
    }
    func body(_ count: Int) {
        let text = lock.withLock { () -> String? in
            bodyBytes += count
            let now = clock.now()
            guard lastBodyLog == nil || now - lastBodyLog! >= .seconds(5) else { return nil }
            lastBodyLog = now
            let text = "正文按需交付累计 \(bodyBytes) 字节"
            return text
        }
        if let text { sink?(text) }
    }
    func failure(_ error: any Error, body: Bool = false) {
        let reason = error is CancellationError ? "取消" : error as? TransportError == .timeout ? "超时" : "终止错误"
        let text = lock.withLock { "\(body ? "正文" : stage)\(reason)，阶段用时 \(clock.now() - (body ? bodyBegan : began))" }
        sink?(text)
    }
}
