import Foundation
import Network
import Testing
@testable import SecureTransport

/// 对外端口经内核套接字接受、回环转给内部监听（KernelFrontDoor）：来源地址、限速、上限、时限、
/// 挂断不丢数据、换密钥串行、关闭清理、内部端口不对外。
extension TransportServerSuites {
@Suite(.serialized) struct KernelFrontDoorTests {
    let device = TransportSecurity.KeyEntry(identity: "d:device-1", key: TransportSecurity.randomKey())

    /// /host 返回服务端看到的来源地址；/big 推送 64 MB（测中途断开）。
    func makeServer() -> SecureServer {
        SecureServer(port: 0) { peer, request in
            switch request.path {
            case "/host": return .full(HTTPResponseHead(status: 200), Data(peer.remoteHost.utf8))
            case "/big":
                let chunk = Data(repeating: 1, count: 256 * 1024)
                let (stream, c) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
                Task.detached { for _ in 0..<256 { c.yield(chunk); try? await Task.sleep(for: .milliseconds(1)) }; c.finish() }
                return .stream(HTTPResponseHead(status: 200), stream)
            default: return .status(404)
            }
        }
    }

    /// 等条件成立，最多 `seconds` 秒。
    func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// 普通套接字连本机某地址的某端口（阻塞）；成功返回套接字，失败返回 -errno。
    func rawConnect(_ host: String, _ port: UInt16) -> Int32 {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { return -EINVAL }
        defer { freeaddrinfo(res) }
        let fd = socket(ai.pointee.ai_family, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        if connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 { return fd }
        let e = errno
        close(fd)
        return -e
    }

    /// 连一下就关；返回 0 表示连上，否则 errno。
    func tcpConnect(_ host: String, _ port: UInt16) -> Int32 {
        let fd = rawConnect(host, port)
        if fd >= 0 { close(fd); return 0 }
        return -fd
    }

    /// 等对方关闭：读到结束或被重置返回 true；`seconds` 秒内一直没有结束返回 false。读到的数据丢弃。
    func waitClosed(_ fd: Int32, seconds: Double) -> Bool {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 65536)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            let n = read(fd, &buf, buf.count)
            if n == 0 { return true }
            if n < 0 { return errno != EAGAIN && errno != EWOULDBLOCK ? true : false }
        }
        return false
    }

    /// 本机第一个非回环 IPv4 地址。
    func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var p = list
        while let i = p {
            defer { p = i.pointee.ifa_next }
            guard let a = i.pointee.ifa_addr, a.pointee.sa_family == sa_family_t(AF_INET),
                  i.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, i.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(a, socklen_t(a.pointee.sa_len), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: buf)
            }
        }
        return nil
    }

    func openFDCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    // MARK: 来源地址

    /// 内部监听只看得到回环；经 IPv6 回环连进来，服务端看到的必须是 ::1 而不是转接用的 127.0.0.1。
    @Test func realSourceAddressReachesHandler() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        for (host, expected) in [("::1", "::1"), ("127.0.0.1", "127.0.0.1")] {
            let (head, body) = try await SecureClient(host: host, port: port, key: device).send(HTTPRequest(method: "GET", path: "/host"))
            #expect(head.status == 200)
            #expect(String(decoding: body, as: UTF8.self) == expected)
        }
    }

    /// 登记只认 127.0.0.1 来的、代次相同的连接。
    @Test func originRequiresLoopbackAndGeneration() throws {
        let door = try KernelFrontDoor(port: 0) { _ in true }
        defer { door.stop() }
        door.registerForTesting(port: 50000, host: "192.168.1.9", connection: 1, generation: 3)
        func ep(_ host: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(host), port: 50000) }
        #expect(door.origin(of: ep("127.0.0.1"), generation: 3) == "192.168.1.9")
        #expect(door.origin(of: ep("127.0.0.1"), generation: 4) == nil)
        #expect(door.origin(of: ep("127.0.0.2"), generation: 3) == nil)
        #expect(door.origin(of: ep("::1"), generation: 3) == nil)
    }

    /// 登录失败计数按真实来源：::1 被拒绝后，127.0.0.1 照常可用。
    @Test func blockingUsesRealSourceAddress() async throws {
        let saved = SecureServer.failureLimit
        SecureServer.failureLimit = 3
        defer { SecureServer.failureLimit = saved }
        final class Events: @unchecked Sendable { var list: [String] = [] }
        let events = Events()
        let server = makeServer()
        server.onSecurityEvent = { events.list.append($0) }
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        for _ in 0..<3 {
            let wrong = SecureClient(host: "::1", port: port,
                key: TransportSecurity.KeyEntry(identity: "d:device-1", key: TransportSecurity.randomKey()))
            _ = try? await wrong.send(HTTPRequest(method: "GET", path: "/host"))
        }
        await #expect(throws: (any Error).self) {
            _ = try await SecureClient(host: "::1", port: port, key: self.device).send(HTTPRequest(method: "GET", path: "/host"))
        }
        let (head, _) = try await SecureClient(host: "127.0.0.1", port: port, key: device).send(HTTPRequest(method: "GET", path: "/host"))
        #expect(head.status == 200)
        #expect(events.list.contains { $0.contains("0000:0000:0000:0000::/64") && $0.contains("已拒绝") })
        #expect(!events.list.contains { $0.contains("127.0.0.1") })
    }

    // MARK: 关闭与清理

    /// 正常结束、客户端中途断开、只连不握手之后，转发线程都退出、登记清空；停止时正在推送的连接也被关掉，
    /// 线程确实退出（停止后仍拿着前门核对），对外端口不再接受，文件描述符不增加。
    @Test func connectionsAndStopCleanUp() async throws {
        let saved = (KernelFrontDoor.lingerSeconds, SecureServer.handshakeSeconds)
        KernelFrontDoor.lingerSeconds = 1
        defer { KernelFrontDoor.lingerSeconds = saved.0; SecureServer.handshakeSeconds = saved.1 }
        // 预热：Network 框架第一次用时会长期打开一个网络策略描述符，不算泄漏
        do {
            let warm = makeServer()
            try await warm.start(keys: [device])
            _ = try await SecureClient(host: "127.0.0.1", port: try #require(warm.port), key: device).send(HTTPRequest(method: "GET", path: "/host"))
            warm.stop()
        }
        try await Task.sleep(for: .milliseconds(300))
        let fdBefore = openFDCount()
        let server = makeServer()
        try await server.start(keys: [device])
        var door: KernelFrontDoor! = try #require(server.frontDoorForTesting)
        let port = try #require(server.port)
        let client = SecureClient(host: "127.0.0.1", port: port, key: device)
        for _ in 0..<5 { _ = try await client.send(HTTPRequest(method: "GET", path: "/host")) }
        for _ in 0..<3 {
            let (_, stream) = try await client.open(HTTPRequest(method: "GET", path: "/big"))
            var got = 0
            for try await chunk in stream { got += chunk.count; if got > 1_000_000 { break } }
        }
        // 只连不握手就关：对方发来结束后，内部要到认证时限才放弃，这里把时限调短
        SecureServer.handshakeSeconds = 0.5
        for _ in 0..<3 { _ = tcpConnect("127.0.0.1", port) }
        #expect(await eventually { door.activeCount == 0 })
        #expect(door.registrationCount == 0)

        let (_, hanging) = try await client.open(HTTPRequest(method: "GET", path: "/big"))
        var iterator = hanging.makeAsyncIterator()
        _ = try await iterator.next()
        #expect(door.activeCount == 1)
        server.stop()
        #expect(server.frontDoorForTesting == nil)
        #expect(await eventually { door.activeCount == 0 })
        #expect(door.registrationCount == 0)
        #expect(tcpConnect("127.0.0.1", port) == ECONNREFUSED)
        door = nil   // 放掉前门（停止通知用的管道随之关闭）
        #expect(await eventually { openFDCount() <= fdBefore })
    }

    /// 停止通知能打断还在连内部监听的线程：对一个排满的监听非阻塞连接，收到停止通知立刻返回。
    @Test func connectAbortsOnStop() async throws {
        let l = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(l) }
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(l, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(l, 1)
        var ss = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(l, $0, &len) } }
        a.sin_port = KernelFrontDoor.port(of: ss).bigEndian
        // 先把排队位置占满（不 accept）
        var fillers: [Int32] = []
        defer { fillers.forEach { close($0) } }
        for _ in 0..<4 {
            let f = socket(AF_INET, SOCK_STREAM, 0)
            _ = fcntl(f, F_SETFL, O_NONBLOCK)
            _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(f, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            fillers.append(f)
        }
        try await Task.sleep(for: .milliseconds(100))
        var p: [Int32] = [0, 0]
        pipe(&p)
        defer { close(p[0]); close(p[1]) }
        let u = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(u) }
        _ = fcntl(u, F_SETFL, O_NONBLOCK)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { var b: UInt8 = 1; _ = write(p[1], &b, 1) }
        let start = Date()
        let ok = KernelFrontDoor.connectNonBlocking(u, &a, stop: p[0], seconds: 5)
        let took = Date().timeIntervalSince(start)
        // 排满时连接挂起（实测 macOS 排队上限 1 时第二个起就挂起），停止通知一到就返回失败
        #expect(!ok)
        #expect(took >= 0.25 && took < 2)
    }

    // MARK: 挂断不丢数据

    /// 内部一侧写完就整个关闭，外面慢慢读：回应必须完整到达。
    /// `junk` 时对方在内部关闭之后又分两次发来几个字节：第一次写给内部会引来重置，第二次写会失败。
    /// 曾经往内部写失败就整条结束，前门缓冲里还没送出的回应被丢掉（b3bf161 的旧代码在 1 MB 带多余字节这一组实测必定截断）。
    /// 注：内部还没写完就收到多余字节的组合不测——内部带着未读数据关闭会发重置，内核丢掉已收未读的数据，
    /// 这是 TCP 本身的行为，直接用 Network 框架对外时也一样。
    /// 各组参数逐个运行（曾经 4 组并行时约 135 轮卡过 1 次）；客户端读设 30 秒超时，卡住记为失败并打出诊断。
    @Test(.serialized, arguments: [(200, true), (1024, true), (1024, false), (8192, false)]) func internalCloseWithSlowReaderDeliversEverything(kilobytes: Int, junk: Bool) async throws {
        let payload = Data((0..<(kilobytes * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })
        let server = PlainHTTPServer(port: 0) { _, _ in .full(HTTPResponseHead(status: 200), payload) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.actualPort)
        let fd = rawConnect("127.0.0.1", port)
        try #require(fd >= 0)
        defer { close(fd) }
        var small: Int32 = 16 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let request = Array("GET / HTTP/1.1\r\nhost: x\r\n\r\n".utf8)
        #expect(write(fd, request, request.count) == request.count)
        // 先不读，让内部写完（能写完的话）并关闭、前门缓冲满着；再发几个多余字节
        try await Task.sleep(for: .milliseconds(500))
        if junk {
            let extra = Array("XXXX".utf8)
            _ = write(fd, extra, extra.count)
            try await Task.sleep(for: .milliseconds(150))
            _ = write(fd, extra, extra.count)
        }
        try await Task.sleep(for: .milliseconds(300))
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var reads = 0
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                let report = "30 秒没有收到数据也没有结束（已收 \(response.count) 字节）\n" + Self.diagnostics(server: server, port: port)
                print(report)
                Issue.record(Comment(rawValue: report))
                break
            }
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
            reads += 1
            if reads % 16 == 0 { usleep(20_000) }   // 慢慢读
        }
        let split = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        let body = response[split.upperBound...]
        #expect(body.count == payload.count)
        #expect(body == payload)
    }

    /// 卡住时的诊断：本机相关连接（状态、收发队列）、前门活动转发数、各转发最近状态。
    static func diagnostics(server: PlainHTTPServer, port: UInt16) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat"); p.arguments = ["-anv", "-p", "tcp"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let lines = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").filter { $0.contains(".\(port) ") || $0.contains("\(getpid())") }
        let door = server.frontDoorForTesting
        return "netstat：\n" + lines.joined(separator: "\n")
            + "\n前门活动转发 \(door?.activeCount ?? -1)，各转发状态 \(door?.relayStatesForTesting ?? [:])"
    }

    // MARK: 上限与时限

    /// 同一来源超过上限的连接直接关闭；释放后又能连。一次几十个并发请求（刷封面）在默认上限下全部成功。
    @Test func perSourceLimitAndBurstOfRequests() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        let door = try #require(server.frontDoorForTesting)

        let client = SecureClient(host: "127.0.0.1", port: port, key: device)
        let ok = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<48 {
                group.addTask { (try? await client.send(HTTPRequest(method: "GET", path: "/host")))?.0.status == 200 }
            }
            var n = 0
            for await r in group where r { n += 1 }
            return n
        }
        #expect(ok == 48)
        #expect(await eventually { door.activeCount == 0 })

        let saved = KernelFrontDoor.maxPerSource
        KernelFrontDoor.maxPerSource = 3
        defer { KernelFrontDoor.maxPerSource = saved }
        let held = (0..<3).map { _ in rawConnect("127.0.0.1", port) }
        defer { held.forEach { if $0 >= 0 { close($0) } } }
        #expect(held.allSatisfy { $0 >= 0 })
        #expect(await eventually { door.activeCount == 3 })
        let extra = rawConnect("127.0.0.1", port)
        try #require(extra >= 0)
        #expect(waitClosed(extra, seconds: 2))    // 超出上限：马上被关
        close(extra)
        // 另一个来源（IPv6 回环）不受这个来源的计数影响
        let other = rawConnect("::1", port)
        try #require(other >= 0)
        #expect(await eventually { door.activeCount == 4 })
        close(other)
    }

    /// 只连不握手：到认证时限断开（不计入登录失败）。
    @Test func handshakeTimeout() async throws {
        let saved = (SecureServer.handshakeSeconds, KernelFrontDoor.lingerSeconds)
        SecureServer.handshakeSeconds = 0.5
        KernelFrontDoor.lingerSeconds = 1
        defer { SecureServer.handshakeSeconds = saved.0; KernelFrontDoor.lingerSeconds = saved.1 }
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        let door = try #require(server.frontDoorForTesting)
        let fd = rawConnect("127.0.0.1", port)
        try #require(fd >= 0)
        let start = Date()
        #expect(waitClosed(fd, seconds: 5))
        #expect(Date().timeIntervalSince(start) < 3)
        close(fd)
        #expect(await eventually { door.activeCount == 0 })
        // 时限断开不算登录失败：照常能连
        let (head, _) = try await SecureClient(host: "127.0.0.1", port: port, key: device).send(HTTPRequest(method: "GET", path: "/host"))
        #expect(head.status == 200)
    }

    /// 请求头迟迟不发完：到请求时限断开。
    @Test func requestHeaderTimeout() async throws {
        let saved = (PlainHTTPServer.requestSeconds, KernelFrontDoor.lingerSeconds)
        PlainHTTPServer.requestSeconds = 0.5
        KernelFrontDoor.lingerSeconds = 1
        defer { PlainHTTPServer.requestSeconds = saved.0; KernelFrontDoor.lingerSeconds = saved.1 }
        let server = PlainHTTPServer(port: 0) { _, _ in .status(200) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.actualPort)
        let door = try #require(server.frontDoorForTesting)
        let fd = rawConnect("127.0.0.1", port)
        try #require(fd >= 0)
        let partial = Array("GET / HTTP/1.1\r\nhost:".utf8)
        _ = write(fd, partial, partial.count)
        let start = Date()
        #expect(waitClosed(fd, seconds: 5))
        #expect(Date().timeIntervalSince(start) < 3)
        close(fd)
        #expect(await eventually { door.activeCount == 0 })
    }

    /// 对方不再读：有数据却写不出去，到停滞时限断开，线程退出。
    @Test func stalledReaderIsDropped() async throws {
        let saved = KernelFrontDoor.stallSeconds
        KernelFrontDoor.stallSeconds = 1
        defer { KernelFrontDoor.stallSeconds = saved }
        let payload = Data(repeating: 9, count: 32 * 1024 * 1024)
        let server = PlainHTTPServer(port: 0) { _, _ in .full(HTTPResponseHead(status: 200), payload) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.actualPort)
        let door = try #require(server.frontDoorForTesting)
        let fd = rawConnect("127.0.0.1", port)
        try #require(fd >= 0)
        defer { close(fd) }
        let request = Array("GET / HTTP/1.1\r\nhost: x\r\n\r\n".utf8)
        _ = write(fd, request, request.count)
        #expect(await eventually { door.activeCount == 1 })
        #expect(await eventually(6) { door.activeCount == 0 })
    }

    // MARK: 换密钥与内部端口

    /// 换密钥表后对外端口不变，内部换新端口；新连接照常可用。
    @Test func keyUpdateSwitchesInternalListener() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        let firstInternal = try #require(server.internalPort)
        let other = TransportSecurity.KeyEntry(identity: "d:device-2", key: TransportSecurity.randomKey())
        try await server.start(keys: [device, other])
        #expect(server.port == port)
        #expect(server.internalPort != firstInternal)
        let (head, _) = try await SecureClient(host: "127.0.0.1", port: port, key: other).send(HTTPRequest(method: "GET", path: "/host"))
        #expect(head.status == 200)
    }

    /// 并发换密钥：一个一个执行，最后前门指向的就是正在用的内部监听，连接照常可用。
    @Test func concurrentKeyUpdatesStayConsistent() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        let keys = (0..<12).map { TransportSecurity.KeyEntry(identity: "d:k\($0)", key: TransportSecurity.randomKey()) }
        await withTaskGroup(of: Void.self) { group in
            for k in keys { group.addTask { try? await server.start(keys: [self.device, k]) } }
        }
        let door = try #require(server.frontDoorForTesting)
        #expect(door.targetPortForTesting == server.internalPort)
        let (head, _) = try await SecureClient(host: "127.0.0.1", port: port, key: device).send(HTTPRequest(method: "GET", path: "/host"))
        #expect(head.status == 200)
    }

    /// 内部监听只绑 127.0.0.1：经本机局域网地址连内部端口被拒，连对外端口可以（对照，证明这条路本身通）。
    @Test func internalPortIsLoopbackOnly() async throws {
        let server = makeServer()
        try await server.start(keys: [device])
        defer { server.stop() }
        let port = try #require(server.port)
        let internalPort = try #require(server.internalPort)
        #expect(tcpConnect("127.0.0.1", internalPort) == 0)
        guard let lan = lanAddress() else { return }   // 没有局域网地址的机器上无从验证
        try #require(tcpConnect(lan, port) == 0, "对照：经 \(lan) 连对外端口应当能连上")
        #expect(tcpConnect(lan, internalPort) == ECONNREFUSED)
    }

    /// 管理网页端口：来源地址照实，客户端发完请求半关闭写方向，仍能收到完整回应。
    @Test func plainHTTPSourceAndHalfClose() async throws {
        let server = PlainHTTPServer(port: 0) { host, _ in .full(HTTPResponseHead(status: 200), Data(host.utf8)) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.actualPort)
        let door = try #require(server.frontDoorForTesting)
        for host in ["::1", "127.0.0.1"] {
            let fd = rawConnect(host, port)
            try #require(fd >= 0)
            let request = Array("GET / HTTP/1.1\r\nhost: x\r\n\r\n".utf8)
            #expect(write(fd, request, request.count) == request.count)
            shutdown(fd, SHUT_WR)
            var response = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while true { let n = read(fd, &buf, buf.count); if n <= 0 { break }; response.append(contentsOf: buf[0..<n]) }
            close(fd)
            let text = String(decoding: response, as: UTF8.self)
            #expect(text.hasPrefix("HTTP/1.1 200"))
            #expect(text.hasSuffix("\r\n\r\n" + host))
        }
        #expect(await eventually { door.activeCount == 0 })
    }

    /// 来源地址的写法：IPv4 映射地址写成普通 IPv4，日志好读，限速与内网判断都认得。
    @Test func frontDoorHostFormatting() {
        func make(_ text: String) -> sockaddr_storage {
            var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            _ = getaddrinfo(text, "1", &hints, &res)
            defer { freeaddrinfo(res) }
            var ss = sockaddr_storage()
            memcpy(&ss, res!.pointee.ai_addr, Int(res!.pointee.ai_addrlen))
            return ss
        }
        #expect(KernelFrontDoor.host(of: make("::ffff:192.168.100.91")) == "192.168.100.91")
        #expect(KernelFrontDoor.host(of: make("192.168.100.91")) == "192.168.100.91")
        #expect(KernelFrontDoor.host(of: make("fd29::1")) == "fd29::1")
        #expect(KernelFrontDoor.port(of: make("::1")) == 1)
    }
}
}
