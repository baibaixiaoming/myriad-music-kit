import Foundation

/// 歌词状态（LYR-04）。“无结果”与“服务失败”必须区分。
public enum LyricsStatus: Hashable, Sendable, Codable {
    case fetching
    case available
    case instrumental
    case noResult
    case uncertainMatch
    case serviceFailure(MusicErrorCategory)
}

public struct LyricsWord: Hashable, Sendable, Codable {
    public let text: String
    public let start: Duration
    public let duration: Duration?

    public init(text: String, start: Duration, duration: Duration?) {
        self.text = text
        self.start = start
        self.duration = duration
    }
}

public struct LyricsLine: Hashable, Sendable, Codable {
    public let text: String
    /// 无时间轴时为 nil；此时界面不得展示虚假的“当前句”（LYR-14）。
    public let start: Duration?
    public let words: [LyricsWord]?

    public init(text: String, start: Duration?, words: [LyricsWord]?) {
        self.text = text
        self.start = start
        self.words = words
    }
}

/// 已知歌词源格式（LYR-06）。列在这里不代表解析器已完成。
public enum LyricsSourceFormat: String, Hashable, Sendable, Codable {
    case plain, lrc, qrc, yrc, ttml, other
}

/// 一条来自单一来源的歌词轨道（原文 / 翻译 / 罗马音之一）。
public struct LyricsTrack: Hashable, Sendable, Codable {
    public enum Role: String, Hashable, Sendable, Codable { case original, translation, romanization }
    public let role: Role
    public let language: String?
    public let lines: [LyricsLine]
    public let source: PlatformID
    public let sourceFormat: LyricsSourceFormat
    /// 来源的内容版本标识（如有）。
    public let contentVersion: String?
    /// 署名与使用限制说明（LYR-16）。
    public let attribution: String?
    public let usageRestrictions: String?

    public init(role: Role, language: String?, lines: [LyricsLine], source: PlatformID,
                sourceFormat: LyricsSourceFormat, contentVersion: String? = nil,
                attribution: String? = nil, usageRestrictions: String? = nil) {
        self.role = role
        self.language = language
        self.lines = lines
        self.source = source
        self.sourceFormat = sourceFormat
        self.contentVersion = contentVersion
        self.attribution = attribution
        self.usageRestrictions = usageRestrictions
    }

    public var timing: Timing {
        if lines.contains(where: { $0.words?.isEmpty == false }) { return .word }
        if lines.contains(where: { $0.start != nil }) { return .line }
        return .none
    }
    public enum Timing: Sendable { case none, line, word }
}

/// 组合后的歌词。原文与其时间轴为主轨道；附加轨道必须带对齐结论（LYR-07/08/09）。
public struct ComposedLyrics: Hashable, Sendable {
    public struct Attached: Hashable, Sendable {
        public let track: LyricsTrack
        public let alignment: AlignmentVerdict
    }
    public enum AlignmentVerdict: Hashable, Sendable {
        case aligned
        /// 不可靠：只能作为单独文本或候选显示，不宣称已同步。
        case unreliable(reason: String)
    }

    public let primary: LyricsTrack
    public let attached: [Attached]
    /// 逐字 → 逐行 → 普通文本的降级原因（LYR-09）。
    public let degradationNote: String?
}
