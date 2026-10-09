import Foundation

/// 稳定的平台标识（MOD-01）。具体平台的常量由各平台模块自己定义（共享组件与客户端不包含任何在线平台名称）。
public struct PlatformID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// 编解码时若编码器 / 解码器的 `userInfo` 带有 `PlatformIDTranslation`，就在内部编号与对外编号之间转换；
    /// 没有时原样读写字符串（与以前的格式完全相同）。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if let t = decoder.userInfo[.platformIDTranslation] as? PlatformIDTranslation {
            self = t.toInternal(PlatformID(raw))
        } else {
            self.init(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let t = encoder.userInfo[.platformIDTranslation] as? PlatformIDTranslation {
            try c.encode(t.toWire(self).rawValue)
        } else {
            try c.encode(rawValue)
        }
    }
}

/// 来源编号在协议边界上的转换（服务器用）：服务器内部用自己的名字，对客户端只用“槽位号”。
/// 把它放进 `JSONEncoder.userInfo` / `JSONDecoder.userInfo` 的 `.platformIDTranslation`，
/// 收发的数据里所有 `PlatformID` 就会自动转换。表里没有的编号原样通过（例如客户端本机来源、旧客户端发来的旧编号）。
public struct PlatformIDTranslation: Sendable {
    private let wire: [String: String]
    private let `internal`: [String: String]

    /// - Parameter internalToWire: 内部编号 → 对外编号。
    public init(internalToWire: [String: String]) {
        wire = internalToWire
        var back: [String: String] = [:]
        for (k, v) in internalToWire { back[v] = k }
        `internal` = back
    }

    public func toWire(_ id: PlatformID) -> PlatformID { wire[id.rawValue].map { PlatformID($0) } ?? id }
    public func toInternal(_ id: PlatformID) -> PlatformID { `internal`[id.rawValue].map { PlatformID($0) } ?? id }
    public func toWire(_ raw: String) -> String { wire[raw] ?? raw }
    public func toInternal(_ raw: String) -> String { `internal`[raw] ?? raw }
}

extension CodingUserInfoKey {
    /// 见 `PlatformIDTranslation`。
    public static let platformIDTranslation = CodingUserInfoKey(rawValue: "AccessibleMusic.platformIDTranslation")!
}

/// 平台内的账号标识。首版每平台一个活动账号，但数据结构保留账号维度（ACC-02）。
public struct AccountID: Hashable, Sendable, Codable {
    public let platform: PlatformID
    /// 模块定义的不透明账号键，不得包含凭据。
    public let opaqueKey: String
    public init(platform: PlatformID, opaqueKey: String) {
        self.platform = platform
        self.opaqueKey = opaqueKey
    }
}

/// 地区上下文。曲目可用性、搜索结果与权益都可能随地区变化（MOD-06）。
public struct RegionContext: Hashable, Sendable, Codable {
    /// ISO 3166-1 alpha-2；未知时为 nil，不猜测。
    public let storefront: String?
    public init(storefront: String?) { self.storefront = storefront }
    public static let unknown = RegionContext(storefront: nil)
}

/// 本软件的统一曲目 ID：对应一个具体录音版本（MAT-01），不是抽象歌名。
public struct UnifiedTrackID: Hashable, Sendable, Codable {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
}

/// 平台资源引用：平台 + 地区/账号上下文 + 平台原始 ID（SEA-04、§4.4）。
public struct PlatformResourceRef: Hashable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case track, album, artist, playlist }
    public let platform: PlatformID
    public let kind: Kind
    public let platformID: String
    public let region: RegionContext
    /// 仅当资源属于某个账号的私有视图时填写。
    public let account: AccountID?

    public init(platform: PlatformID, kind: Kind, platformID: String,
                region: RegionContext = .unknown, account: AccountID? = nil) {
        self.platform = platform
        self.kind = kind
        self.platformID = platformID
        self.region = region
        self.account = account
    }
}
