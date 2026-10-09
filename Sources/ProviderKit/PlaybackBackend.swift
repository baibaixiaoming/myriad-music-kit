import Foundation

/// 播放会话标识。切歌或切源时递增，旧会话的回调一律忽略（PLAY-03）。
public struct PlaybackSessionToken: Hashable, Sendable, Comparable {
    public let generation: UInt64
    public init(generation: UInt64) { self.generation = generation }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.generation < rhs.generation }
}

public enum PlaybackEvent: Sendable, Hashable {
    case started(PlaybackSessionToken)
    case progress(PlaybackSessionToken, position: Duration)
    case paused(PlaybackSessionToken)
    /// 用户仍希望播放，但当前播放所需的数据不足；位置是实际停住的媒体时间。
    case buffering(PlaybackSessionToken, position: Duration)
    /// 跳转**实际完成**，与“发出跳转动作”分开（AX-06）。
    case seekCompleted(PlaybackSessionToken, position: Duration)
    case finished(PlaybackSessionToken)
    /// 已无缝接上预先准备好的下一首（同一会话继续，协调器把队列前进一首）。
    case advanced(PlaybackSessionToken)
    /// 后端只拿到了试听片段，不得当作全曲成功（PLAY-06）。
    case previewOnly(PlaybackSessionToken)
    case failed(PlaybackSessionToken, MusicError)
}

/// 已知的当前音质信息（PLAY-09）。
public struct PlaybackQualityInfo: Sendable, Hashable {
    public let platformLabel: String?
    public let detail: AudioQuality?
}

/// 播放后端。一个平台可以有多个后端；上层只通过此约定操作。
/// 后端不得自行推进统一队列（PLAY-08），播完只上报 `.finished`。
public protocol PlaybackBackend: Sendable {
    var identifier: String { get }
    var platform: PlatformID { get }
    var supportedControls: Set<Capability> { get }

    func load(_ ref: PlatformResourceRef, session: PlaybackSessionToken,
              context: RequestContext) async throws
    func play(session: PlaybackSessionToken) async throws
    func pause(session: PlaybackSessionToken) async throws
    func seek(to position: Duration, session: PlaybackSessionToken) async throws
    /// 停止并释放；切换后端前必须调用，保证同一时刻只有一个后端出声。
    func stop() async

    var events: AsyncStream<PlaybackEvent> { get }
}

/// 为播放后端提供后端实例的模块。
public protocol PlaybackProviding: MusicProvider {
    func playbackBackends() -> [any PlaybackBackend]
}

// MARK: - 播放地址

/// 平台提供的音质级别（如“标准”“极高”“无损”，由各来源自行定义）。
/// `tier` 等是可选的通用标注（协议“通用音质档位”）：旧服务器不发，客户端照常按 `label` 显示。
public struct StreamQualityLevel: Hashable, Sendable, Codable {
    public let key: String
    public let label: String
    /// 这个级别对应的通用档位；来源说不清时为 nil。
    public var tier: QualityTier?
    /// 多声道（true）或双声道（false）；未知为 nil。
    public var multichannel: Bool?
    /// 是否空间音频（如杜比全景声）；未知为 nil。
    public var spatial: Bool?

    public init(key: String, label: String, tier: QualityTier? = nil, multichannel: Bool? = nil, spatial: Bool? = nil) {
        self.key = key; self.label = label
        self.tier = tier; self.multichannel = multichannel; self.spatial = spatial
    }

    /// 在一个来源的级别里挑“不超过上限的最高档”（同档取列表里靠后的，即来源认为更好的那个）。
    /// - 没有任何级别标了档位：返回 nil（由来源默认）。
    /// - 标了档位的级别全都高于上限：返回其中档位最低的（最接近上限）。
    /// - 空间音频、多声道的级别只在没有普通级别可选时才考虑（上限只管档位，不替用户打开空间音频）。
    public static func best(in levels: [StreamQualityLevel], notAbove cap: QualityTier) -> StreamQualityLevel? {
        let tagged = levels.filter { $0.tier != nil }
        let plain = tagged.filter { $0.spatial != true && $0.multichannel != true }
        let pool = plain.isEmpty ? tagged : plain
        guard !pool.isEmpty else { return nil }
        var best: StreamQualityLevel?
        for level in pool where level.tier! <= cap {
            if best == nil || level.tier! >= best!.tier! { best = level }
        }
        if let best { return best }
        return pool.min { $0.tier! < $1.tier! }
    }
}

/// 解析出的临时播放地址。只在播放后端内部短期使用，不存入曲目或资料库（§4.4、DATA-04）。
public struct ResolvedStream: Sendable {
    public let url: URL
    public let httpHeaders: [String: String]
    /// 服务端实际返回的音质，可能与请求的不同（例如请求 hires 返回 lossless）。
    public let quality: AudioQuality
    public let duration: Duration?
    /// 只给了试听片段时的区间（PLAY-06）。nil 表示完整歌曲。
    public let previewRange: ClosedRange<Duration>?
    public let expiresAt: Date?
    /// 只播放文件中的一段（例如 CUE 分轨：整轨文件里的某一首）。nil 表示整个文件。
    /// 播放器把这一段当作一首完整的歌：进度从 0 开始，播到段尾即结束。
    public var clipRange: Range<Duration>?
    /// 自动换源时实际使用的来源说明，例如“来源 B（同一录音，自动换源）”。
    public var substituteSource: String?
    /// 换源的一句话说明（例如“来源 A 无法播放，已换成来源 B”）。
    public var substituteNotice: String?
    /// 数据是经网络传来的 DSF 格式 DSD（服务器音乐库），由 DSD 播放器读取。
    public var isDSDStream = false

    public init(url: URL, httpHeaders: [String: String] = [:], quality: AudioQuality, duration: Duration?,
                previewRange: ClosedRange<Duration>?, expiresAt: Date? = nil, substituteSource: String? = nil,
                substituteNotice: String? = nil, clipRange: Range<Duration>? = nil) {
        self.clipRange = clipRange
        self.substituteSource = substituteSource
        self.substituteNotice = substituteNotice
        self.url = url
        self.httpHeaders = httpHeaders
        self.quality = quality
        self.duration = duration
        self.previewRange = previewRange
        self.expiresAt = expiresAt
    }

    public var isPreview: Bool { previewRange != nil }
}

/// 能给出可直接播放的音频地址的模块。由通用的地址播放后端使用。
public protocol StreamResolving: MusicProvider {
    var streamQualityLevels: [StreamQualityLevel] { get }
    func resolveStream(_ ref: PlatformResourceRef, preferredLevel: String?,
                       context: RequestContext) async throws -> ResolvedStream
    /// 带完整曲目信息的版本：远端模块据此在只能试听时到其他平台匹配同一录音。默认等同于按编号解析。
    func resolveStream(for track: PlatformTrack, preferredLevel: String?,
                       context: RequestContext) async throws -> ResolvedStream
}

extension StreamResolving {
    public func resolveStream(for track: PlatformTrack, preferredLevel: String?,
                              context: RequestContext) async throws -> ResolvedStream {
        try await resolveStream(track.ref, preferredLevel: preferredLevel, context: context)
    }
}
