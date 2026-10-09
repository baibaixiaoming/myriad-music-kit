import Foundation
import Network
import Testing
@testable import SecureTransport

private final class TestClock: @unchecked Sendable {
    let lock = NSLock()
    var time: Duration = .zero
    var waits: [UUID: (Duration, CheckedContinuation<Void, Error>)] = [:]
    /// 累计挂上的计时器个数。被测代码先算时长、再另起任务挂计时器，挂上的时刻不确定；
    /// 拨钟前要等“该挂的都挂上、旧的都撤掉”，否则拨钟插在中间会把到期点推后，等待永远不结束。
    var registered = 0
    var registrations: Int { lock.withLock { registered } }
    var clock: TransportClock { .init(now: { self.lock.withLock { self.time } }, sleep: { try await self.sleep($0) }) }
    var deadlines: [Duration] { lock.withLock { waits.values.map { $0.0 } } }
    func sleep(_ delay: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waits[id] = (time + delay, c); registered += 1; return false
                }
                if cancelled { c.resume(throwing: CancellationError()) }
            }
        } onCancel: { self.lock.withLock { self.waits.removeValue(forKey: id) }?.1.resume(throwing: CancellationError()) }
    }
    func advance(_ delay: Duration) {
        let ready = lock.withLock {
            time += delay
            return waits.filter { $0.value.0 <= time }.keys.compactMap { waits.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
}
private final class Wire: @unchecked Sendable {
    typealias VoidCallback = @Sendable (Result<Void, Error>) -> Void
    typealias DataCallback = @Sendable (Result<Data?, Error>) -> Void
    let lock = NSLock()
    var blockStart = false, blockSend = false
    var startCallback: VoidCallback?, sendCallback: VoidCallback?, receiveCallback: DataCallback?
    var receives = 0, cancels = 0
    var pieces: [Data?] = []
    var hooks: ClientIOHooks {
        .init(start: { done in
            if self.lock.withLock({ self.startCallback = done; return self.blockStart }) { return }
            done(.success(()))
        }, send: { _, done in
            if self.lock.withLock({ self.sendCallback = done; return self.blockSend }) { return }
            done(.success(()))
        }, receive: { done in
            let piece = self.lock.withLock { () -> Data?? in
                self.receives += 1
                if self.pieces.isEmpty { self.receiveCallback = done; return nil }
                return .some(self.pieces.removeFirst())
            }
            if let piece { done(.success(piece)) }
        }, cancel: { self.lock.withLock { self.cancels += 1 } })
    }
    func makeIO(_ clock: TestClock) -> ConnectionIO {
        ConnectionIO(NWConnection(host: "127.0.0.1", port: 1, using: .tcp), queue: .global(),
                     clientMode: true, clock: clock.clock, hooks: hooks)
    }
}
/// 等任务结果；测试被时限取消时连带取消这个任务，不让等待拖住整个测试进程。
private func value<T: Sendable>(_ task: Task<T, Error>) async throws -> T {
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
/// 等计时器到位再拨钟：只剩 `expected` 这些计时器，且 20 毫秒内没有新挂上或撤掉的。
/// 被测代码先算时长、再另起任务挂计时器；上一阶段的计时器在完成时撤掉（若它的任务还没开始就被取消，则根本不会挂上），
/// 所以挂上的个数和时刻都不确定。只看“有没有这个到期点”会把上一阶段没撤完的同值计时器当成本阶段的，
/// 拨钟后本阶段计时器才挂上，到期点被推后，等待永远不结束（曾约每 10 轮卡死 1 次）。
private func settleTimers(_ clock: TestClock, _ expected: [Duration], _ condition: () -> Bool = { true }) async throws {
    for _ in 0..<500 {
        if condition(), clock.deadlines == expected {
            let before = clock.registrations
            try await Task.sleep(for: .milliseconds(20))
            if condition(), clock.deadlines == expected, clock.registrations == before { return }
        } else {
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    Issue.record("计时器未到位：\(clock.deadlines)"); throw CancellationError()
}
private func settle(_ condition: () -> Bool) async throws {
    for _ in 0..<10000 { if condition() { return }; await Task.yield() }
    Issue.record("未到达异步检查点"); throw CancellationError()
}
@Suite(.serialized, .timeLimit(.minutes(1))) struct ClientFlowTests {
    private func client(_ clock: TestClock) -> SecureClient {
        var client = SecureClient(host: "unused", port: 1, key: .init(identity: "test", key: Data(repeating: 1, count: 32)))
        client.clock = clock.clock
        return client
    }
    let request = HTTPRequest(method: "GET", path: "/audio")

    @Test(arguments: [0, 1, 2]) func cancellationCoversHandshakeSendAndHeaders(_ phase: Int) async throws {
        let clock = TestClock(), wire = Wire()
        wire.blockStart = phase == 0; wire.blockSend = phase == 1
        let io = wire.makeIO(clock)
        let work = Task { try await client(clock).open(request, using: io) }
        try await settle { io.clientWaitCount == 1 && wire.lock.withLock {
            phase == 0 ? wire.startCallback != nil : (phase == 1 ? wire.sendCallback != nil : wire.receiveCallback != nil)
        } }
        work.cancel()
        await #expect(throws: CancellationError.self) { _ = try await value(work) }
        #expect(io.clientWaitCount == 0)
        #expect(wire.lock.withLock { wire.cancels } > 0)
        // 底层在取消后才回调，不得重复恢复。
        wire.lock.withLock { wire.startCallback }?(.success(()))
        wire.lock.withLock { wire.sendCallback }?(.success(()))
        wire.lock.withLock { wire.receiveCallback }?(.success(Data()))
    }

    @Test(arguments: [0, 1, 2]) func stageTimeoutsUseInjectedClock(_ phase: Int) async throws {
        let clock = TestClock(), wire = Wire()
        wire.blockStart = phase == 0; wire.blockSend = phase == 1
        let io = wire.makeIO(clock)
        let work = Task { try await client(clock).open(request, using: io) }
        let timeout: Duration = phase == 1 ? .seconds(5) : .seconds(10)
        // 到达本阶段时，前面阶段的计时器已撤掉，只剩本阶段这一个
        try await settleTimers(clock, [timeout]) { io.clientWaitCount == 1 }
        clock.advance(timeout)
        await #expect(throws: TransportError.timeout) { _ = try await value(work) }
        #expect(io.clientWaitCount == 0)
    }

    @Test func bodyIdleTimeoutAndCancellationCloseConnection() async throws {
        for cancel in [false, true] {
            let clock = TestClock(), wire = Wire()
            wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8)]
            let io = wire.makeIO(clock)
            let (_, body) = try await client(clock).open(request, using: io)
            let work = Task { var iterator = body.makeAsyncIterator(); return try await iterator.next() }
            // 握手、发送、响应头的计时器已撤掉，只剩等正文的这一个
            try await settleTimers(clock, [.seconds(10)]) { io.clientWaitCount == 1 }
            if cancel { work.cancel(); await #expect(throws: CancellationError.self) { _ = try await value(work) } }
            else { clock.advance(.seconds(10)); await #expect(throws: TransportError.timeout) { _ = try await value(work) } }
            #expect(io.clientWaitCount == 0)
            #expect(wire.lock.withLock { wire.cancels } > 0)
        }
    }

    @Test func headersHaveAbsoluteDeadlineDespiteTrickle() async throws {
        let clock = TestClock(), wire = Wire()
        // 使用同一时钟的 IO；分段头不能把十秒延长。
        let actualIO = wire.makeIO(clock)
        let work = Task { try await client(clock).open(request, using: actualIO) }
        try await settleTimers(clock, [.seconds(10)]) { wire.lock.withLock { wire.receiveCallback != nil } }
        clock.advance(.seconds(6))
        wire.lock.withLock { let c = wire.receiveCallback; wire.receiveCallback = nil; return c }?(.success(Data("HTTP/1.1 200".utf8)))
        // 第二次读响应头的计时器按剩余 4 秒挂上，到期点仍是 10 秒
        try await settleTimers(clock, [.seconds(10)]) { wire.lock.withLock { wire.receives == 2 && wire.receiveCallback != nil } }
        clock.advance(.seconds(4))
        await #expect(throws: TransportError.timeout) { _ = try await value(work) }
    }

    @Test func slowConsumerHasDemandBackpressureAndLosesNoBytes() async throws {
        let clock = TestClock(), wire = Wire()
        let payload = (0..<12).map { Data(repeating: UInt8($0), count: 64 * 1024) }
        wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.reduce(0) { $0 + $1.count })\r\n\r\n".utf8)] + payload.map(Optional.some)
        let io = wire.makeIO(clock)
        let (_, body) = try await client(clock).open(request, using: io)
        #expect(wire.lock.withLock { wire.receives } == 1)
        clock.advance(.seconds(100)) // 写盘慢而没有正在等待正文，不应计无进展超时。
        var iterator = body.makeAsyncIterator(), output = Data()
        for expected in payload {
            let count = wire.lock.withLock { wire.receives }
            for _ in 0..<20 { await Task.yield() }
            #expect(wire.lock.withLock { wire.receives } == count)
            let actual = try #require(try await iterator.next())
            #expect(actual == expected); output.append(actual)
            clock.advance(.seconds(100))
        }
        #expect(try await iterator.next() == nil)
        #expect(output == payload.reduce(into: Data()) { $0.append($1) })
    }

    @Test func knownLengthRejectsEarlyEOFAndExtraBytes() async throws {
        for bytes in [Data([1, 2]), Data([1, 2, 3, 4, 5])] {
            let clock = TestClock(), wire = Wire()
            wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8), bytes, nil]
            let (_, body) = try await client(clock).open(request, using: wire.makeIO(clock))
            await #expect(throws: TransportError.self) { for try await _ in body {} }
        }
    }

    @Test func callbackCancellationAndTimeoutRaceOnlyCompletesOnce() async throws {
        for _ in 0..<100 {
            let clock = TestClock(), wire = Wire(); wire.blockSend = true
            let io = wire.makeIO(clock)
            let work = Task { try await io.send(Data([1]), timeout: .seconds(5)) }
            try await settle { wire.lock.withLock { wire.sendCallback != nil } }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { work.cancel() }
                group.addTask { wire.lock.withLock { wire.sendCallback }?(.success(())) }
                group.addTask { clock.advance(.seconds(5)) }
            }
            _ = try? await work.value
            #expect(io.clientWaitCount == 0)
        }
    }
    @Test func malformedAndOversizedHeadersAreTerminalProtocolErrors() async throws {
        let examples = [
            "garbage\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: nope\r\n\r\n",
            "HTTP/1.1 200 OK\r\nX: " + String(repeating: "x", count: 65_536) + "\r\n\r\n",
        ]
        for header in examples {
            let clock = TestClock(), wire = Wire(); wire.pieces = [Data(header.utf8)]
            await #expect(throws: TransportError.malformed) { _ = try await client(clock).open(request, using: wire.makeIO(clock)) }
        }
    }

    @Test func alreadyCancelledTaskNeverStartsNetworkOperation() async throws {
        let clock = TestClock(), wire = Wire()
        let actualIO = wire.makeIO(clock)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client(clock).open(request, using: actualIO)
        }
        await #expect(throws: CancellationError.self) { _ = try await value(work) }
        #expect(wire.lock.withLock { wire.startCallback == nil && wire.sendCallback == nil && wire.receives == 0 })
        #expect(actualIO.clientWaitCount == 0)
    }

    @Test(arguments: [0, 1, 2]) func terminalStateClosesRetainedBodyWithoutAnotherRead(_ event: Int) async throws {
        let clock = TestClock(), wire = Wire()
        wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8), Data([1, 2, 3])]
        let io = wire.makeIO(clock)
        let (_, body) = try await client(clock).open(request, using: io)
        var iterator = body.makeAsyncIterator()
        #expect(try await iterator.next() == Data([1, 2, 3]))
        #expect(io.clientWaitCount == 0)
        let reads = wire.lock.withLock { wire.receives }
        let state: NWConnection.State = event == 0 ? .failed(.posix(.ECONNRESET))
            : event == 1 ? .cancelled : .waiting(.posix(.ENETDOWN))
        // 经过真正安装的生命周期回调；握手的 done 此时早已完成。
        io.connection.stateUpdateHandler?(state)
        #expect(wire.lock.withLock { wire.cancels } == 1)
        #expect(wire.lock.withLock { wire.receives } == reads)
        io.connection.stateUpdateHandler?(.cancelled)
        io.cancel()
        #expect(wire.lock.withLock { wire.cancels } == 1)
        await #expect(throws: TransportError.self) { _ = try await iterator.next() }
        withExtendedLifetime(body) {}
    }

    @Test func connectionStateFailureWakesPendingReceiveOnlyOnce() async throws {
        let clock = TestClock(), wire = Wire()
        wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)]
        let io = wire.makeIO(clock)
        let (_, body) = try await client(clock).open(request, using: io)
        let work = Task { var iterator = body.makeAsyncIterator(); return try await iterator.next() }
        try await settle { io.clientWaitCount == 1 && wire.lock.withLock { wire.receiveCallback != nil } }
        io.connection.stateUpdateHandler?(.failed(.posix(.ECONNRESET)))
        await #expect(throws: TransportError.self) { _ = try await value(work) }
        wire.lock.withLock { wire.receiveCallback }?(.success(Data([1])))
        io.connection.stateUpdateHandler?(.cancelled)
        clock.advance(.seconds(10))
        #expect(io.clientWaitCount == 0)
        #expect(wire.lock.withLock { wire.cancels } == 1)
    }

    @Test func lastKnownBodyPieceClosesWithoutRequestingEOF() async throws {
        let clock = TestClock(), wire = Wire()
        wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n".utf8), Data([1, 2, 3])]
        let io = wire.makeIO(clock)
        let (_, body) = try await client(clock).open(request, using: io)
        var iterator = body.makeAsyncIterator()
        #expect(try await iterator.next() == Data([1, 2, 3]))
        #expect(wire.lock.withLock { wire.cancels } == 1)
        #expect(wire.lock.withLock { wire.receives } == 2)
        #expect(try await iterator.next() == nil)
        withExtendedLifetime(body) {}
    }

    @Test func EOFWithFinalBytesReleasesConnectionAndPreservesBytes() async throws {
        let clock = TestClock(), wire = Wire()
        let io = wire.makeIO(clock)
        let work = Task { try await io.receive(timeout: .seconds(10)) }
        try await settle { wire.lock.withLock { wire.receiveCallback != nil } }
        let done = try #require(wire.lock.withLock { wire.receiveCallback })
        io.clientReceived(Data([1, 2, 3]), complete: true, error: nil, done: done)
        #expect(try await value(work) == Data([1, 2, 3]))
        #expect(wire.lock.withLock { wire.cancels } == 1)
        #expect(try await io.receive() == nil)
        #expect(wire.lock.withLock { wire.receives } == 1)
    }

    @Test func droppingUnreadBodyClosesConnection() async throws {
        let clock = TestClock(), wire = Wire()
        wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n".utf8)]
        let io = wire.makeIO(clock)
        do {
            let (_, body) = try await client(clock).open(request, using: io)
            withExtendedLifetime(body) {}
        }
        #expect(wire.lock.withLock { wire.cancels } == 1)
        #expect(wire.lock.withLock { wire.receives } == 1)
    }

    @Test func lateEOFAfterFailureCannotTurnFailureIntoSuccess() async throws {
        let clock = TestClock(), wire = Wire()
        let io = wire.makeIO(clock)
        io.clientStateChanged(.failed(.posix(.ECONNRESET)))
        io.clientReceived(nil, complete: true, error: nil, done: { _ in })
        await #expect(throws: TransportError.self) { _ = try await io.receive() }
        #expect(wire.lock.withLock { wire.cancels } == 1)
    }

}
