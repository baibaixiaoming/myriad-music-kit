import CommonCrypto
import CryptoKit
import Foundation
import Network
import Security

/// 客户端与服务端之间的加密方式（ADR-0003 第 9、13 节）：
/// TLS 1.2 预共享密钥 + ECDHE（X25519）+ ChaCha20-Poly1305，无证书。
/// 实验依据见 spikes/transport/。
public enum TransportSecurity {
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256
    public static let requiredSuite: UInt16 = 0xCCAC
    /// 从密码派生密钥的迭代次数（PBKDF2-SHA256）。
    public static let passwordIterations: UInt32 = 600_000
    public static let minimumPasswordLength = 10

    /// 一把已登记的预共享密钥。
    public struct KeyEntry: Sendable, Hashable {
        public let identity: String
        public let key: Data
        public init(identity: String, key: Data) { self.identity = identity; self.key = key }
    }

    /// 用户首次登录用的身份与密钥：`u:<小写用户名>`，密钥由密码派生。
    public static func passwordEntry(username: String, password: String) -> KeyEntry {
        let name = normalizedUsername(username)
        return KeyEntry(identity: "u:\(name)", key: deriveKey(password: password, username: name))
    }

    public static func normalizedUsername(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// PBKDF2-SHA256。盐由用户名确定，使客户端无需先向服务端询问。
    public static func deriveKey(password: String, username: String, iterations: UInt32 = passwordIterations) -> Data {
        let salt = Data("AccessibleMusic/v1/user/\(username)".utf8)
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 passwordBytes.map { Int8(bitPattern: $0) }, passwordBytes.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                 &derived, derived.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 失败")
        return Data(derived)
    }

    public static func randomKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }

    static func string(_ data: dispatch_data_t) -> String {
        var out = Data()
        (data as DispatchData).enumerateBytes { bytes, _, _ in out.append(contentsOf: bytes) }
        return String(decoding: out, as: UTF8.self)
    }

    private static func baseOptions() -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: requiredSuite)!)
        // 禁止会话复用：复用时不再经过预共享密钥选择，服务端无法确认身份，且可能让不同客户端串用同一会话
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        return tls
    }

    /// 服务端参数：登记全部密钥；按身份选密钥时回调 `onIdentity`，用于把连接对应到身份。
    /// `allow`：选密钥前询问是否接受这个身份（用于暂停某个用户名的密码登录）。
    static func serverParameters(keys: [KeyEntry], allow: @escaping @Sendable (String) -> Bool = { _ in true },
                                 onIdentity: @escaping @Sendable (ObjectIdentifier, String) -> Void) -> NWParameters {
        let tls = baseOptions()
        let sec = tls.securityProtocolOptions
        for entry in keys {
            sec_protocol_options_add_pre_shared_key(sec, dispatchData(entry.key), dispatchData(Data(entry.identity.utf8)))
        }
        let known = Set(keys.map(\.identity))
        sec_protocol_options_set_pre_shared_key_selection_block(sec, { metadata, hint, complete in
            guard let hint else { complete(nil); return }
            let identity = string(hint)
            guard known.contains(identity), allow(identity) else { complete(nil); return }
            onIdentity(ObjectIdentifier(metadata as AnyObject), identity)
            complete(dispatchData(Data(identity.utf8)))
        }, DispatchQueue(label: "AccessibleMusic.TLS.select"))
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    static func clientParameters(_ entry: KeyEntry) -> NWParameters {
        let tls = baseOptions()
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, dispatchData(entry.key),
                                                dispatchData(Data(entry.identity.utf8)))
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    static func metadata(_ connection: NWConnection) -> sec_protocol_metadata_t? {
        (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)?.securityProtocolMetadata
    }

    /// 握手后检查实际套件；系统不支持时会静默退回无前向保密的套件，必须拒绝。
    static func hasRequiredSuite(_ connection: NWConnection) -> Bool {
        guard let meta = metadata(connection) else { return false }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta).rawValue == requiredSuite
            && sec_protocol_metadata_get_negotiated_tls_protocol_version(meta) == .TLSv12
    }
}
