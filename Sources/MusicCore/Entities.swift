import Foundation

/// 录音版本类型（MAT-01/04）。不同类型不得随意合并。
public enum RecordingVersionKind: String, Hashable, Sendable, Codable {
    case studio, live, cover, instrumental, edit, remaster, remix, acoustic
    case languageVariant, musicVideo, userUpload
    case unknown
}

/// 来源未提供的字段一律为 nil（未知），不编造（SEA-04）。
public struct TrackMetadata: Hashable, Sendable, Codable {
    public var title: String
    public var artists: [String]
    public var album: String?
    public var duration: Duration?
    public var versionKind: RecordingVersionKind
    /// 平台给出的版本说明原文，如“Live at …”“伴奏”。
    public var versionNote: String?
    public var isExplicit: Bool?
    public var isrc: String?
    public var discNumber: Int?
    public var trackNumber: Int?
    public var originalURL: URL?
    /// 专辑封面图片地址（来源平台的地址；客户端经家庭服务器转发取图）。
    public var artworkURL: URL?

    public init(title: String, artists: [String], album: String? = nil, duration: Duration? = nil,
                versionKind: RecordingVersionKind = .unknown, versionNote: String? = nil,
                isExplicit: Bool? = nil, isrc: String? = nil, discNumber: Int? = nil,
                trackNumber: Int? = nil, originalURL: URL? = nil) {
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.versionKind = versionKind
        self.versionNote = versionNote
        self.isExplicit = isExplicit
        self.isrc = isrc
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.originalURL = originalURL
    }
}

/// 平台标注的收听条件（来自平台的歌曲收费类型，不代表当前账号是否已有权限）。
public enum AccessRequirement: String, Hashable, Sendable, Codable {
    case membership   // 需要会员
    case purchase     // 需要单独购买
}

/// 平台返回的一条曲目。不得携带临时播放地址、票据或 Cookie（§4.4）。
public struct PlatformTrack: Hashable, Sendable, Codable {
    public let ref: PlatformResourceRef
    public var metadata: TrackMetadata
    public var accessRequirement: AccessRequirement?

    public init(ref: PlatformResourceRef, metadata: TrackMetadata, accessRequirement: AccessRequirement? = nil) {
        self.ref = ref
        self.metadata = metadata
        self.accessRequirement = accessRequirement
    }
}

public struct PlatformAlbum: Hashable, Sendable, Codable {
    public let ref: PlatformResourceRef
    public var title: String
    public var artists: [String]
    public var releaseDate: Date?
    /// 发行版本说明（豪华版、重制版等），同名专辑不自动合并（MAT-05）。
    public var editionNote: String?
    public var trackCount: Int?
    /// 封面图片地址。
    public var artworkURL: URL?

    public init(ref: PlatformResourceRef, title: String, artists: [String], releaseDate: Date? = nil, editionNote: String? = nil, trackCount: Int? = nil) {
        self.ref = ref
        self.title = title
        self.artists = artists
        self.releaseDate = releaseDate
        self.editionNote = editionNote
        self.trackCount = trackCount
    }
}

public struct PlatformArtist: Hashable, Sendable, Codable {
    public let ref: PlatformResourceRef
    public var name: String

    public init(ref: PlatformResourceRef, name: String) {
        self.ref = ref
        self.name = name
    }
}

/// 平台歌单的所有权，决定写入权限判断（LIB-02）。
public enum PlaylistOwnership: String, Hashable, Sendable, Codable {
    case ownedByAccount, createdByThisApp, savedFromOthers, editorial, unknown
}

public struct PlatformPlaylist: Hashable, Sendable, Codable {
    public let ref: PlatformResourceRef
    public var name: String
    public var ownership: PlaylistOwnership
    public var trackCount: Int?
    /// 缓存刷新时间（LIB-01）。
    public var fetchedAt: Date?

    public init(ref: PlatformResourceRef, name: String, ownership: PlaylistOwnership, trackCount: Int? = nil, fetchedAt: Date? = nil) {
        self.ref = ref
        self.name = name
        self.ownership = ownership
        self.trackCount = trackCount
        self.fetchedAt = fetchedAt
    }
}

// MARK: - 跨平台匹配（§7.2）

/// 匹配置信等级。内部排序用，不得以百分比形式显示（MAT-03）。
public enum MatchConfidence: Int, Comparable, Hashable, Sendable, Codable {
    case conflicting = 0
    case weak = 1
    case probable = 2
    case strong = 3
    case userConfirmed = 4   // 用户手动确认，优先于后续自动结果（MAT-06）

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum MatchEvidence: Hashable, Sendable, Codable {
    case isrcEqual
    case titleEqual
    case artistsEqual
    case durationWithin(seconds: Double)
    case versionKindEqual
    case albumEqual
    case conflict(String)
    case userAction
}

/// 统一曲目到平台曲目的映射。
public struct PlatformMapping: Hashable, Sendable, Codable {
    public let unifiedID: UnifiedTrackID
    public let platformTrack: PlatformResourceRef
    public var confidence: MatchConfidence
    public var evidence: [MatchEvidence]
    public var lastVerifiedAt: Date?
    public var isPinnedByUser: Bool
    public var isRejectedByUser: Bool

    public init(unifiedID: UnifiedTrackID, platformTrack: PlatformResourceRef, confidence: MatchConfidence, evidence: [MatchEvidence], lastVerifiedAt: Date? = nil, isPinnedByUser: Bool = false, isRejectedByUser: Bool = false) {
        self.unifiedID = unifiedID
        self.platformTrack = platformTrack
        self.confidence = confidence
        self.evidence = evidence
        self.lastVerifiedAt = lastVerifiedAt
        self.isPinnedByUser = isPinnedByUser
        self.isRejectedByUser = isRejectedByUser
    }
}

// MARK: - 软件资料库（§9）

public struct SoftwarePlaylistID: Hashable, Sendable, Codable {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
}

/// 歌单条目有独立 ID，支持重复歌曲与可靠重排（§7.3）。
public struct PlaylistEntryID: Hashable, Sendable, Codable {
    public let uuid: UUID
    public init(_ uuid: UUID = UUID()) { self.uuid = uuid }
}

public struct SoftwarePlaylistEntry: Hashable, Sendable, Codable {
    public let id: PlaylistEntryID
    public let track: UnifiedTrackID
    /// 加入时的原始来源。
    public let originalSource: PlatformResourceRef?
    /// 用户固定的来源；为 nil 时走自动路由（PLAY-05）。
    public var pinnedSource: PlatformResourceRef?
    public let addedAt: Date

    public init(id: PlaylistEntryID = PlaylistEntryID(), track: UnifiedTrackID, originalSource: PlatformResourceRef?, pinnedSource: PlatformResourceRef? = nil, addedAt: Date = Date()) {
        self.id = id
        self.track = track
        self.originalSource = originalSource
        self.pinnedSource = pinnedSource
        self.addedAt = addedAt
    }
}

public struct SoftwarePlaylist: Hashable, Sendable, Codable {
    public let id: SoftwarePlaylistID
    public var name: String
    public var entries: [SoftwarePlaylistEntry]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: SoftwarePlaylistID = SoftwarePlaylistID(), name: String, entries: [SoftwarePlaylistEntry] = [], createdAt: Date = Date(), modifiedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.entries = entries
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
