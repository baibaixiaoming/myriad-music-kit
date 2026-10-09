import Foundation

/// 让一组异步操作按提交顺序一个一个执行（上一个结束、无论成败，下一个才开始）。
/// 用于“登记设备 + 换密钥表”：两台设备同时登录时，后装的密钥表一定包含两台。
actor AsyncSerial {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
