import Foundation
@_exported import MusicCore

/// 模块协议版本。现有模型无法表达新媒体类型时显式升级（§3.3）。
public let currentProviderProtocolVersion = 1

/// 接入类型（MOD-02）。
public enum IntegrationKind: String, Sendable, Codable {
    case officialSDK
    case officialAPI
    case communityAPI
    case externalBackend
}

public enum AccountRequirement: Sendable, Codable, Hashable {
    case none
    case optional       // 未登录也有经过验证的公开能力（ACC-01）
    case required
}

/// 参考实现或外部依赖的固定版本（SEC-04、ADR-0002）。与 docs/dependencies.md 一致。
public struct DependencyPin: Sendable, Codable, Hashable {
    public let name: String
    public let source: URL
    /// 固定版本或提交；nil 表示尚未固定（阶段一必须补上）。
    public let pinnedVersion: String?
    public let license: String?

    public init(name: String, source: URL, pinnedVersion: String?, license: String?) {
        self.name = name
        self.source = source
        self.pinnedVersion = pinnedVersion
        self.license = license
    }
}

/// 一项能力的声明：证据等级 + 适用范围或限制说明。
public struct CapabilityDeclaration: Sendable, Codable, Hashable {
    public let capability: Capability
    public let evidence: EvidenceLevel
    public let note: String?

    public init(_ capability: Capability, _ evidence: EvidenceLevel, note: String? = nil) {
        self.capability = capability
        self.evidence = evidence
        self.note = note
    }
}

/// 模块描述信息（MOD-01）。
public struct ProviderDescriptor: Sendable, Codable, Hashable {
    public let platform: PlatformID
    public let displayName: String
    public let moduleVersion: String
    public let protocolVersion: Int
    public let integration: IntegrationKind
    public let accountRequirement: AccountRequirement
    public let dependencies: [DependencyPin]
    public let capabilities: [CapabilityDeclaration]
    /// 支持的扫码登录方式；空表示不支持或只有一种默认方式。
    public var qrLoginVariants: [QRLoginVariant] = []
    /// 可选的播放音质级别（从低到高）；空表示由平台决定、不可选。
    public var streamLevels: [StreamQualityLevel] = []
    /// 来源的用途（可选）：例如服务器自己的音乐文件库，客户端为它单独开页面。旧服务器不发。
    public var role: ProviderRole?

    public init(platform: PlatformID, displayName: String, moduleVersion: String,
                protocolVersion: Int = currentProviderProtocolVersion,
                integration: IntegrationKind, accountRequirement: AccountRequirement,
                dependencies: [DependencyPin] = [], capabilities: [CapabilityDeclaration],
                qrLoginVariants: [QRLoginVariant] = []) {
        self.qrLoginVariants = qrLoginVariants
        self.platform = platform
        self.displayName = displayName
        self.moduleVersion = moduleVersion
        self.protocolVersion = protocolVersion
        self.integration = integration
        self.accountRequirement = accountRequirement
        self.dependencies = dependencies
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case platform, displayName, moduleVersion, protocolVersion, integration, accountRequirement, dependencies, capabilities, qrLoginVariants, streamLevels, role
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        platform = try c.decode(PlatformID.self, forKey: .platform)
        displayName = try c.decode(String.self, forKey: .displayName)
        moduleVersion = try c.decode(String.self, forKey: .moduleVersion)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        integration = try c.decode(IntegrationKind.self, forKey: .integration)
        accountRequirement = try c.decode(AccountRequirement.self, forKey: .accountRequirement)
        dependencies = try c.decode([DependencyPin].self, forKey: .dependencies)
        capabilities = try c.decode([CapabilityDeclaration].self, forKey: .capabilities)
        qrLoginVariants = try c.decodeIfPresent([QRLoginVariant].self, forKey: .qrLoginVariants) ?? []
        streamLevels = try c.decodeIfPresent([StreamQualityLevel].self, forKey: .streamLevels) ?? []
        role = try c.decodeIfPresent(ProviderRole.self, forKey: .role)
    }

    public func evidence(for capability: Capability) -> EvidenceLevel? {
        capabilities.first { $0.capability == capability }?.evidence
    }

    /// 只有达到“已实现”的能力才允许在界面中出现。
    public func mayExpose(_ capability: Capability) -> Bool {
        evidence(for: capability)?.mayBeExposedInUI ?? false
    }
}

/// 来源的用途。用字符串结构体而不是枚举：客户端遇到不认识的用途也能正常解码（当作普通来源）。
public struct ProviderRole: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    /// 服务器自己的音乐文件库（服务器音乐库）：客户端单独显示，不并入平台的喜欢、专辑、歌手、歌单。
    public static let musicLibrary = ProviderRole(rawValue: "musicLibrary")
}

/// 模块健康状态（MOD-01/02）。
public enum ProviderHealth: Sendable, Hashable {
    case healthy
    case degraded(reason: String)
    case needsReauthentication
    case suspended(reason: String)    // 隔离并暂停请求（NFR-03）
    case unavailable(reason: String)  // 辅助进程无法启动、模块禁用等
}
