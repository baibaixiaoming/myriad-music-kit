import Foundation
import Network

/// 对外端口的“前门”：用内核套接字接受连接，再经本机回环转给只绑在 127.0.0.1 的 Network 框架监听器。
///
/// 为什么不直接用 NWListener 对外（2026-10-08 实测）：Network 框架在 macOS 上接受的连接走用户态协议栈
/// （nettop 架构列显示 ch）。在服务器 Mac mini（10G 有线网卡、处于混杂模式并挂着 vlan）上，用户态协议栈往外发包
/// 大量丢失，重传约占一半，往局域网另一台机器发 32 MB 只有约 0.01–0.15 MB/秒；同一台机器用内核套接字约 17 MB/秒。
/// Network 框架没有公开办法要求走内核协议栈，也不能把已接受的套接字包装成 NWConnection，所以对外一侧改用内核套接字，
/// 加密与 HTTP 处理照旧交给 Network 框架（本机回环上很快）。
///
/// - 用法：`init` 只绑定并开始监听（内核排队，不取连接）；调用方设好目标（`setTarget`）、保存好本对象、
///   装好来源查询之后再 `resume()` 开始取连接。
/// - 内部监听只绑 127.0.0.1，外面连不进来。
/// - 真实来源地址：转接用的出站套接字先绑定本机回环的临时端口，登记“临时端口 → 真实地址、连接编号、目标代次”，
///   再连内部监听。内部监听接受连接时，只有对方确实是 127.0.0.1 且代次相同才认这条登记（`origin(of:generation:)`）。
///   连接结束时先撤销登记（核对连接编号）再关闭套接字，端口被别的连接复用也不会串号。
/// - 外部监听为 IPv6 双栈（同时接受 IPv4）；系统不支持 IPv6 时退回只听 IPv4。
/// - 上限：总共 `maxConnections` 条，同一来源（IPv6 按 /64）`maxPerSource` 条，超出的直接关闭。
/// - 每条连接一个线程，用 poll 双向转发（见 `pump`）：按方向处理结束，先排空再半关闭；内部一侧结束后，
///   对外最多再等 `lingerSeconds` 秒让对方收完并关闭；有数据却连续 `stallSeconds` 秒写不出去就断开。
///   对外连接开 TCP 保活。握手、请求头的时限在 Network 框架那一侧（SecureServer、PlainHTTPServer）。
/// - 文件描述符用完时暂停取连接，退避（50 毫秒起，最多 2 秒）后再恢复。
/// - `stop()` 关闭监听并通知全部转发线程退出（包括还在连内部监听的）、关闭各自的套接字；
///   对外连接用重置关闭（先等最多 200 毫秒让已发出的数据被确认），见 `relay` 末尾的说明。
final class KernelFrontDoor: @unchecked Sendable {
    /// 对外实际监听的端口（请求 0 时由系统分配）。
    let port: UInt16

    nonisolated(unsafe) static var maxConnections = 192
    nonisolated(unsafe) static var maxPerSource = 64
    nonisolated(unsafe) static var stallSeconds: Double = 120
    nonisolated(unsafe) static var lingerSeconds: Double = 10
    static let connectSeconds: Double = 5
    static let bufferSize = 256 * 1024

    struct Registration { let host: String; let connection: Int; let generation: Int }

    /// 是否接受这个来源（在建立转发之前判断，例如被限速的地址、管理网页只收内网）。
    private let shouldAccept: @Sendable (String) -> Bool
    private let lock = NSLock()
    private var target: (port: UInt16, generation: Int)?
    private var registrations: [UInt16: Registration] = [:]
    private var perSource: [String: Int] = [:]
    private var active = 0
    private var nextConnection = 0
    private var stopped = false
    private var started = false
    private let listenFD: Int32
    private var source: DispatchSourceRead?
    private var suspended = false
    private var backoff: Double = 0
    /// 停止通知：写端写入一个字节后，所有转发线程的 poll 都会醒来并退出。
    private let stopRead: Int32
    private let stopWrite: Int32
    private let queue = DispatchQueue(label: "AccessibleMusic.KernelFrontDoor")
    private static let queueKey = DispatchSpecificKey<Bool>()

    /// 还活着的转发线程数（线程把套接字都关掉后、退出前最后一步才减一；测试用）。
    var activeCount: Int { lock.withLock { active } }
    var registrationCount: Int { lock.withLock { registrations.count } }
    var targetPortForTesting: UInt16? { lock.withLock { target?.port } }
    /// 各条转发最近一次状态变化（诊断用：读到结束、半关闭、作废、缓冲字节数、结束原因）。只在状态变化时更新。
    private var relayStates: [Int: String] = [:]
    var relayStatesForTesting: [Int: String] { lock.withLock { relayStates } }
    func registerForTesting(port: UInt16, host: String, connection: Int, generation: Int) {
        lock.withLock { registrations[port] = Registration(host: host, connection: connection, generation: generation) }
    }

    init(port requested: UInt16, shouldAccept: @escaping @Sendable (String) -> Bool) throws {
        self.shouldAccept = shouldAccept
        let fd = try Self.listenSocket(port: requested)
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        var p: [Int32] = [0, 0]
        guard pipe(&p) == 0 else {
            let e = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        for f in p { _ = fcntl(f, F_SETFL, fcntl(f, F_GETFL) | O_NONBLOCK) }
        port = Self.port(of: ss)
        listenFD = fd
        stopRead = p[0]; stopWrite = p[1]
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    deinit {
        stop()
        close(stopRead); close(stopWrite)
    }

    /// 内部监听（某一代）就绪：之后的新连接转到它，已建立的不受影响。
    func setTarget(port: UInt16, generation: Int) { lock.withLock { target = (port, generation) } }

    /// 开始取连接。只调用一次。
    func resume() {
        onQueue {
            guard !self.started, !self.lock.withLock({ self.stopped }) else { return }
            self.started = true
            let fd = self.listenFD
            let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            s.setEventHandler { [weak self] in self?.acceptAll() }
            s.setCancelHandler { close(fd) }
            self.source = s
            s.resume()
        }
    }

    /// 内部监听接受的连接对应的真实来源。只认来自 127.0.0.1、登记代次与接受它的监听代次相同的；
    /// 其他（本机程序直接连内部端口等）返回 nil。
    func origin(of endpoint: NWEndpoint, generation: Int) -> String? {
        guard case .hostPort(let host, let p) = endpoint, case .ipv4(let a) = host, a == IPv4Address.loopback else { return nil }
        return lock.withLock {
            guard let r = registrations[p.rawValue], r.generation == generation else { return nil }
            return r.host
        }
    }

    func stop() {
        let first: Bool = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard first else { return }
        var b: UInt8 = 1
        _ = write(stopWrite, &b, 1)
        let closed = DispatchSemaphore(value: 0)
        var waitForClose = false
        onQueue {
            if let s = self.source {
                s.setCancelHandler { [fd = self.listenFD] in close(fd); closed.signal() }
                waitForClose = true
                s.cancel()   // 取消处理里关监听套接字
                if self.suspended { s.resume(); self.suspended = false }   // 挂起的事件源要恢复后取消才会生效
                self.source = nil
            } else if !self.started {
                // 还没开始取连接：直接关监听套接字，之后不再开始
                close(self.listenFD)
                self.started = true
            }
        }
        // 等监听套接字真正关掉再返回（停止后端口立即拒绝连接）；在自己的队列上调用时不能等
        if waitForClose, DispatchQueue.getSpecific(key: Self.queueKey) != true { _ = closed.wait(timeout: .now() + 2) }
    }

    private func onQueue(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == true { work() } else { queue.sync(execute: work) }
    }

    // MARK: 接受

    private static func listenSocket(port: UInt16) throws -> Int32 {
        func fail(_ fd: Int32) -> POSIXError {
            let e = errno
            if fd >= 0 { close(fd) }
            return POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        var yes: Int32 = 1, no: Int32 = 0
        // 先试 IPv6 双栈
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        if fd6 >= 0 {
            setsockopt(fd6, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd6, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            a.sin6_addr = in6addr_any
            let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            if r == 0 {
                guard listen(fd6, 128) == 0 else { throw fail(fd6) }
                _ = fcntl(fd6, F_SETFL, fcntl(fd6, F_GETFL) | O_NONBLOCK)
                return fd6
            }
            // 端口被占用等错误照实报告；只有系统不支持 IPv6 时才退回 IPv4
            if errno != EAFNOSUPPORT && errno != EADDRNOTAVAIL { throw fail(fd6) }
            close(fd6)
        }
        let fd4 = socket(AF_INET, SOCK_STREAM, 0)
        guard fd4 >= 0 else { throw fail(fd4) }
        setsockopt(fd4, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0, listen(fd4, 128) == 0 else { throw fail(fd4) }
        _ = fcntl(fd4, F_SETFL, fcntl(fd4, F_GETFL) | O_NONBLOCK)
        return fd4
    }

    /// 在 queue 上运行。
    private func acceptAll() {
        while true {
            var ss = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let c = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &len) } }
            if c < 0 {
                switch errno {
                case EINTR, ECONNABORTED: continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM: pauseAccepting(); return
                default: return   // EAGAIN：已取完
                }
            }
            backoff = 0
            Self.setNoSigPipe(c)
            // 接受的套接字可能继承非阻塞，统一设为非阻塞（连接内部监听与转发都用 poll）
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
            let host = Self.host(of: ss)
            let key = SecureServer.limitKey(host)
            let id: Int? = lock.withLock {
                guard !stopped, active < Self.maxConnections, perSource[key, default: 0] < Self.maxPerSource else { return nil }
                active += 1
                perSource[key, default: 0] += 1
                nextConnection += 1
                return nextConnection
            }
            guard let id else { close(c); continue }
            guard shouldAccept(host) else { close(c); finished(key: key); continue }
            let thread = Thread { [self] in self.relay(client: c, host: host, key: key, id: id) }
            thread.name = "AccessibleMusic.FrontDoor.relay"
            thread.stackSize = 256 * 1024
            thread.start()
        }
    }

    /// 文件描述符等资源用完：暂停取连接，退避后恢复（不忙等）。
    private func pauseAccepting() {
        guard let s = source, !suspended else { return }
        s.suspend()
        suspended = true
        backoff = backoff == 0 ? 0.05 : min(backoff * 2, 2)
        queue.asyncAfter(deadline: .now() + backoff) { [weak self] in
            guard let self, self.suspended, let s = self.source else { return }
            self.suspended = false
            s.resume()
            self.acceptAll()
        }
    }

    private func finished(key: String) {
        lock.withLock {
            active -= 1
            perSource[key, default: 1] -= 1
            if perSource[key] == 0 { perSource[key] = nil }
        }
    }

    // MARK: 转发

    private func relay(client c: Int32, host: String, key: String, id: Int) {
        var registered: UInt16?
        let u = socket(AF_INET, SOCK_STREAM, 0)
        defer {
            // 先撤销登记（核对是本连接的），再关套接字释放端口
            if let registered {
                lock.withLock { if registrations[registered]?.connection == id { registrations[registered] = nil } }
            }
            // 服务停止时对外连接用重置关闭（SO_LINGER 为 0）：停止本来就是强行断开。正常关闭（先送完再发结束）时，
            // 客户端要把 Network 框架已经替它收下的数据读完才看得到结束；按需读取的客户端若暂时不读，
            // 连接就一直挂着。重置会让客户端连接立刻失败、关掉（客户端会先交出已到达的数据再报错）。
            // 代价：200 毫秒内还没送出、没被确认的数据丢弃，停止时这是预期。
            // 停滞超时、对方收尾等其他关闭照旧正常关闭。
            if lock.withLock({ stopped }) {
                // 先等已发出的数据被对方确认（最多 200 毫秒）：实测发送队列里还有在途数据时发重置，
                // 客户端有时不认（序号对不上），连接照样挂着；队列清空后再重置就可靠了。
                Self.waitUntilSent(c, seconds: 0.2)
                var abort = linger(l_onoff: 1, l_linger: 0)
                setsockopt(c, SOL_SOCKET, SO_LINGER, &abort, socklen_t(MemoryLayout<linger>.size))
            }
            close(c)
            if u >= 0 { close(u) }
            lock.withLock { relayStates[id] = nil }
            finished(key: key)
        }
        guard u >= 0 else { return }
        Self.setNoSigPipe(u)
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = 0
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard withUnsafePointer(to: &a, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(u, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0
        else { return }
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(u, $0, &len) } }
        let lp = Self.port(of: ss)
        // 先登记来源，再连内部监听：内部监听接受时一定查得到
        let to: (port: UInt16, generation: Int)? = lock.withLock {
            guard !stopped, let t = target else { return nil }
            registrations[lp] = Registration(host: host, connection: id, generation: t.generation)
            return t
        }
        guard let to else { return }
        registered = lp
        a.sin_port = to.port.bigEndian
        _ = fcntl(u, F_SETFL, fcntl(u, F_GETFL) | O_NONBLOCK)
        guard Self.connectNonBlocking(u, &a, stop: stopRead, seconds: Self.connectSeconds) else { return }

        var yes: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        for fd in [c, u] { setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, size) }
        // 对外连接的保活：对方掉线时约 2 分钟内断开
        var idle: Int32 = 60, interval: Int32 = 10, count: Int32 = 6
        setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, size)
        setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
        Self.pump(c, u, stop: stopRead, stallSeconds: Self.stallSeconds, lingerSeconds: Self.lingerSeconds) { [weak self] state in
            self?.lock.withLock { self?.relayStates[id] = state }
        }
    }

    /// 非阻塞连接：同时等连接结果、停止通知和时限，并核对 SO_ERROR。
    static func connectNonBlocking(_ fd: Int32, _ a: inout sockaddr_in, stop: Int32, seconds: Double) -> Bool {
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 { return true }
        guard errno == EINPROGRESS || errno == EINTR else { return false }
        let deadline = now() + seconds
        while true {
            let left = deadline - now()
            if left <= 0 { return false }
            var p = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0), pollfd(fd: stop, events: Int16(POLLIN), revents: 0)]
            let n = poll(&p, 2, Int32(min(left, 1) * 1000) + 1)
            if n < 0 { if errno == EINTR { continue }; return false }
            if p[1].revents != 0 { return false }
            if p[0].revents != 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
                return err == 0
            }
        }
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// 等发送队列清空（对方确认了全部已写入的数据），最多 `seconds` 秒。
    static func waitUntilSent(_ fd: Int32, seconds: Double) {
        let deadline = now() + seconds
        while now() < deadline {
            var info = tcp_connection_info()
            var len = socklen_t(MemoryLayout<tcp_connection_info>.size)
            guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &len) == 0, info.tcpi_snd_sbbytes > 0 else { return }
            usleep(2_000)
        }
    }

    /// 双向转发。下标 0 是对外连接，1 是内部连接；方向 d 指从 fds[d] 读、往 fds[1-d] 写，数据在 buffers[d]。
    ///
    /// - 读到结束（eof[d]）后继续把 buffers[d] 写完，写完才对目标半关闭（shut[d]）。对方暂时写不进去只是等，不算结束。
    /// - 往内部写失败（内部已整个关闭）：对外→内部这个方向作废，之后读到的丢弃；往外写失败（对方已断开）：整条结束。
    /// - 对外一端读出错（被重置）：整条结束；内部一端读出错：当作读到结束，已读到的照常送完。
    /// - 内部→对外方向结束后，最多再等 `lingerSeconds` 秒让对方关闭（继续读，避免带未读数据关闭发出重置导致对方丢尾巴）。
    /// - 有待写数据却连续 `stallSeconds` 秒没有写出任何字节：结束。
    /// - 收到停止通知：结束。
    static func pump(_ c: Int32, _ u: Int32, stop: Int32, stallSeconds: Double, lingerSeconds: Double,
                     report: ((String) -> Void)? = nil) {
        let fds = [c, u]
        var buffers = [Buffer(), Buffer()]
        defer { buffers[0].free(); buffers[1].free() }
        var eof = [false, false]
        var shut = [false, false]
        var dead = [false, false]
        var lastProgress = [now(), now()]
        var lingerUntil: Double?
        var idleWakeups = 0
        func finished(_ d: Int) -> Bool { eof[d] && ((buffers[d].isEmpty && shut[d]) || dead[d]) }
        var lastState = ""
        var lastSig = 0
        func say(_ reason: String) {
            guard let report else { return }
            let state = "\(reason) 读完=\(eof) 半关=\(shut) 作废=\(dead) 缓冲=\(buffers[0].end - buffers[0].start),\(buffers[1].end - buffers[1].start)"
            if state != lastState { lastState = state; report(state) }
        }
        say("开始")
        while true {
            let t = now()
            if finished(1) {
                if finished(0) { say("两个方向都结束"); return }
                if lingerUntil == nil { lingerUntil = t + lingerSeconds }
            }
            if let l = lingerUntil, t >= l { say("收尾等待到时"); return }
            for d in 0..<2 where !buffers[d].isEmpty && !dead[d] && t - lastProgress[d] > stallSeconds { say("方向\(d)停滞"); return }

            var p = [pollfd](repeating: pollfd(), count: 3)
            var wantRead = [false, false], wantWrite = [false, false]
            for i in 0..<2 {
                wantRead[i] = !eof[i] && (dead[i] || !buffers[i].isFull)
                wantWrite[i] = !buffers[1 - i].isEmpty && !dead[1 - i]
                var ev: Int16 = 0
                if wantRead[i] { ev |= Int16(POLLIN) }
                if wantWrite[i] { ev |= Int16(POLLOUT) }
                p[i] = pollfd(fd: fds[i], events: ev, revents: 0)
            }
            p[2] = pollfd(fd: stop, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 3, 1000)
            if r < 0 { if errno == EINTR { continue }; say("等待出错 \(errno)"); return }
            if p[2].revents != 0 { say("停止"); return }
            if r == 0 { say("空闲 等读=\(wantRead) 等写=\(wantWrite)"); continue }   // 每秒一次，卡住时能看到当时状态
            var progressed = false
            let ready = Int16(POLLHUP | POLLERR)
            // 先写：尽量把已有数据送出去
            for i in 0..<2 where wantWrite[i] && p[i].revents & (Int16(POLLOUT) | ready) != 0 {
                let d = 1 - i
                let n = buffers[d].write(to: fds[i])
                if n > 0 { lastProgress[d] = now(); progressed = true; continue }
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                if i == 0 { say("往外写失败 \(errno)"); return }   // 对方已断开，送不出去了
                dead[d] = true; buffers[d].clear(); progressed = true   // 内部已整个关闭：对外→内部作废
            }
            for i in 0..<2 where wantRead[i] && p[i].revents & (Int16(POLLIN) | ready) != 0 {
                let n: Int
                if dead[i] { n = Buffer.discard(from: fds[i]) } else {
                    let wasEmpty = buffers[i].isEmpty
                    n = buffers[i].read(from: fds[i])
                    if n > 0 && wasEmpty { lastProgress[i] = now() }
                }
                if n > 0 { progressed = true }
                else if n == 0 { eof[i] = true; progressed = true }
                else if errno != EAGAIN && errno != EINTR {
                    if i == 0 { say("对外读出错 \(errno)"); return }   // 对方重置：什么也送不出去了
                    // 内部被重置：已读到的照常送完再半关闭；往内部的方向作废
                    eof[1] = true; dead[0] = true; buffers[0].clear(); progressed = true
                }
            }
            for d in 0..<2 where eof[d] && buffers[d].isEmpty && !shut[d] && !dead[d] {
                shutdown(fds[1 - d], SHUT_WR)
                shut[d] = true
                progressed = true
            }
            let sig = (0..<2).reduce(0) { $0 | (eof[$1] ? 1 : 0) << ($1 * 3) | (shut[$1] ? 2 : 0) << ($1 * 3) | (dead[$1] ? 4 : 0) << ($1 * 3) }
            if sig != lastSig { lastSig = sig; say("进行中") }
            // 防空转：被唤醒却什么也没做成时稍等（不丢数据，时限照常生效）
            if progressed { idleWakeups = 0 } else { idleWakeups += 1; if idleWakeups > 8 { usleep(10_000) } }
        }
    }

    /// 定长缓冲：从头部取、往尾部放，取空后归零。
    struct Buffer {
        let base = UnsafeMutableRawPointer.allocate(byteCount: KernelFrontDoor.bufferSize, alignment: 16)
        var start = 0, end = 0
        var isEmpty: Bool { start == end }
        var isFull: Bool { end == KernelFrontDoor.bufferSize }
        mutating func read(from fd: Int32) -> Int {
            let n = Darwin.read(fd, base + end, KernelFrontDoor.bufferSize - end)
            if n > 0 { end += n }
            return n
        }
        mutating func write(to fd: Int32) -> Int {
            let n = Darwin.write(fd, base + start, end - start)
            if n > 0 { start += n; if start == end { start = 0; end = 0 } }
            return n
        }
        mutating func clear() { start = 0; end = 0 }
        func free() { base.deallocate() }
        /// 读出并丢弃。
        static func discard(from fd: Int32) -> Int {
            var scratch = [UInt8](repeating: 0, count: 16 * 1024)
            return Darwin.read(fd, &scratch, scratch.count)
        }
    }

    // MARK: 地址

    static func setNoSigPipe(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    static func port(of ss: sockaddr_storage) -> UInt16 {
        var ss = ss
        switch Int32(ss.ss_family) {
        case AF_INET: return withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) } }
        case AF_INET6: return withUnsafePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) } }
        default: return 0
        }
    }

    /// 数字地址；IPv4 映射的 IPv6 地址写成普通 IPv4，链路本地地址带网卡名（如 fe80::1%en0）。
    static func host(of ss: sockaddr_storage) -> String {
        var ss = ss
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t($0.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard r == 0 else { return "?" }
        let s = String(cString: buf)
        if s.lowercased().hasPrefix("::ffff:"), s.contains(".") { return String(s.dropFirst(7)) }
        return s
    }
}

/// 异步互斥：启动、换密钥、停止按到达顺序一个一个来。
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        await enter()
        defer { leave() }
        return try await work()
    }

    private func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }

    private func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
