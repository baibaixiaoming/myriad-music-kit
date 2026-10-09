import Foundation
import Network
import Testing
@testable import SecureTransport

private final class DeadlineClock: @unchecked Sendable {
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
    func elapseWithoutCallbacks(_ delay: Duration) { lock.withLock { time += delay } }
    func advance(_ delay: Duration) {
        let ready = lock.withLock {
            time += delay
            return waits.filter { $0.value.0 <= time }.keys.compactMap { waits.removeValue(forKey: $0)?.1 }
        }
        ready.forEach { $0.resume() }
    }
}
private final class DeadlineWire: @unchecked Sendable {
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
    func makeIO(_ clock: DeadlineClock) -> ConnectionIO {
        ConnectionIO(NWConnection(host: "127.0.0.1", port: 1, using: .tcp), queue: .global(),
                     clientMode: true, clock: clock.clock, hooks: hooks)
    }
}

private func deadlineCheckpoint(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<10000 { if condition() { return }; await Task.yield() }
    Issue.record("假连接尚未到达检查点"); throw CancellationError()
}
@Suite(.serialized) struct ClientDeadlineTests {
    private func client(_ clock: DeadlineClock) -> SecureClient {
        var c = SecureClient(host: "unused", port: 1, key: .init(identity: "test", key: Data(repeating: 1, count: 32)))
        c.clock = clock.clock
        return c
    }
    let request = HTTPRequest(method: "GET", path: "/audio")
    @Test(arguments: [0, 1, 2, 3]) func suspendedTimersRejectLateSuccessAtEveryStage(_ stage: Int) async throws {
        let clock = DeadlineClock(), wire = DeadlineWire()
        wire.blockStart = stage == 0; wire.blockSend = stage == 1
        if stage == 3 { wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8)] }
        let io = wire.makeIO(clock)
        let work = Task {
            let (_, body) = try await client(clock).open(request, using: io)
            if stage == 3 { var it = body.makeAsyncIterator(); _ = try await it.next() }
        }
        try await deadlineCheckpoint { io.clientWaitCount == 1 && wire.lock.withLock {
            stage == 0 ? wire.startCallback != nil : stage == 1 ? wire.sendCallback != nil : wire.receiveCallback != nil
        } }
        clock.elapseWithoutCallbacks(.seconds(213))
        if stage == 0 { wire.lock.withLock { wire.startCallback }?(.success(())) }
        else if stage == 1 { wire.lock.withLock { wire.sendCallback }?(.success(())) }
        else { wire.lock.withLock { wire.receiveCallback }?(.success(Data(stage == 2 ? "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8 : "data".utf8))) }
        await #expect(throws: TransportError.timeout) { try await work.value }
        #expect(io.clientWaitCount == 0 && wire.lock.withLock { wire.cancels } == 1)
    }
    @Test(arguments: [0, 1, 2, 3]) func eachStageUsesSmallerRemainingBudget(_ stage: Int) async throws {
        let clock = DeadlineClock(), wire = DeadlineWire()
        wire.blockStart = stage == 0; wire.blockSend = stage == 1
        if stage == 3 { wire.pieces = [Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n".utf8)] }
        var c = client(clock)
        c.remainingBudget = { .seconds(4) - clock.clock.now() }
        let bounded = c, io = wire.makeIO(clock)
        let work = Task {
            let (_, body) = try await bounded.open(request, using: io)
            if stage == 3 { var it = body.makeAsyncIterator(); _ = try await it.next() }
        }
        try await deadlineCheckpoint { clock.deadlines == [.seconds(4)] && io.clientWaitCount == 1 }
        clock.advance(.seconds(4))
        await #expect(throws: TransportError.timeout) { try await work.value }
        #expect(wire.lock.withLock { wire.cancels } == 1)
    }
    @Test func totalRequestBudgetDoesNotRestartBetweenStages() async throws {
        let clock = DeadlineClock(), wire = DeadlineWire()
        wire.blockStart = true; wire.blockSend = true
        var c = client(clock); c.requestTimeout = .seconds(12)
        let bounded = c, io = wire.makeIO(clock)
        let work = Task { try await bounded.open(request, using: io) }
        try await deadlineCheckpoint { clock.deadlines == [.seconds(10)] && wire.lock.withLock { wire.startCallback != nil } }
        clock.advance(.seconds(9)); wire.lock.withLock { wire.startCallback }?(.success(()))
        try await deadlineCheckpoint { clock.deadlines == [.seconds(12)] && wire.lock.withLock { wire.sendCallback != nil } }
        clock.advance(.seconds(2)); wire.lock.withLock { wire.sendCallback }?(.success(()))
        try await deadlineCheckpoint { clock.deadlines == [.seconds(12)] && wire.lock.withLock { wire.receiveCallback != nil } }
        clock.advance(.seconds(1))
        await #expect(throws: TransportError.timeout) { _ = try await work.value }
    }
    @Test(arguments: [false, true]) func residualWaitHasTimeoutAndCancellation(_ cancel: Bool) async throws {
        let clock = DeadlineClock(), wire = DeadlineWire(), io = wire.makeIO(clock)
        try await io.start(timeout: .seconds(10))
        io.clientStateChanged(.ready)
        io.clientStateChanged(.failed(.posix(.ECONNRESET)))
        // 假残余数据 receive 不回调；消费者必须有自己的有界、可取消出口。
        let work = Task { try await io.receive(timeout: .seconds(3)) }
        try await deadlineCheckpoint { io.clientWaitCount == 1 && clock.deadlines.sorted() == [.seconds(3), .seconds(10)] }
        if cancel { work.cancel(); await #expect(throws: CancellationError.self) { _ = try await work.value } }
        else { clock.advance(.seconds(3)); await #expect(throws: TransportError.timeout) { _ = try await work.value } }
        #expect(io.clientWaitCount == 0 && wire.lock.withLock { wire.cancels } == 1)
        wire.lock.withLock { wire.receiveCallback }?(.success(Data([1])))
        io.cancel()
        #expect(wire.lock.withLock { wire.cancels } == 1)
    }
    @Test func residualDrainIsBoundedEvenWithoutConsumer() async throws {
        let clock = DeadlineClock(), wire = DeadlineWire(), io = wire.makeIO(clock)
        try await io.start(timeout: .seconds(10))
        io.clientStateChanged(.ready)
        io.clientStateChanged(.failed(.posix(.ECONNRESET)))
        try await deadlineCheckpoint { clock.deadlines == [.seconds(10)] && wire.lock.withLock { wire.receiveCallback != nil } }
        clock.advance(.seconds(10))
        try await deadlineCheckpoint { wire.lock.withLock { wire.cancels } == 1 }
        #expect(io.clientWaitCount == 0)
        withExtendedLifetime(io) {}
    }
    @Test func residualDataIsDeliveredBeforeTerminalError() async throws {
        let clock = DeadlineClock(), wire = DeadlineWire(), io = wire.makeIO(clock)
        try await io.start(timeout: .seconds(10))
        io.clientStateChanged(.ready)
        io.clientStateChanged(.failed(.posix(.ECONNRESET)))
        let work = Task { try await io.receive(timeout: .seconds(3)) }
        try await deadlineCheckpoint { io.clientWaitCount == 1 }
        wire.lock.withLock { wire.receiveCallback }?(.success(Data([1, 2])))
        try await deadlineCheckpoint { wire.lock.withLock { wire.receives } == 2 }
        wire.lock.withLock { wire.receiveCallback }?(.failure(TransportError.closed))
        #expect(try await work.value == Data([1, 2]))
        await #expect(throws: TransportError.self) { _ = try await io.receive(timeout: .seconds(3)) }
        #expect(wire.lock.withLock { wire.cancels } == 1)
    }
}

extension ClientDeadlineTests {
    @Test func terminalDuringResidualRegistrationStillDeliversQueuedBytes() async throws {
        let clock = DeadlineClock(), wire = DeadlineWire(), io = wire.makeIO(clock)
        try await io.start(timeout: .seconds(10))
        io.clientStateChanged(.ready)
        io.clientStateChanged(.failed(.posix(.ECONNRESET)))
        io.residualWaitRegistered = {
            wire.lock.withLock { wire.receiveCallback }?(.success(Data([1, 2])))
            wire.lock.withLock { wire.receiveCallback }?(.failure(TransportError.closed))
        }
        #expect(try await io.receive(timeout: .seconds(3)) == Data([1, 2]))
        await #expect(throws: TransportError.self) { _ = try await io.receive(timeout: .seconds(3)) }
        #expect(io.clientWaitCount == 0 && wire.lock.withLock { wire.cancels } == 1)
    }
}
