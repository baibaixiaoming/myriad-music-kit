import Foundation

/// 细分能力（PRD §4.2）。同一类操作按语义拆开，不压缩成一个真假值。
public enum Capability: Hashable, Sendable, Codable {
    // 账号
    case login(LoginMethod)
    case logout
    case credentialRefresh
    case readEntitlements

    // 内容
    case search(SearchKind)
    case detail(EntityKind)
    case recommendations
    case charts

    // 资料库：加入资料库、点赞、收藏专辑、关注艺人是不同操作（§2.2）
    case libraryRead(LibrarySection)
    case libraryAdd(EntityKind)
    case libraryRemove(EntityKind)
    case like
    case unlike
    case followArtist
    case unfollowArtist

    // 歌单写入，附适用范围
    case playlistWrite(PlaylistWriteOperation, scope: PlaylistWriteScope)

    // 播放
    case fullPlayback
    case previewPlayback
    case pause
    case seek
    case skip
    case qualitySelection
    case independentVolume
    case systemMediaControls
    case platformManagedOffline

    // 歌词
    case lyrics(LyricsFeature)

    // 下载：播放流获取、离线缓存和导出文件是三个不同能力
    case resolveStream
    case offlineCache
    case exportAudioFile
    case queryDownloadQuality
    case cancelDownload
    case resumeDownload
    case embedLyrics
    case embedArtwork
    case embedTags
}

public enum LoginMethod: String, Hashable, Sendable, Codable {
    case systemAuthorization   // 如 MusicKit 系统授权
    case oauthDevice
    case browserHeaders
    case qrCode
    case smsCode
    case password
}

public enum SearchKind: String, Hashable, Sendable, Codable, CaseIterable {
    case track, album, artist, playlist
}

public enum EntityKind: String, Hashable, Sendable, Codable {
    case track, album, artist, playlist
}

public enum LibrarySection: String, Hashable, Sendable, Codable {
    case savedTracks, likedTracks, savedAlbums, followedArtists
    case ownedPlaylists, savedPlaylists, recentlyAdded, history
}

public enum PlaylistWriteOperation: String, Hashable, Sendable, Codable {
    case create, rename, addTracks, removeTracks, reorder, delete
}

public enum PlaylistWriteScope: String, Hashable, Sendable, Codable {
    case ownedByAccount        // 当前账号拥有的歌单
    case createdByThisApp      // 仅限本应用创建（如 MusicKit 的约束，§5.1）
}

public enum LyricsFeature: String, Hashable, Sendable, Codable {
    case plainText, lineSynced, wordSynced, translation, romanization, cacheOrExport
}

/// 证据等级（PRD §16 阶段一）。描述信息中的每项能力都要标注。
public enum EvidenceLevel: Int, Comparable, Sendable, Codable {
    case unavailable = -1        // 已确认当前不可用
    case documented = 0          // 仅文档声明
    case invoked = 1             // 已调用验证
    case implemented = 2         // 已完成产品实现
    case voiceOverAccepted = 3   // 已完成 VoiceOver 验收

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 只有已实现的能力才能出现在界面中。
    public var mayBeExposedInUI: Bool { self >= .implemented }
}

/// 运行时能力状态（MOD-05）。
public enum CapabilityStatus: Hashable, Sendable, Codable {
    case unsupported
    case unverified
    case checking
    case available
    case requiresLogin
    case insufficientEntitlement
    case resourceUnavailable
    case temporaryFailure

    /// 只有 `.available` 可执行；未知不得伪装成可用。
    public var isExecutable: Bool { self == .available }

    /// 未知或暂时性状态不得永久缓存为“不支持”。
    public var isCacheableAsFinal: Bool {
        switch self {
        case .unsupported: true
        default: false
        }
    }
}

/// 触发重新验证的条件（MOD-06）。
public enum InvalidationTrigger: String, Hashable, Sendable, Codable {
    case accountChanged, regionChanged, trackVersionChanged, resourceExpired, moduleUpgraded, timeElapsed
}

/// 一次能力判断的结果（MOD-04/05/06）。
public struct CapabilityAssessment: Hashable, Sendable, Codable {
    public let capability: Capability
    public let status: CapabilityStatus
    public let checkedAt: Date?
    public let expiresAt: Date?
    public let invalidatedBy: Set<InvalidationTrigger>
    /// 面向用户的可读原因（如“需要登录来源 A”），用于 VoiceOver 播报与详情。
    public let reason: String?

    public init(capability: Capability, status: CapabilityStatus, checkedAt: Date? = nil,
                expiresAt: Date? = nil, invalidatedBy: Set<InvalidationTrigger> = [], reason: String? = nil) {
        self.capability = capability
        self.status = status
        self.checkedAt = checkedAt
        self.expiresAt = expiresAt
        self.invalidatedBy = invalidatedBy
        self.reason = reason
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return checkedAt != nil }
        return now < expiresAt
    }
}
