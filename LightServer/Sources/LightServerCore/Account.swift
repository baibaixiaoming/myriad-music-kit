import Foundation
import Security
import SecureTransport

/// 唯一的用户：用户名固定 demo，第一次启动时生成随机密码，明文存在 account.json（600）里，
/// 菜单栏照着显示，方便用户与审核员输入。
public struct Account: Codable, Sendable, Equatable {
    public static let defaultUsername = "demo"

    public let username: String
    public let password: String
    public let createdAt: Date

    public init(username: String, password: String, createdAt: Date = Date()) {
        self.username = username
        self.password = password
        // 存盘用 ISO 8601（精确到秒），这里也取整到秒，读回来与原值相同
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }

    var isValid: Bool {
        TransportSecurity.normalizedUsername(username) == username && !username.isEmpty
            && password.count >= TransportSecurity.minimumPasswordLength
    }

    /// 随机密码：12 个小写字母与数字（去掉易混的 0、1、i、l、o），每 4 个用横线隔开，共 14 个字符。
    /// 读屏逐字读、手机上输入都方便；约 59 位随机性，加上协议规定的 60 万次密钥派生，足够演示用。
    static func generatePassword() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        var chars: [Character] = []
        while chars.count < 12 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { continue }
            // 拒绝采样，避免取模偏差
            let limit = UInt8(256 - 256 % alphabet.count)
            guard byte < limit else { continue }
            chars.append(alphabet[Int(byte) % alphabet.count])
        }
        return stride(from: 0, to: 12, by: 4).map { String(chars[$0 ..< $0 + 4]) }.joined(separator: "-")
    }

    /// 读取账号；没有就生成一个并保存。文件坏了改名留底后重新生成（已登录的设备用各自的设备密钥，不受影响）。
    static func loadOrCreate(at url: URL) throws -> Account {
        if let data = try PrivateFile.read(url) {
            if let account = try? JSONDecoder.iso.decode(Account.self, from: data), account.isValid { return account }
            serverLog("账号", "账号文件无法识别，已改名留底并重新生成")
            PrivateFile.setAside(url)
        }
        let account = Account(username: defaultUsername, password: generatePassword())
        try PrivateFile.write(try JSONEncoder.iso.encode(account), to: url)
        serverLog("账号", "已生成账号 \(account.username)")
        return account
    }
}

extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
