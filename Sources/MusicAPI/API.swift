import Foundation
import ProviderKit

/// 客户端与服务端之间的接口定义（ADR-0003 第 5 节）。两端共用，保证字段一致。
/// 所有接口都在加密端口上；接口版本前缀 `/v1/`。
public enum API {
    public static let version = 1

    /// 接口协议版本：两端结构不兼容地改动时加一。
    public static let protocolVersion = 2

    public enum Path {
        public static let server = "/v1/server"                  // GET 服务端版本与协议版本
        public static let login = "/v1/session/login"            // POST，仅首次密码登录身份可用
        public static let me = "/v1/me"                          // GET
        public static let providers = "/v1/providers"            // GET
        public static let providerIDs = "/v1/providers/ids"      // POST SourceIDsRequest：把客户端保存的旧来源编号换成现在的编号
        public static let search = "/v1/search"                  // GET platform, q, kind, cursor
        public static let searchAll = "/v1/search/all"           // GET q, kind：服务器同时搜各来源并排序
        public static let artwork = "/v1/artwork"                // GET url：由服务器转发封面图片
        public static let library = "/v1/library"                // GET platform, section, cursor
        public static let track = "/v1/track"                    // GET platform, id
        public static let albumTracks = "/v1/album-tracks"       // GET platform, id, cursor
        public static let playlistTracks = "/v1/playlist-tracks" // GET platform, id, cursor
        public static let artistTracks = "/v1/artist-tracks"     // GET platform, id, cursor
        public static let artistAlbums = "/v1/artist-albums"     // GET platform, id, cursor
        public static let lyrics = "/v1/lyrics"                  // GET platform, id
        public static let lyricsForTrack = "/v1/lyrics/for-track" // POST {track}：跨来源查找（LYR-01/02）
        public static let streamOpen = "/v1/stream/open"         // POST
        public static let streamData = "/v1/stream/"             // GET /v1/stream/{编号}，支持 Range
        public static let downloadCandidates = "/v1/download/candidates" // POST {track}
        public static let downloadOpen = "/v1/download/open"       // POST {platform, id, qualityKey}：之后用 streamData 取整个文件
        public static let smsSend = "/v1/platform-login/sms/send"
        public static let smsLogin = "/v1/platform-login/sms/login"
        public static let qrLogin = "/v1/platform-login/qr"      // POST，事件流
        public static let platformLogout = "/v1/platform-logout"  // POST
        public static let platformChoice = "/v1/platform-choice" // POST：用自己的 / 借用 / 不使用
        public static let lending = "/v1/lending"                // POST：允许哪些成员借用
        // 平台资料库写入（只能用自己的平台账户；借用的账户不行）
        public static let platformWrite = "/v1/platform-library/write"   // POST PlatformWriteRequest
        public static let platformPlaylist = "/v1/platform-playlist"     // POST PlatformPlaylistRequest

        // 软件资料库（每个用户独立；歌单可只读分享）
        public static let playlists = "/v1/my/playlists"              // GET 列表
        public static let playlist = "/v1/my/playlist"                // GET id
        public static let playlistCreate = "/v1/my/playlist/create"   // POST {name}
        public static let playlistRename = "/v1/my/playlist/rename"   // POST {id, name}
        public static let playlistDelete = "/v1/my/playlist/delete"   // POST {id}
        public static let playlistAdd = "/v1/my/playlist/add"         // POST {id, tracks}
        public static let playlistRemove = "/v1/my/playlist/remove"   // POST {id, entryIDs}
        public static let playlistMove = "/v1/my/playlist/move"       // POST {id, entryID, toIndex}
        public static let playlistShare = "/v1/my/playlist/share"     // POST {id, userIDs}
        public static let favorites = "/v1/my/favorites"              // GET
        public static let favoritesAdd = "/v1/my/favorites/add"       // POST {tracks}
        public static let favoritesRemove = "/v1/my/favorites/remove" // POST {refs}
        public static let history = "/v1/my/history"                  // GET
        public static let historyAdd = "/v1/my/history/add"           // POST {track}
        public static let historyClear = "/v1/my/history/clear"       // POST {}
        public static let discLookup = "/v1/disc/lookup"              // POST DiscTOC → DiscInfo（查不到为 404）
        // 诊断：客户端上传崩溃记录与运行日志（按用户与设备存在服务器上，供排查问题）
        public static let diagnosticsUpload = "/v1/diagnostics/upload" // POST DiagnosticUpload
    }

    // MARK: 软件资料库

    public struct LibraryEntry: Codable, Sendable, Hashable {
        /// 条目编号：同一首歌可重复出现，重排按条目进行（§7.3）。
        public let entryID: String
        public let track: PlatformTrack
        public let addedAt: Date
        public init(entryID: String, track: PlatformTrack, addedAt: Date) {
            self.entryID = entryID; self.track = track; self.addedAt = addedAt
        }
    }

    public struct LibraryPlaylist: Codable, Sendable, Hashable {
        public let id: String
        public var name: String
        public let ownerUserID: String
        public var entries: [LibraryEntry]
        /// 只读分享给的成员（只有所有者能看到）。
        public var sharedWith: [String]
        public let createdAt: Date
        public var modifiedAt: Date
        public init(id: String, name: String, ownerUserID: String, entries: [LibraryEntry], sharedWith: [String],
                    createdAt: Date, modifiedAt: Date) {
            self.id = id; self.name = name; self.ownerUserID = ownerUserID; self.entries = entries
            self.sharedWith = sharedWith; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        }
    }

    public struct PlaylistSummary: Codable, Sendable, Hashable {
        public let id: String
        public let name: String
        public let trackCount: Int
        public let ownerName: String
        /// false 表示别人分享给我的只读歌单。
        public let isMine: Bool
        public let sharedWith: [String]?
        public init(id: String, name: String, trackCount: Int, ownerName: String, isMine: Bool, sharedWith: [String]?) {
            self.id = id; self.name = name; self.trackCount = trackCount; self.ownerName = ownerName
            self.isMine = isMine; self.sharedWith = sharedWith
        }
    }

    public struct HistoryEntry: Codable, Sendable, Hashable {
        public let track: PlatformTrack
        public let playedAt: Date
        public init(track: PlatformTrack, playedAt: Date) { self.track = track; self.playedAt = playedAt }
    }

    public struct PlaylistRequest: Codable, Sendable {
        public var id: String?
        public var name: String?
        public var tracks: [PlatformTrack]?
        public var entryIDs: [String]?
        public var entryID: String?
        public var toIndex: Int?
        public var userIDs: [String]?
        public init(id: String? = nil, name: String? = nil, tracks: [PlatformTrack]? = nil, entryIDs: [String]? = nil,
                    entryID: String? = nil, toIndex: Int? = nil, userIDs: [String]? = nil) {
            self.id = id; self.name = name; self.tracks = tracks; self.entryIDs = entryIDs
            self.entryID = entryID; self.toIndex = toIndex; self.userIDs = userIDs
        }
    }

    public struct TrackRequest: Codable, Sendable {
        public let track: PlatformTrack
        public init(track: PlatformTrack) { self.track = track }
    }

    public struct TracksRequest: Codable, Sendable {
        public let tracks: [PlatformTrack]
        public init(tracks: [PlatformTrack]) { self.tracks = tracks }
    }

    public struct RefsRequest: Codable, Sendable {
        public let refs: [PlatformResourceRef]
        public init(refs: [PlatformResourceRef]) { self.refs = refs }
    }

    public struct Empty: Codable, Sendable { public init() {} }

    // MARK: 平台资料库写入

    /// 对单个平台对象的写入：红心、收藏专辑或歌单、关注歌手。以平台返回结果为准。
    public enum PlatformWriteAction: String, Codable, Sendable, CaseIterable {
        case like, unlike, saveAlbum, unsaveAlbum, savePlaylist, unsavePlaylist, followArtist, unfollowArtist

        public var capability: Capability {
            switch self {
            case .like: .like
            case .unlike: .unlike
            case .saveAlbum: .libraryAdd(.album)
            case .unsaveAlbum: .libraryRemove(.album)
            case .savePlaylist: .libraryAdd(.playlist)
            case .unsavePlaylist: .libraryRemove(.playlist)
            case .followArtist: .followArtist
            case .unfollowArtist: .unfollowArtist
            }
        }

        public var kind: EntityKind {
            switch self {
            case .like, .unlike: .track
            case .saveAlbum, .unsaveAlbum: .album
            case .savePlaylist, .unsavePlaylist: .playlist
            case .followArtist, .unfollowArtist: .artist
            }
        }
    }

    public struct PlatformWriteRequest: Codable, Sendable {
        public let platform: PlatformID
        public let action: PlatformWriteAction
        public let id: String
        public init(platform: PlatformID, action: PlatformWriteAction, id: String) {
            self.platform = platform; self.action = action; self.id = id
        }
    }

    /// 平台歌单写入。`idempotencyKey` 只用于新建：同一编号重复提交（例如超时后重试）只建一次（LIB-06）。
    public struct PlatformPlaylistRequest: Codable, Sendable {
        public let platform: PlatformID
        public let operation: PlaylistWriteOperation
        public var playlistID: String?
        public var name: String?
        public var trackIDs: [String]?
        public var idempotencyKey: UUID?
        public init(platform: PlatformID, operation: PlaylistWriteOperation, playlistID: String? = nil,
                    name: String? = nil, trackIDs: [String]? = nil, idempotencyKey: UUID? = nil) {
            self.platform = platform; self.operation = operation; self.playlistID = playlistID
            self.name = name; self.trackIDs = trackIDs; self.idempotencyKey = idempotencyKey
        }
    }

    /// 平台歌单写入结果：新建时返回新歌单，其余为空。
    public struct PlatformPlaylistResponse: Codable, Sendable {
        public let playlist: PlatformPlaylist?
        public init(playlist: PlatformPlaylist?) { self.playlist = playlist }
    }

    /// 家庭服务器提供的功能。客户端只显示服务器声明了的页面与菜单；未声明（或未连接服务器）时不显示。
    /// 自建服务器可以只实现其中一部分。
    public enum ServerFeature: String, Codable, Sendable, CaseIterable {
        /// 软件收藏（/v1/my/favorites…）
        case favorites
        /// 软件播放列表（/v1/my/playlist…）
        case playlists
        /// 播放历史（/v1/my/history…）
        case history
        /// 向其他用户只读分享软件播放列表
        case playlistSharing
        /// 由服务器提供的下载（/v1/download/…）
        case downloads
        /// 按歌曲在多个来源中查找歌词（/v1/lyrics/for-track）
        case lyricsForTrack
        /// 统一搜索：服务器同时搜所有来源，合并后排序（DJ 版、剪辑版等排到后面）（/v1/search/all）
        case rankedSearch
        /// 平台账户登录、借用设置（/v1/platform-login/…、/v1/platform-choice、/v1/lending）
        case platformAccounts
        /// 按光盘目录查整张 CD 的歌名（/v1/disc/lookup）：由服务器联网查询，客户端不直接访问外部资料库
        case discLookup
        /// 接收客户端上传的崩溃记录与运行日志（/v1/diagnostics/upload）
        case diagnostics
        /// 唱片资料查询（/v1/catalog/…）：认唱片、取整张唱片的曲目、作品与参与人员。只在服务器配置了资料库时提供
        case catalog
        /// 旧来源编号换算（/v1/providers/ids）：服务器改用槽位号后，客户端把本机保存的旧编号换成新编号
        case sourceIDMapping
        /// 逐层浏览与简介（/v1/catalog/browse/…）：按作曲家、艺人、作品、录音、专辑、唱片公司浏览。
        /// 只在资料库与浏览索引都已配置且是同一期时提供
        case catalogBrowse
    }

    // MARK: 来源编号

    /// 客户端本机保存的、在当前来源列表里找不到的来源编号（例如旧版服务器发的编号）。
    public struct SourceIDsRequest: Codable, Sendable {
        public let ids: [String]
        public init(ids: [String]) { self.ids = ids }
    }

    /// 旧编号 → 现在的编号。服务器不认识的编号不出现在结果里。
    public struct SourceIDsResponse: Codable, Sendable {
        public let ids: [String: String]
        public init(ids: [String: String]) { self.ids = ids }
    }

    // MARK: 诊断

    /// 客户端上传的一份诊断信息（一份崩溃记录或一段运行日志）。单份不超过 3 MB。
    public struct DiagnosticUpload: Codable, Sendable {
        /// crash（崩溃时程序自己记下的）、system（系统诊断报告）、log（运行日志）
        public let kind: String
        /// 文件名（客户端本机的名字，便于对照）
        public let name: String
        /// 发生时间（崩溃时间或日志截取时间）
        public let created: Date?
        public let device: String
        public let system: String
        /// 应用版本与构建号
        public let app: String
        public let text: String
        public init(kind: String, name: String, created: Date?, device: String, system: String, app: String, text: String) {
            self.kind = kind; self.name = name; self.created = created; self.device = device; self.system = system; self.app = app; self.text = text
        }
    }

    public struct ServerInfo: Codable, Sendable {
        public let serverVersion: String
        public let protocolVersion: Int
        /// 服务器声明的功能名称。保留为字符串，客户端忽略不认识的名称。
        public let features: [String]?
        public init(serverVersion: String, protocolVersion: Int, features: [ServerFeature] = []) {
            self.serverVersion = serverVersion; self.protocolVersion = protocolVersion
            self.features = features.map(\.rawValue)
        }
        /// 客户端认识的功能。
        public var knownFeatures: Set<ServerFeature> { Set((features ?? []).compactMap(ServerFeature.init(rawValue:))) }
    }

    // MARK: 登录

    public struct LoginRequest: Codable, Sendable {
        public let deviceName: String
        public init(deviceName: String) { self.deviceName = deviceName }
    }

    public struct LoginResponse: Codable, Sendable {
        public let user: UserInfo
        public let deviceID: String
        /// 该设备的长期密钥（Base64）。之后以 `d:<deviceID>` 身份连接。
        public let deviceKey: String
        public init(user: UserInfo, deviceID: String, deviceKey: String) {
            self.user = user; self.deviceID = deviceID; self.deviceKey = deviceKey
        }
    }

    public struct UserInfo: Codable, Sendable, Hashable {
        public let id: String
        public let username: String
        public let displayName: String
        public init(id: String, username: String, displayName: String) {
            self.id = id; self.username = username; self.displayName = displayName
        }
    }

    // MARK: 当前用户与平台状态

    public struct MeResponse: Codable, Sendable {
        public let user: UserInfo
        public let platforms: [PlatformStatus]
        /// 服务器上的其他成员（用于设置借给谁）。
        public let members: [UserInfo]
        public init(user: UserInfo, platforms: [PlatformStatus], members: [UserInfo]) {
            self.user = user; self.platforms = platforms; self.members = members
        }
    }

    public enum PlatformMode: String, Codable, Sendable { case own, borrowed, guest }

    public struct PlatformStatus: Codable, Sendable {
        public let platform: PlatformID
        public let displayName: String
        public let supportsLogin: Bool
        public let mode: PlatformMode
        /// 当前使用的平台账户（自己的或借用的）。
        public let current: AccountInfo?
        /// 自己在该平台的账户（若已登录）。
        public let own: AccountInfo?
        /// 允许我借用的家庭成员账户。
        public let borrowable: [AccountInfo]
        public init(platform: PlatformID, displayName: String, supportsLogin: Bool, mode: PlatformMode,
                    current: AccountInfo?, own: AccountInfo?, borrowable: [AccountInfo]) {
            self.platform = platform; self.displayName = displayName; self.supportsLogin = supportsLogin
            self.mode = mode; self.current = current; self.own = own; self.borrowable = borrowable
        }
    }

    public struct AccountInfo: Codable, Sendable, Hashable {
        public let accountID: String
        public let platform: PlatformID
        public let ownerUserID: String
        public let ownerName: String
        public let nickname: String
        /// 允许借用的成员（只有所有者能看到）。默认是全部其他成员。
        public let lendTo: [String]?
        public init(accountID: String, platform: PlatformID, ownerUserID: String, ownerName: String,
                    nickname: String, lendTo: [String]?) {
            self.accountID = accountID; self.platform = platform; self.ownerUserID = ownerUserID
            self.ownerName = ownerName; self.nickname = nickname; self.lendTo = lendTo
        }
    }

    public struct PlatformChoiceRequest: Codable, Sendable {
        public let platform: PlatformID
        public let mode: PlatformMode
        public let accountID: String?
        public init(platform: PlatformID, mode: PlatformMode, accountID: String?) {
            self.platform = platform; self.mode = mode; self.accountID = accountID
        }
    }

    public struct LendingRequest: Codable, Sendable {
        public let accountID: String
        public let userIDs: [String]
        public init(accountID: String, userIDs: [String]) { self.accountID = accountID; self.userIDs = userIDs }
    }

    public struct PlatformRequest: Codable, Sendable {
        public let platform: PlatformID
        /// 二维码登录方式（QRLoginVariant.id）；其他请求不用。
        public let variant: String?
        public init(platform: PlatformID, variant: String? = nil) { self.platform = platform; self.variant = variant }
    }

    // MARK: 平台登录

    public struct SMSSendRequest: Codable, Sendable {
        public let platform: PlatformID
        public let phone: String
        public let countryCode: String
        public init(platform: PlatformID, phone: String, countryCode: String) {
            self.platform = platform; self.phone = phone; self.countryCode = countryCode
        }
    }

    public struct SMSLoginRequest: Codable, Sendable {
        public let platform: PlatformID
        public let phone: String
        public let code: String
        public let countryCode: String
        public init(platform: PlatformID, phone: String, code: String, countryCode: String) {
            self.platform = platform; self.phone = phone; self.code = code; self.countryCode = countryCode
        }
    }

    /// 二维码登录事件流中的一条事件（SSE `data:` 为其 JSON）。
    public struct QRLoginEvent: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case qrCode, awaitingConfirmation, succeeded, expired, failed }
        public let kind: Kind
        public let message: String
        public let imagePNG: String?          // Base64
        public let account: AccountInfo?
        public init(kind: Kind, message: String, imagePNG: String? = nil, account: AccountInfo? = nil) {
            self.kind = kind; self.message = message; self.imagePNG = imagePNG; self.account = account
        }
    }

    // MARK: 下载

    /// 一个可下载的来源：平台上的同一录音及其实际可下载音质（DL-05、DL-07）。
    public struct DownloadCandidate: Codable, Sendable {
        public let platform: PlatformID
        public let displayName: String
        public let track: PlatformTrack
        public let qualities: [AudioQuality]
        /// 是否为原来的播放来源；否则为匹配到的同一录音。
        public let isOriginal: Bool
        public init(platform: PlatformID, displayName: String, track: PlatformTrack, qualities: [AudioQuality], isOriginal: Bool) {
            self.platform = platform; self.displayName = displayName; self.track = track; self.qualities = qualities; self.isOriginal = isOriginal
        }
    }

    public struct DownloadOpenRequest: Codable, Sendable {
        public let platform: PlatformID
        public let id: String
        public let qualityKey: String
        public init(platform: PlatformID, id: String, qualityKey: String) {
            self.platform = platform; self.id = id; self.qualityKey = qualityKey
        }
    }

    // MARK: 音频转发

    public struct StreamOpenRequest: Codable, Sendable {
        public let platform: PlatformID
        public let id: String
        public let level: String?
        /// 曲目信息，用于只能试听时到其他平台匹配同一录音。
        public let track: PlatformTrack?
        public let allowSourceFallback: Bool?
        /// 用户给各来源选的音质（来源编号 → 级别键）。自动换源时按目标来源的选择取音质。
        public let levels: [String: String]?
        /// 用户设的“最高音质”（通用档位，可选）。自动换源时，目标来源在 `levels` 里没有级别的，
        /// 服务器取不超过“想要的档位”的最高级别（想要的档位 = 原来源所用级别的档位，再以此为上限）。
        public let maxTier: QualityTier?
        public init(platform: PlatformID, id: String, level: String?, track: PlatformTrack? = nil,
                    allowSourceFallback: Bool? = nil, levels: [String: String]? = nil, maxTier: QualityTier? = nil) {
            self.platform = platform; self.id = id; self.level = level; self.track = track
            self.allowSourceFallback = allowSourceFallback; self.levels = levels; self.maxTier = maxTier
        }
    }

    public struct StreamOpenResponse: Codable, Sendable {
        public let streamID: String
        public let quality: AudioQuality
        public let duration: Duration?
        public let previewStart: Duration?
        public let previewEnd: Duration?
        /// 自动换源时实际使用的来源说明（为空表示使用原来源）。
        public let substituteSource: String?
        /// 换源的一句话说明，例如“来源 A 无法播放，已换成来源 B”。客户端按用户设置决定是否播报。
        public let substituteNotice: String?
        /// 整轨文件中的一段（CUE 分轨）：客户端只播这一段。旧服务器不发，为空。
        public let clipStart: Duration?
        public let clipEnd: Duration?
        /// 为 true 时数据是 DSF 格式的 DSD（服务器音乐库里的 DSD、SACD 镜像），客户端用自己的 DSD 播放器读取。
        public let dsdStream: Bool?
        public init(streamID: String, quality: AudioQuality, duration: Duration?,
                    previewStart: Duration?, previewEnd: Duration?, substituteSource: String? = nil,
                    substituteNotice: String? = nil, clipStart: Duration? = nil, clipEnd: Duration? = nil, dsdStream: Bool? = nil) {
            self.streamID = streamID; self.quality = quality; self.duration = duration
            self.previewStart = previewStart; self.previewEnd = previewEnd; self.substituteSource = substituteSource
            self.substituteNotice = substituteNotice
            self.clipStart = clipStart; self.clipEnd = clipEnd; self.dsdStream = dsdStream
        }
    }

    // MARK: 分页与错误

    /// 统一搜索结果：已按服务器规则排序；某些来源失败时单独说明。
    public struct SearchAllResponse: Codable, Sendable {
        public struct Failure: Codable, Sendable {
            public let platform: PlatformID
            public let message: String
            public init(platform: PlatformID, message: String) { self.platform = platform; self.message = message }
        }
        public let items: [SearchItem]
        public let failures: [Failure]
        public init(items: [SearchItem], failures: [Failure]) { self.items = items; self.failures = failures }
    }

    public struct PageResponse<Item: Codable & Sendable>: Codable, Sendable {
        public let items: [Item]
        public let nextCursor: String?
        public let total: Int?
        public init(items: [Item], nextCursor: String?, total: Int?) {
            self.items = items; self.nextCursor = nextCursor; self.total = total
        }
    }

    public struct ErrorResponse: Codable, Sendable, Error {
        public let category: MusicErrorCategory
        public let message: String
        public init(category: MusicErrorCategory, message: String) { self.category = category; self.message = message }
    }

    /// 每次取用都是新的编码器，调用方修改设置不会影响别处。
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
