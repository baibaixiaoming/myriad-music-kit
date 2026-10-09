import Foundation
import MusicAPI
import SecureTransport

/// 账号与设备：密码身份只能换设备密钥；之后每台设备用自己的密钥连接（协议第 2 节）。
/// 设备登记存在 devices.json（600）。改动先写文件，写成功才改内存，半途失败不会留下不一致。
actor AccountService {
    struct Device: Codable, Sendable, Equatable {
        let id: String
        let name: String
        /// 32 字节随机密钥（Base64）。
        let key: String
        let createdAt: Date
    }

    enum Caller: Sendable, Equatable {
        /// 用密码连上来的（只能登录换设备密钥）。
        case password
        case device(String)
    }

    /// 最多保留的设备数：超过时去掉最早登记的。
    static let maxDevices = 200

    let account: Account
    private let passwordEntry: TransportSecurity.KeyEntry
    private let devicesFile: URL
    private var devices: [Device]

    /// 读取（或生成）账号与设备表。密码派生密钥要 60 万次运算，放在调用方的后台任务里做。
    init(paths: ServerPaths) throws {
        account = try Account.loadOrCreate(at: paths.accountFile)
        passwordEntry = TransportSecurity.passwordEntry(username: account.username, password: account.password)
        devicesFile = paths.devicesFile
        if let data = try PrivateFile.read(devicesFile) {
            if let list = try? JSONDecoder.iso.decode([Device].self, from: data) {
                devices = list
            } else {
                serverLog("账号", "设备表无法识别，已改名留底；各设备需要重新用密码登录")
                PrivateFile.setAside(devicesFile)
                devices = []
            }
        } else {
            devices = []
        }
    }

    var user: API.UserInfo { API.UserInfo(id: account.username, username: account.username, displayName: account.username) }

    var deviceCount: Int { devices.count }

    /// 加密端口要登记的全部密钥：密码身份 + 每台设备。
    func keyTable() -> [TransportSecurity.KeyEntry] {
        [passwordEntry] + devices.compactMap { d in
            Data(base64Encoded: d.key).map { TransportSecurity.KeyEntry(identity: "d:\(d.id)", key: $0) }
        }
    }

    func identify(_ identity: String) -> Caller? {
        if identity == passwordEntry.identity { return .password }
        guard identity.hasPrefix("d:") else { return nil }
        let id = String(identity.dropFirst(2))
        return devices.contains { $0.id == id } ? .device(id) : nil
    }

    /// 登记一台新设备并保存。
    func register(name: String) throws -> Device {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let device = Device(id: UUID().uuidString.lowercased(), name: clean.isEmpty ? "未命名设备" : clean,
                            key: TransportSecurity.randomKey().base64EncodedString(), createdAt: Date())
        var next = devices + [device]
        if next.count > Self.maxDevices { next.removeFirst(next.count - Self.maxDevices) }
        try save(next)
        devices = next
        serverLog("账号", "登记新设备：\(device.name)（共 \(next.count) 台）")
        return device
    }

    /// 撤销刚登记的设备（换密钥表失败时回滚用）。
    func remove(id: String) {
        let next = devices.filter { $0.id != id }
        guard next.count != devices.count else { return }
        do {
            try save(next)
            devices = next
        } catch {
            serverLog("账号", "撤销设备失败：\(error)")
        }
    }

    private func save(_ list: [Device]) throws {
        try PrivateFile.write(try JSONEncoder.iso.encode(list), to: devicesFile)
    }
}
