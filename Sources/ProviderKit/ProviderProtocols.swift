import Foundation

/// 所有平台模块的基础协议。
///
/// 模块只在**真正实现**某类能力后才遵循下方对应的能力协议。
/// 不允许为了“先占位”而遵循协议并在方法里抛错或返回空结果（PRD §19）。
public protocol MusicProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func health() async -> ProviderHealth
}

// MARK: - 账号（§6）

/// 登录流程的可读状态（ACC-04）。
public enum LoginState: Sendable, Hashable {
    case awaitingUserAction(instructions: String)
    /// 二维码登录：提供图像数据与可访问的文字说明（ACC-05）。
    case qrCodePresented(imagePNG: Data, instructions: String)
    case awaitingConfirmation(instructions: String)
    case succeeded(AccountID)
    case cancelled
    case expired
    case failed(MusicError)
}

public struct AccountSummary: Sendable, Hashable {
    public let account: AccountID
    public let displayName: String?
    public init(account: AccountID, displayName: String?) {
        self.account = account
        self.displayName = displayName
    }
}

/// 权益：无法可靠读取时为 `.unverified`，而不是“非会员”（ACC-06）。
public enum EntitlementStatus: Sendable, Hashable {
    case unverified
    case none
    case active(label: String, expiresAt: Date?)
}

/// 账号状态与会话管理。具体登录方式由下面的登录协议分别声明，界面按协议显示入口，不按平台分支。
public protocol AccountProviding: MusicProvider {
    func currentAccount() async -> AccountSummary?
    func refreshCredentials() async throws
    func entitlements() async throws -> EntitlementStatus
    func logout() async throws
}

/// 二维码登录：流依次给出二维码、扫码后等待确认、成功 / 过期 / 失败。
/// 过期后流结束，不自动刷新二维码（ACC-04）；由用户决定是否重新开始。
public protocol QRLoginProviding: AccountProviding {
    /// 可选的扫码方式（如“用某某 App 扫码”“用另一个 App 扫码”）。只有一种时界面只显示一个按钮。
    var qrLoginVariants: [QRLoginVariant] { get }
    func beginQRLogin(variant: String?) -> AsyncStream<LoginState>
}

public struct QRLoginVariant: Hashable, Sendable, Codable {
    public let id: String
    /// 用于按钮文字，例如“微信扫码”。
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
    public static let standard = QRLoginVariant(id: "default", title: "二维码")
}

/// 短信验证码登录。
public protocol SMSLoginProviding: AccountProviding {
    func sendSMSCode(phone: String, countryCode: String) async throws
    func loginWithSMSCode(phone: String, code: String, countryCode: String) async throws -> AccountSummary
}

// MARK: - 内容

public enum SearchItem: Sendable, Hashable, Codable {
    case track(PlatformTrack)
    case album(PlatformAlbum)
    case artist(PlatformArtist)
    case playlist(PlatformPlaylist)
}

public protocol CatalogSearching: MusicProvider {
    var supportedSearchKinds: Set<SearchKind> { get }
    func search(_ query: String, kind: SearchKind, cursor: PageCursor?,
                context: RequestContext) async throws -> Page<SearchItem>
}

public protocol CatalogDetailReading: MusicProvider {
    func track(_ ref: PlatformResourceRef, context: RequestContext) async throws -> PlatformTrack
    func albumTracks(_ ref: PlatformResourceRef, cursor: PageCursor?,
                     context: RequestContext) async throws -> Page<PlatformTrack>
    func playlistTracks(_ ref: PlatformResourceRef, cursor: PageCursor?,
                        context: RequestContext) async throws -> Page<PlatformTrack>
}

/// 歌手详情：热门歌曲与专辑。能力为 `.detail(.artist)`。
public protocol ArtistReading: MusicProvider {
    func artistTracks(_ ref: PlatformResourceRef, cursor: PageCursor?,
                      context: RequestContext) async throws -> Page<PlatformTrack>
    func artistAlbums(_ ref: PlatformResourceRef, cursor: PageCursor?,
                      context: RequestContext) async throws -> Page<PlatformAlbum>
}

// MARK: - 个人资料库（§8）

public protocol LibraryReading: MusicProvider {
    var readableSections: Set<LibrarySection> { get }
    func library(_ section: LibrarySection, cursor: PageCursor?,
                 context: RequestContext) async throws -> Page<SearchItem>
}

/// 平台资料库写入（LIB-02、LIB-05）。是否允许写入由服务端按账户判断（只能用自己的账户，借用的不行）；
/// 模块只负责按上游行为发出请求，并以平台返回结果为准，失败时抛出错误。
public protocol LibraryWriting: MusicProvider {
    /// 本模块支持的写入能力（如 `.like`、`.libraryAdd(.album)`、`.followArtist`）。
    var writableCapabilities: Set<Capability> { get }
    func perform(_ capability: Capability, on ref: PlatformResourceRef,
                 context: RequestContext) async throws
}

public protocol PlaylistWriting: MusicProvider {
    var playlistOperations: Set<PlaylistWriteOperation> { get }
    func createPlaylist(named name: String, context: RequestContext) async throws -> PlatformPlaylist
    func renamePlaylist(_ playlist: PlatformResourceRef, to name: String, context: RequestContext) async throws
    /// 只接受本平台的曲目引用；跨平台须先取得经验证的映射（LIB-04）。
    func addTracks(_ tracks: [PlatformResourceRef], to playlist: PlatformResourceRef,
                   context: RequestContext) async throws
    func removeTracks(_ tracks: [PlatformResourceRef], from playlist: PlatformResourceRef,
                      context: RequestContext) async throws
    /// `newOrder` 为歌单全部曲目的新顺序。
    func reorder(_ playlist: PlatformResourceRef, newOrder: [PlatformResourceRef], context: RequestContext) async throws
    func deletePlaylist(_ playlist: PlatformResourceRef, context: RequestContext) async throws
}

// MARK: - 歌词（§11）

public struct LyricsQuery: Sendable, Hashable {
    public let unifiedTrack: UnifiedTrackID
    public let metadata: TrackMetadata
    /// 本平台的已知映射；没有时模块可按元数据检索。
    public let platformRef: PlatformResourceRef?
    public init(unifiedTrack: UnifiedTrackID, metadata: TrackMetadata, platformRef: PlatformResourceRef?) {
        self.unifiedTrack = unifiedTrack
        self.metadata = metadata
        self.platformRef = platformRef
    }
}

public struct LyricsResult: Sendable, Hashable, Codable {
    public let status: LyricsStatus
    public let tracks: [LyricsTrack]
    /// 本次匹配到的平台曲目，用于版本核对（LYR-10）。
    public let matchedRef: PlatformResourceRef?
    public init(status: LyricsStatus, tracks: [LyricsTrack], matchedRef: PlatformResourceRef?) {
        self.status = status
        self.tracks = tracks
        self.matchedRef = matchedRef
    }
}

/// 歌词模块不必具备播放能力（LYR-02，TEST-18）。
public protocol LyricsProviding: MusicProvider {
    var lyricsFeatures: Set<LyricsFeature> { get }
    func lyrics(for query: LyricsQuery, context: RequestContext) async throws -> LyricsResult
}

// MARK: - 下载（§12）

public protocol DownloadSourcing: MusicProvider {
    /// 以当前账号对该曲目的实际返回为准的可下载音质（DL-05、DL-07）；空表示不能下载。不以会员身份推断（§5.2）。
    /// 只返回完整歌曲；试听片段不算可下载。
    func downloadQualities(_ ref: PlatformResourceRef, context: RequestContext) async throws -> [AudioQuality]
    /// 按指定音质取得完整文件地址；该音质不可用时报错，不得改用其他音质（DL-12）。
    func resolveDownload(_ ref: PlatformResourceRef, qualityKey: String, context: RequestContext) async throws -> ResolvedStream
}
