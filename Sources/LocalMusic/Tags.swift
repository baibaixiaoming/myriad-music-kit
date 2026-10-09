import AVFoundation
import Foundation
import ProviderKit

/// 各种来源（FLAC 的 Vorbis 注释、ID3、iTunes 标签、APEv2、CUE）统一后的标签。
/// 键一律用大写的通用名：TITLE、ARTIST、ARTISTS（多值）、ALBUM、ALBUMARTIST、TRACKNUMBER、DISCNUMBER、DISCTOTAL、
/// DATE、COMPILATION、MUSICBRAINZ_ALBUMID、MUSICBRAINZ_TRACKID；古典唱片常用的 COMPOSER、CONDUCTOR、ORCHESTRA/ENSEMBLE、
/// PERFORMER（“人名 (乐器)”）、LABEL、CATALOGNUMBER、GENRE、WORK、MOVEMENTNAME。
struct TagValues: Sendable {
    var title: String?
    /// 原样的歌手写法（未拆分）。
    var artist: String?
    /// 文件里本来就写好的多位歌手（有它就不再拆分）。
    var artists: [String]?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var discTotal: Int?
    var year: Int?
    var compilation: Bool?
    var musicBrainzAlbumID: String?
    var musicBrainzTrackID: String?
    /// 古典唱片的演奏信息（文件里写了才有）。
    var composers: [String] = []
    var conductors: [String] = []
    /// 乐团、合唱团、室内乐团、四重奏等。
    var ensembles: [String] = []
    /// 独奏者与其他演奏者：人名与乐器或声部（没写乐器时为 nil）。
    var performers: [Credit] = []
    var label: String?
    var catalogNumber: String?
    var genres: [String] = []
    var work: String?
    var movement: String?

    struct Credit: Codable, Sendable, Hashable {
        let name: String
        let role: String?

        /// 解析“Anne-Sophie Mutter (violin)”“Mutter, violin”这类写法。
        static func parse(_ s: String) -> Credit {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let m = t.wholeMatch(of: /(.+?)\s*[\(（]([^()（）]+)[\)）]/) {
                return Credit(name: String(m.1).trimmingCharacters(in: .whitespaces), role: String(m.2).trimmingCharacters(in: .whitespaces))
            }
            return Credit(name: t, role: nil)
        }
    }

    /// 由“键 → 若干值”的字典生成（键不分大小写，常见的别名都认）。
    init(_ raw: [String: [String]]) {
        var d: [String: [String]] = [:]
        for (k, v) in raw {
            let key = k.uppercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
            d[key, default: []] += v.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))) }
                .filter { !$0.isEmpty }
        }
        func first(_ keys: String...) -> String? { keys.lazy.compactMap { d[$0]?.first }.first }
        title = first("TITLE")
        artist = first("ARTIST")
        if let multi = d["ARTISTS"], multi.count > 1 { artists = multi }
        else if let a = d["ARTIST"], a.count > 1 { artists = a }
        album = first("ALBUM")
        albumArtist = first("ALBUMARTIST", "ALBUMARTISTS", "BAND")
        func number(_ s: String?) -> (Int?, Int?) {
            guard let s else { return (nil, nil) }
            let parts = s.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            return (parts.first ?? nil, parts.count > 1 ? parts[1] : nil)
        }
        trackNumber = number(first("TRACKNUMBER", "TRACK")).0
        let disc = number(first("DISCNUMBER", "DISC"))
        discNumber = disc.0
        discTotal = disc.1 ?? Int(first("DISCTOTAL", "TOTALDISCS") ?? "")
        if let date = first("DATE", "YEAR", "ORIGINALDATE", "ORIGINALYEAR"),
           let y = Int(date.prefix(4)), (1000...2999).contains(y) { year = y }
        if let c = first("COMPILATION") { compilation = c == "1" || c.lowercased() == "true" }
        musicBrainzAlbumID = first("MUSICBRAINZALBUMID")
        musicBrainzTrackID = first("MUSICBRAINZTRACKID", "MUSICBRAINZRELEASETRACKID")
        // 多值：同一个键写了多次，或一个值里用“; ”分隔
        func all(_ keys: String...) -> [String] {
            var seen = Set<String>(), out: [String] = []
            for k in keys {
                for v in d[k] ?? [] {
                    for part in v.split(whereSeparator: { $0 == ";" || $0 == "；" }).map({ $0.trimmingCharacters(in: .whitespaces) })
                    where !part.isEmpty && seen.insert(part.lowercased()).inserted { out.append(part) }
                }
            }
            return out
        }
        composers = all("COMPOSER")
        conductors = all("CONDUCTOR")
        ensembles = all("ORCHESTRA", "ENSEMBLE", "CHOIR", "CHORUS")
        performers = all("PERFORMER", "SOLOIST", "SOLOISTS").map(Credit.parse)
        label = first("LABEL", "ORGANIZATION", "PUBLISHER", "RECORDLABEL")
        catalogNumber = first("CATALOGNUMBER", "CATALOG", "LABELNO", "CATALOGUENUMBER")
        genres = all("GENRE", "STYLE")
        work = first("WORK", "WORKTITLE")
        movement = first("MOVEMENTNAME", "MOVEMENT")
    }

    // MARK: FLAC 的 Vorbis 注释（自己读，能拿到全部字段与多值歌手）

    static func flac(_ url: URL) -> TagValues? {
        guard let r = try? FileReader(forReadingFrom: url) else { return nil }
        defer { try? r.close() }
        guard (try? r.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var pos: UInt64 = 4
        for _ in 0..<64 {
            try? r.seek(toOffset: pos)
            guard let h = try? r.read(upToCount: 4), h.count == 4 else { return nil }
            let last = h[h.startIndex] & 0x80 != 0, type = h[h.startIndex] & 0x7F
            let len = Int(h[h.startIndex + 1]) << 16 | Int(h[h.startIndex + 2]) << 8 | Int(h[h.startIndex + 3])
            if type == 4 {
                guard len < 16 << 20, let body = try? r.read(upToCount: len), body.count == len else { return nil }
                return TagValues(vorbis(body))
            }
            pos += 4 + UInt64(len)
            if last { break }
        }
        return nil
    }

    static func vorbis(_ b: Data) -> [String: [String]] {
        var p = 0
        func u32() -> Int? {
            guard p + 4 <= b.count else { return nil }
            defer { p += 4 }
            return Int(b[b.startIndex + p]) | Int(b[b.startIndex + p + 1]) << 8 | Int(b[b.startIndex + p + 2]) << 16 | Int(b[b.startIndex + p + 3]) << 24
        }
        guard let vendor = u32(), p + vendor <= b.count else { return [:] }
        p += vendor
        guard let count = u32() else { return [:] }
        var out: [String: [String]] = [:]
        for _ in 0..<min(count, 10_000) {
            guard let n = u32(), p + n <= b.count else { break }
            let s = String(decoding: b[(b.startIndex + p) ..< (b.startIndex + p + n)], as: UTF8.self)
            p += n
            guard let eq = s.firstIndex(of: "=") else { continue }
            out[String(s[..<eq]).uppercased(), default: []].append(String(s[s.index(after: eq)...]))
        }
        return out
    }

    /// FLAC 里的歌词（LYRICS 或 UNSYNCEDLYRICS 字段）。
    static func flacLyrics(_ url: URL) -> String? {
        guard let r = try? FileReader(forReadingFrom: url), (try? r.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        defer { try? r.close() }
        var pos: UInt64 = 4
        for _ in 0..<64 {
            try? r.seek(toOffset: pos)
            guard let h = try? r.read(upToCount: 4), h.count == 4 else { return nil }
            let len = Int(h[h.startIndex + 1]) << 16 | Int(h[h.startIndex + 2]) << 8 | Int(h[h.startIndex + 3])
            if h[h.startIndex] & 0x7F == 4, let body = try? r.read(upToCount: len) {
                let d = vorbis(body)
                return d["LYRICS"]?.first ?? d["UNSYNCEDLYRICS"]?.first
            }
            pos += 4 + UInt64(len)
            if h[h.startIndex] & 0x80 != 0 { break }
        }
        return nil
    }

    /// 自己能读的格式（FLAC、DSD、APE）的标签；其他格式返回 nil。
    static func of(_ url: URL) -> TagValues? {
        switch url.pathExtension.lowercased() {
        case "flac": return flac(url)
        case "dsf", "dff": return (try? DSDFile(url: url)).map { TagValues($0.rawTags) }
        case "ape": return (try? APEFile(url: url)).map { TagValues($0.rawTags) }
        default: return nil
        }
    }

    // MARK: 系统读出的标签（MP3、M4A、WAV、AIFF 等）

    static func asset(_ asset: AVAsset) async -> (TagValues, lyrics: String?) {
        var d: [String: [String]] = [:]
        var lyrics: String?
        func add(_ key: String, _ value: String?) { if let value, !value.isEmpty { d[key, default: []].append(value) } }
        if let common = try? await asset.load(.commonMetadata) {
            for item in common {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.stringValue)
                switch key {
                case .commonKeyTitle: add("TITLE", value)
                case .commonKeyArtist: add("ARTIST", value)
                case .commonKeyAlbumName: add("ALBUM", value)
                case .commonKeyCreationDate: add("DATE", value)
                default: break
                }
            }
        }
        if let all = try? await asset.load(.metadata) {
            for item in all {
                let id = item.identifier
                let raw = id?.rawValue ?? ""
                let value = try? await item.load(.stringValue)
                switch id {
                case .iTunesMetadataAlbumArtist?, .id3MetadataBand?: add("ALBUMARTIST", value)
                case .id3MetadataUnsynchronizedLyric?, .iTunesMetadataLyrics?: lyrics = value
                case .iTunesMetadataTrackNumber?, .id3MetadataTrackNumber?, .iTunesMetadataDiscNumber?, .id3MetadataPartOfASet?:
                    let key = id == .iTunesMetadataTrackNumber || id == .id3MetadataTrackNumber ? "TRACKNUMBER" : "DISCNUMBER"
                    if let value { add(key, value) }
                    else { add(key, Self.iTunesNumberPair(try? await item.load(.dataValue))) }
                case .id3MetadataYear?, .id3MetadataRecordingTime?, .iTunesMetadataReleaseDate?: add("DATE", value)
                case .iTunesMetadataDiscCompilation?: add("COMPILATION", value)
                case .id3MetadataComposer?, .iTunesMetadataComposer?: add("COMPOSER", value)
                case .id3MetadataConductor?, .iTunesMetadataConductor?: add("CONDUCTOR", value)
                case .id3MetadataPublisher?, .iTunesMetadataPublisher?: add("LABEL", value)
                case .id3MetadataContentType?, .iTunesMetadataUserGenre?: add("GENRE", value)
                case .id3MetadataContentGroupDescription?: add("WORK", value)
                case .id3MetadataMusicianCreditsList?:
                    // “乐器\0人名\0……”成对
                    let parts = (value ?? "").split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                    var k = 0
                    while k + 1 < parts.count { if !parts[k + 1].isEmpty { add("PERFORMER", "\(parts[k + 1]) (\(parts[k]))") }; k += 2 }
                case .id3MetadataUserText?:
                    // ID3 的自定义文字：说明（如“MusicBrainz Album Id”）作键
                    let desc = (try? await item.load(.extraAttributes))?[.info] as? String
                    if let desc { add(desc, value) }
                default:
                    // iTunes 自由标签（如 com.apple.iTunes:MusicBrainz Album Id）、FLAC 以外的注释类标签
                    if let colon = raw.lastIndex(of: ":") { add(String(raw[raw.index(after: colon)...]), value) }
                    else if raw.hasSuffix("TCMP") { add("COMPILATION", value) }
                    else if raw.hasSuffix("%A9wrk") || raw.hasSuffix("©wrk") { add("WORK", value) }        // iTunes 作品
                    else if raw.hasSuffix("%A9mvn") || raw.hasSuffix("©mvn") { add("MOVEMENTNAME", value) } // iTunes 乐章名
                }
            }
        }
        return (TagValues(d), lyrics)
    }

    /// iTunes 的音轨号、碟号（trkn、disk）是二进制：2 字节保留、2 字节序号、2 字节总数（大端）。
    /// 系统读不出文字，这里换成“序号/总数”。
    static func iTunesNumberPair(_ data: Data?) -> String? {
        guard let data, data.count >= 6 else { return nil }
        let b = [UInt8](data)
        let number = Int(b[2]) << 8 | Int(b[3]), total = Int(b[4]) << 8 | Int(b[5])
        guard number > 0 else { return nil }
        return total > 0 ? "\(number)/\(total)" : "\(number)"
    }
}

// MARK: - 比较用的规整

/// 只用于判断“是不是同一个”，显示时仍用原来的写法：全角转半角、兼容字符统一、忽略大小写、
/// 引号与横线统一、合并空格、繁体转简体。结果缓存，避免重复计算。
final class NameNormalizer: @unchecked Sendable {
    static let shared = NameNormalizer()
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    func key(_ s: String) -> String {
        if let hit = lock.withLock({ cache[s] }) { return hit }
        var t = s.precomposedStringWithCompatibilityMapping
        t = t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
        t = t.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? t
        t = t.lowercased()
        let map: [Character: Character] = ["‘": "'", "’": "'", "“": "\"", "”": "\"", "‐": "-", "‑": "-", "‒": "-", "–": "-", "—": "-",
                                           "―": "-", "〜": "~", "～": "~", "·": "·", "・": "·"]
        t = String(t.map { map[$0] ?? $0 })
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        lock.withLock { cache[s] = t }
        return t
    }
}

// MARK: - 歌手拆分

/// 只拆明确的分隔：“;”“；”“、”“/”（白名单里的名字除外）以及 feat.、ft.、featuring（括号里的也算）。
/// “&”“和”“,”“and”“x”不拆，避免拆错乐队名。参考 Navidrome、beets、Jellyfin 的做法自行编写。
enum ArtistSplitter {
    /// 名字本身带分隔符、不能拆的歌手（比较时不分大小写）。
    static let whitelist = ["AC/DC", "DJ Kool Herc / Grandmaster Flash", "Simon & Garfunkel", "Earth, Wind & Fire",
                            "Crosby, Stills, Nash & Young", "Emerson, Lake & Palmer", "Blood, Sweat & Tears"]

    static func split(_ raw: String?) -> [String] {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return [] }
        var kept: [String] = []
        for name in whitelist where text.range(of: name, options: .caseInsensitive) != nil {
            text = text.replacingOccurrences(of: name, with: "\u{1}\(kept.count)\u{1}", options: .caseInsensitive)
            kept.append(name)
        }
        // feat. 一类：括号里的与不在括号里的都换成分隔符
        let feat = #"(?i)\s*[\(\[（【]?\s*\b(?:feat\.?|ft\.?|featuring)\s+"#
        text = text.replacingOccurrences(of: feat, with: ";", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[\)\]）】]\s*$"#, with: "", options: .regularExpression)
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ";；、/／"))
        return parts.map { p in
            var s = p.trimmingCharacters(in: .whitespaces)
            for (i, name) in kept.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: name) }
            return s
        }.filter { !$0.isEmpty }
    }
}

// MARK: - 从文件名与文件夹推断

enum PathHints {
    /// 碟子文件夹：CD1、CD 01、Disc 2、Disk3、碟一、第二碟、光盘 2 等，后面可以带说明（如“CD12 - 贝多芬”）。返回碟号。
    static func discNumber(folder name: String) -> Int? {
        let t = name.trimmingCharacters(in: .whitespaces)
        let patterns = [#"(?i)^(?:cd|disc|disk|dvd|sacd|碟|光盘|唱片)\s*[-_.]?\s*(\d{1,3})(?:\D.*)?$"#,
                        #"^第\s*([0-9一二三四五六七八九十百]+)\s*[碟张盘](?:.*)?$"#,
                        #"^碟\s*([一二三四五六七八九十]+)(?:.*)?$"#]
        for p in patterns {
            guard let r = try? NSRegularExpression(pattern: p),
                  let m = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let g = Range(m.range(at: 1), in: t) else { continue }
            let num = String(t[g])
            if let n = Int(num) { return n }
            if let n = chineseNumber(num) { return n }
        }
        return nil
    }

    static func chineseNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if s == "十" { return 10 }
        if s.hasPrefix("十"), let d = s.last.flatMap({ digits[$0] }) { return 10 + d }
        if s.count == 2, s.hasSuffix("十"), let d = s.first.flatMap({ digits[$0] }) { return d * 10 }
        if s.count == 3, let a = s.first.flatMap({ digits[$0] }), s.dropFirst().first == "十", let b = s.last.flatMap({ digits[$0] }) { return a * 10 + b }
        return s.count == 1 ? s.first.flatMap { digits[$0] } : nil
    }

    /// 专辑名末尾的碟号说明（“ (Disc 1)”“ CD2”“ [第二碟]”等）：去掉后的名字与碟号。
    static func stripDisc(_ album: String) -> (String, Int?) {
        let p = #"(?i)\s*[\(\[（【\-–—:：,，]?\s*(?:cd|disc|disk|碟|第)\s*([0-9一二三四五六七八九十]+)\s*[碟张]?\s*[\)\]）】]?\s*$"#
        guard let r = try? NSRegularExpression(pattern: p),
              let m = r.firstMatch(in: album, range: NSRange(album.startIndex..., in: album)),
              let whole = Range(m.range, in: album), let g = Range(m.range(at: 1), in: album),
              whole.lowerBound > album.startIndex else { return (album, nil) }
        let num = String(album[g])
        return (String(album[..<whole.lowerBound]).trimmingCharacters(in: .whitespaces), Int(num) ?? chineseNumber(num))
    }

    /// 文件夹名“歌手 - 专辑”。
    static func artistAlbum(folder: String) -> (artist: String, album: String)? {
        let parts = folder.components(separatedBy: " - ")
        guard parts.count == 2, !parts[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        // 去掉专辑名前后的年份标注，如“(1998)”“[2001]”
        let album = parts[1].replacingOccurrences(of: #"^\s*[\(\[]\d{4}[\)\]]\s*|\s*[\(\[]\d{4}[\)\]]\s*$"#, with: "", options: .regularExpression)
        return (parts[0].trimmingCharacters(in: .whitespaces), album.trimmingCharacters(in: .whitespaces))
    }

    /// 文件名（不含扩展名）：“01 - 歌手 - 歌名”“01. 歌名”“01 歌名”“歌手 - 歌名”。参考 beets 的 fromfilename 规则。
    static func fileName(_ name: String) -> (track: Int?, artist: String?, title: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        func match(_ p: String) -> [String]? {
            guard let r = try? NSRegularExpression(pattern: p), let m = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: t).map { String(t[$0]) } ?? "" }
        }
        if let g = match(#"^(\d{1,3})\s*[-._]\s*(.+?)\s+-\s+(.+)$"#) { return (Int(g[0]), g[1], g[2]) }
        if let g = match(#"^(\d{1,3})\s*[-._、]?\s+(.+)$"#) ?? match(#"^(\d{1,3})\s*[-._、]\s*(.+)$"#) { return (Int(g[0]), nil, g[1]) }
        if let g = match(#"^(.+?)\s+-\s+(.+)$"#) { return (nil, g[0], g[1]) }
        return (nil, nil, t)
    }
}
