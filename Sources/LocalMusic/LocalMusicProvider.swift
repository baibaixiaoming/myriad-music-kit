import AVFoundation
import Foundation
import ProviderKit

extension PlatformID {
    public static let local = PlatformID("local")
    /// 家庭服务器上的音乐库（与客户端本机的本地音乐分开显示）。
    public static let serverLibrary = PlatformID("serverlib")
}

/// 本地音乐（ADR-0003 第 16 节）：用户添加的音乐文件夹，客户端自己扫描与播放，不需要服务器。
/// 文件夹以安全访问书签保存（上架沙盒版本需要），索引保存在客户端统一数据文件夹 `config/local-library.json`。
public actor LocalMusicLibrary {
    public struct Folder: Codable, Sendable, Hashable {
        public let id: String
        public var displayPath: String
        public var bookmark: Data
    }

    public struct IndexedTrack: Codable, Sendable {
        public let path: String           // 平台内编号即文件路径
        public let folderID: String
        public let title: String
        public let artists: [String]
        public let album: String?
        public let durationMS: Int?
        public let trackNumber: Int?
        public internal(set) var discNumber: Int?
        public let embeddedLyrics: String?
        /// 专辑艺人（分专辑用；没有时用第一位艺人）。
        public internal(set) var albumArtist: String? = nil
        /// CUE 分轨：在整轨文件中的起止（毫秒）与音轨号。普通文件为 nil。
        public internal(set) var startMS: Int? = nil
        public internal(set) var endMS: Int? = nil
        public internal(set) var cueTrack: Int? = nil
        /// SACD 镜像：区（2 双声道、6 多声道）与曲目号。
        public internal(set) var sacdArea: Int? = nil
        /// 整张 CD 镜像的轨号（路径为目录文件或镜像本身）。
        public internal(set) var cdTrack: Int? = nil
        /// 数据光盘镜像里的文件路径。
        public internal(set) var innerPath: String? = nil
        /// 音频格式：采样率（DSD 为 DSD 采样率，如 2822400）、位深（DSD 为 1）、编码（小写：flac、alac、wav、aiff、ape、mp3、aac、dsd、cd）、是否无损。
        /// 整理资料库时用来区分音质版本。
        public internal(set) var sampleRate: Int? = nil
        public internal(set) var bitDepth: Int? = nil
        public internal(set) var codec: String? = nil
        public internal(set) var lossless: Bool? = nil

        /// 原样的歌手写法（未拆分）、年份、碟片总数、合辑标记、唱片资料库（MusicBrainz）编号：整理资料库用。
        public internal(set) var artistTag: String? = nil
        public internal(set) var year: Int? = nil
        public internal(set) var discTotal: Int? = nil
        public internal(set) var compilation: Bool? = nil
        public internal(set) var musicBrainzAlbumID: String? = nil
        public internal(set) var musicBrainzTrackID: String? = nil

        /// 古典唱片的演奏信息（文件标签里写了才有）：作曲家、指挥、乐团或合唱团、独奏者（人名与乐器）、
        /// 唱片公司、唱片编号、风格、作品名、乐章名。
        public internal(set) var composers: [String]? = nil
        public internal(set) var conductors: [String]? = nil
        public internal(set) var ensembles: [String]? = nil
        public internal(set) var performers: [Credit]? = nil
        public internal(set) var label: String? = nil
        public internal(set) var catalogNumber: String? = nil
        public internal(set) var genres: [String]? = nil
        public internal(set) var work: String? = nil
        public internal(set) var movement: String? = nil

        public struct Credit: Codable, Sendable, Hashable {
            public let name: String
            /// 乐器或声部，如“violin”“soprano”；没写时为 nil。
            public let role: String?
        }

        /// 由统一标签生成曲目记录。
        static func make(path: String, folderID: String, tags t: TagValues, fallbackTitle: String,
                         durationMS: Int?, lyrics: String? = nil) -> IndexedTrack {
            var track = IndexedTrack(path: path, folderID: folderID,
                                     title: t.title?.isEmpty == false ? t.title! : fallbackTitle,
                                     artists: t.artists ?? ArtistSplitter.split(t.artist),
                                     album: t.album?.isEmpty == false ? t.album : nil,
                                     durationMS: durationMS, trackNumber: t.trackNumber, discNumber: t.discNumber, embeddedLyrics: lyrics)
            track.albumArtist = t.albumArtist
            track.artistTag = t.artist
            track.year = t.year
            track.discTotal = t.discTotal
            track.compilation = t.compilation
            track.musicBrainzAlbumID = t.musicBrainzAlbumID
            track.musicBrainzTrackID = t.musicBrainzTrackID
            func list(_ a: [String]) -> [String]? { a.isEmpty ? nil : a }
            track.composers = list(t.composers)
            track.conductors = list(t.conductors)
            track.ensembles = list(t.ensembles)
            track.performers = t.performers.isEmpty ? nil : t.performers.map { Credit(name: $0.name, role: $0.role) }
            track.label = t.label
            track.catalogNumber = t.catalogNumber
            track.genres = list(t.genres)
            track.work = t.work
            track.movement = t.movement
            return track
        }

        mutating func setFormat(_ f: AudioFormat?) {
            guard let f else { return }
            sampleRate = f.sampleRate; bitDepth = f.bitDepth; codec = f.codec; lossless = f.lossless
        }

        /// 按实际格式归出的通用音质档位（格式还没读出时为 nil）。有损文件的码率索引里没有记，按编码判断不了时为 nil。
        public var qualityTier: QualityTier? {
            QualityTier.classify(codec: codec, sampleRateHz: sampleRate, bitDepth: bitDepth, lossless: lossless)
        }

        /// 曲目编号：普通文件为路径；CUE 分轨为“路径#音轨号”；SACD 镜像为“路径#sacd=区,曲目”。
        public var id: String {
            if let a = sacdArea, let n = trackNumber { return "\(path)#sacd=\(a),\(n)" }
            if let n = cdTrack { return "\(path)#cd=\(n)" }
            if let p = innerPath { return "\(path)#iso=\(p)" }
            return cueTrack.map { "\(path)#\($0)" } ?? path
        }
        var albumKey: String { "\(albumArtist ?? artists.first ?? "")\u{1F}\(album ?? "")" }
        var artistNames: [String] { artists.isEmpty ? ["未知歌手"] : artists }
    }

    /// 文件指纹：大小与修改时间都没变，就认为内容没变，不再重读。
    public struct Fingerprint: Codable, Sendable, Equatable {
        let size: Int64
        let modified: Double
    }

    /// 索引里的一条：一个音乐文件，或一组相关文件（CUE 与整轨、光盘镜像目录与数据文件）产生的曲目。
    public struct Record: Codable, Sendable {
        let folderID: String
        /// 涉及的文件及其指纹；任何一个变了就重新索引。
        let files: [String: Fingerprint]
        /// 被这一条“包含”的文件（整轨文件、镜像数据文件），不再单独收录。
        let covers: [String]
        let tracks: [IndexedTrack]
        /// 没有歌名、还没查到的整张 CD 镜像的光盘编号：之后能查询时重新索引。
        var pendingDisc: String? = nil
        /// 索引内容的版本：旧版本的记录在下次检查时重新读取（例如新增了音频格式信息）。
        var indexVersion: Int? = LocalMusicLibrary.indexVersion
        /// 所属文件夹（数据库按文件夹建索引用）。
        public var folderIdentifier: String { folderID }
    }

    /// 文件夹列表与光盘查询缓存（数据量小，整体保存）。
    public struct Meta: Codable, Sendable {
        var folders: [Folder] = []
        /// 按光盘编号查到的歌名（避免每次扫描都联网）；查不到的记下时间，一周后再试。
        var discInfo: [String: DiscInfo] = [:]
        var discMisses: [String: Date] = [:]
        public init() {}
    }

    /// 文件夹当前的状态（给管理页显示）。
    public enum FolderStatus: Sendable, Equatable {
        case ok
        /// 读不到（网络盘没挂载、移动硬盘没接）：保留原来的索引。
        case unavailable
    }

    /// 扫描进度。
    public struct ScanProgress: Sendable {
        public var folder: String
        public var checked: Int
        public var reindexed: Int
    }

    /// 没有 CD-Text 的整张 CD 镜像按光盘目录查歌名。为 nil 时不查。
    private var discLookup: DiscLookup?
    public func setDiscLookup(_ lookup: DiscLookup?) { discLookup = lookup }

    /// 镜像里没有歌名时，用缓存或联网查到的信息补上。
    /// 返回仍然没有歌名的光盘编号（之后能查询时再试）。
    @discardableResult
    func fillDiscInfo(_ image: inout CDImage) async -> String? {
        guard image.tracks.allSatisfy({ $0.title == nil }), let toc = image.toc else { return nil }
        let id = toc.discID
        var info = meta.discInfo[id]
        if info == nil, let lookup = discLookup {
            if let missed = meta.discMisses[id], Date().timeIntervalSince(missed) < 7 * 86400 { return id }
            info = await lookup(toc)
            if let info { meta.discInfo[id] = info } else { meta.discMisses[id] = Date() }
            metaChanged = true
        }
        guard let info else { return id }
        image.title = image.title ?? info.album
        image.performer = image.performer ?? info.artist
        for i in image.tracks.indices {
            guard let t = info.tracks.first(where: { $0.number == image.tracks[i].number }) else { continue }
            image.tracks[i].title = t.title
            image.tracks[i].performer = t.artist ?? info.artist
        }
        return nil
    }

    /// 待查的光盘现在可以查了（已能联网查询、且不在一周内查不到的名单里，或已有缓存结果）。
    func discNowAvailable(_ id: String?) -> Bool {
        guard let id else { return false }
        if meta.discInfo[id] != nil { return true }
        guard discLookup != nil else { return false }
        return meta.discMisses[id].map { Date().timeIntervalSince($0) >= 7 * 86400 } ?? true
    }

    /// 当前的索引内容版本（2：记录音频格式；3：记录年份、碟片总数、合辑、唱片资料库编号与原始歌手写法；
    /// 4：记录作曲家、指挥、乐团、独奏者、唱片公司、唱片编号、风格、作品名、乐章名）。
    static let indexVersion = 4

    /// 一首歌的音频格式。
    struct AudioFormat: Sendable {
        let sampleRate: Int?
        let bitDepth: Int?
        let codec: String
        let lossless: Bool

        static let cd = AudioFormat(sampleRate: 44100, bitDepth: 16, codec: "cd", lossless: true)
        static func dsd(_ rate: Int) -> AudioFormat { AudioFormat(sampleRate: rate, bitDepth: 1, codec: "dsd", lossless: true) }

        /// 从系统读出的音频格式里取。
        static func read(_ asset: AVAsset, ext: String) async -> AudioFormat? {
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let desc = try? await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return nil }
            let rate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : nil
            // 无损压缩格式的位深记在标志里：1 为 16 位、2 为 20 位、3 为 24 位、4 为 32 位
            func losslessBits() -> Int? { [1: 16, 2: 20, 3: 24, 4: 32][Int(asbd.mFormatFlags)] }
            switch asbd.mFormatID {
            case kAudioFormatLinearPCM:
                let name = ["aif", "aiff", "aifc"].contains(ext) ? "aiff" : ext == "caf" ? "caf" : "wav"
                return AudioFormat(sampleRate: rate, bitDepth: Int(asbd.mBitsPerChannel), codec: name, lossless: true)
            case kAudioFormatFLAC: return AudioFormat(sampleRate: rate, bitDepth: losslessBits(), codec: "flac", lossless: true)
            case kAudioFormatAppleLossless: return AudioFormat(sampleRate: rate, bitDepth: losslessBits(), codec: "alac", lossless: true)
            case kAudioFormatMPEGLayer3: return AudioFormat(sampleRate: rate, bitDepth: nil, codec: "mp3", lossless: false)
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
                return AudioFormat(sampleRate: rate, bitDepth: nil, codec: "aac", lossless: false)
            default: return AudioFormat(sampleRate: rate, bitDepth: nil, codec: ext.isEmpty ? "audio" : ext, lossless: false)
            }
        }

        /// 读取一个音乐文件的格式（DSD、APE 用自己的读取器）。
        static func probe(_ url: URL) async -> AudioFormat? {
            switch url.pathExtension.lowercased() {
            case "dsf", "dff": return (try? DSDFile(url: url)).map { .dsd($0.sampleRate) }
            case "ape": return (try? APEFile(url: url)).map { AudioFormat(sampleRate: $0.sampleRate, bitDepth: $0.bitsPerSample, codec: "ape", lossless: true) }
            default:
                let made = FileAccess.asset(for: url)
                defer { withExtendedLifetime(made.owner) {} }
                return await read(made.asset, ext: url.pathExtension.lowercased())
            }
        }
    }

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "mp4", "dsf", "dff", "ape", "iso"]
    static let descriptorExtensions: Set<String> = ["cue", "ccd", "nrg", "mds"]

    private let store: any MusicLibraryStore
    private var meta = Meta()
    /// 以主文件路径为键。
    private var records: [String: Record] = [:]
    private var metaChanged = false
    /// 全部曲目（已排序）与按编号的索引。
    private var tracks: [IndexedTrack] = []
    private var byID: [String: IndexedTrack] = [:]
    /// 整理后的目录（专辑、歌手、去重后的歌曲）；索引变了就作废，下次查询时重建。
    private var cachedCatalog: LibraryCatalog?
    var catalog: LibraryCatalog {
        if let c = cachedCatalog { return c }
        let c = LibraryCatalog.build(tracks)
        cachedCatalog = c
        return c
    }
    public private(set) var folderStatus: [String: FolderStatus] = [:]
    public private(set) var progress: ScanProgress?
    public private(set) var lastScan: Date?
    /// 上次扫描检查的文件数与重新索引的文件数。
    public private(set) var lastScanStats: (checked: Int, reindexed: Int) = (0, 0)
    private var scanning = false
    private var scanRequested = false
    /// 曲目有变化时通知（例如服务器转告客户端刷新）。
    private var onChange: (@Sendable () -> Void)?
    public func setOnChange(_ handler: (@Sendable () -> Void)?) { onChange = handler }

    /// - Parameter fileName: 索引文件名（客户端本机音乐用文件保存）。
    public init(paths: AppPaths = .shared, fileName: String = "local-library.json") {
        self.init(store: JSONLibraryStore(file: paths.config.appending(path: fileName)))
    }

    /// 指定存储方式（服务器音乐库用数据库）。
    public init(store: any MusicLibraryStore) {
        self.store = store
        if let loaded = try? store.load() {
            meta = loaded.meta
            records = loaded.records
        }
        tracks = Self.sorted(records.values.flatMap(\.tracks))
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        cachedCatalog = nil
    }

    public var folders: [Folder] { meta.folders }
    public var trackCount: Int { tracks.count }
    public var isScanning: Bool { scanning }

    public func trackCount(folderID: String) -> Int {
        records.values.filter { $0.folderID == folderID }.reduce(0) { $0 + $1.tracks.count }
    }

    // MARK: 文件夹

    public func addFolder(_ url: URL) throws {
        let bookmark = try FolderBookmark.make(url)
        guard !meta.folders.contains(where: { $0.displayPath == url.path(percentEncoded: false) }) else { return }
        meta.folders.append(Folder(id: UUID().uuidString, displayPath: url.path(percentEncoded: false), bookmark: bookmark))
        try store.save(meta: meta, upserts: [:], deletions: [])
    }

    /// 按路径添加文件夹（服务器上不经系统选择器，也不需要沙盒访问书签）。
    public func addFolder(path: String) throws {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
        guard FileAccess.isDirectory(URL(fileURLWithPath: clean)) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: clean])
        }
        guard !meta.folders.contains(where: { $0.displayPath == clean }) else { return }
        meta.folders.append(Folder(id: UUID().uuidString, displayPath: clean, bookmark: Data()))
        try store.save(meta: meta, upserts: [:], deletions: [])
    }

    public func removeFolder(id: String) throws {
        meta.folders.removeAll { $0.id == id }
        let gone = Set(records.filter { $0.value.folderID == id }.keys)
        for k in gone { records[k] = nil }
        folderStatus[id] = nil
        rebuildTracks()
        try store.save(meta: meta, upserts: [:], deletions: gone)
        if !gone.isEmpty { onChange?() }
    }

    // MARK: 扫描

    /// 扫描全部文件夹（增量：没变的文件不重读），返回歌曲总数。
    /// 正在扫描时再次调用，会在本次结束后再扫一遍（文件夹在扫描期间可能又有变化）。
    @discardableResult
    public func rescan() async throws -> Int {
        if scanning { scanRequested = true; return tracks.count }
        scanning = true
        defer { scanning = false; progress = nil }
        repeat {
            scanRequested = false
            try await scanOnce()
        } while scanRequested
        lastScan = Date()
        return tracks.count
    }

    private func scanOnce() async throws {
        lastScanStats = (0, 0)
        defer { if let p = progress { lastScanStats.checked += p.checked; lastScanStats.reindexed += p.reindexed } }
        var upserts: [String: Record] = [:]
        var deletions = Set<String>()
        for folder in meta.folders {
            guard let url = resolve(folder) else { folderStatus[folder.id] = .unavailable; continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let old = records.filter { $0.value.folderID == folder.id }
            let found = Self.listFiles(in: url)
            // 读不到文件夹，或原来有歌而现在一个文件都没有：多半是网络盘没挂载，保留原索引
            guard let found, !(found.isEmpty && !old.isEmpty) else { folderStatus[folder.id] = .unavailable; continue }
            folderStatus[folder.id] = .ok
            progress = ScanProgress(folder: folder.displayPath, checked: 0, reindexed: 0)
            var fresh: [String: Record] = [:]
            var covered = Set<String>()

            func unchanged(_ r: Record) -> Bool { !r.files.isEmpty && r.files.allSatisfy { found[$0.key] == $0.value } }
            func fingerprints(_ paths: [String]) -> [String: Fingerprint] {
                Dictionary(paths.compactMap { p in found[p].map { (p, $0) } }, uniquingKeysWith: { a, _ in a })
            }
            func reuse(_ path: String) -> Bool {
                guard let r = old[path], unchanged(r), !discNowAvailable(r.pendingDisc),
                      r.indexVersion == Self.indexVersion else { return false }
                fresh[path] = r
                covered.formUnion(r.covers)
                return true
            }

            // 先处理目录文件（CUE、CloneCD、Nero、Alcohol），它们会“包含”整轨或镜像数据文件
            for path in found.keys.sorted() where Self.descriptorExtensions.contains((path as NSString).pathExtension.lowercased()) {
                progress?.checked += 1
                if reuse(path) { continue }
                progress?.reindexed += 1
                let desc = URL(fileURLWithPath: path)
                if var image = CDImage.load(desc) {
                    let pending = await fillDiscInfo(&image)
                    let covers = Array(Set(image.tracks.map { $0.file.path(percentEncoded: false) }))
                    fresh[path] = Record(folderID: folder.id, files: fingerprints([path] + covers), covers: covers,
                                         tracks: Self.indexCDImage(image, descriptor: desc, folderID: folder.id), pendingDisc: pending)
                    covered.formUnion(covers)
                } else if desc.pathExtension.lowercased() == "cue" {
                    let cue = await Self.indexCue(desc, folderID: folder.id)
                    guard !cue.tracks.isEmpty else { continue }
                    let covers = Array(cue.files)
                    fresh[path] = Record(folderID: folder.id, files: fingerprints([path] + covers), covers: covers, tracks: cue.tracks)
                    covered.formUnion(covers)
                }
            }
            for path in found.keys.sorted() where Self.audioExtensions.contains((path as NSString).pathExtension.lowercased())
                && !covered.contains(path) {
                progress?.checked += 1
                if reuse(path) { continue }
                progress?.reindexed += 1
                let f = URL(fileURLWithPath: path)
                var list: [IndexedTrack]
                var pending: String?
                if f.pathExtension.lowercased() == "iso" {
                    if SACDImage.isSACD(f) { list = Self.indexSACD(f, folderID: folder.id) }
                    else if var image = CDImage.load(f) {
                        pending = await fillDiscInfo(&image)
                        list = Self.indexCDImage(image, descriptor: f, folderID: folder.id)
                    } else { list = await Self.indexDataDisc(f, folderID: folder.id) }
                } else {
                    list = [await Self.index(f, folderID: folder.id)]
                }
                fresh[path] = Record(folderID: folder.id, files: fingerprints([path]), covers: [], tracks: list, pendingDisc: pending)
            }
            // 比较新旧：只保存变化的条目
            for (k, r) in fresh where old[k] == nil || !unchanged(old[k]!) || old[k]!.files != r.files
                || old[k]!.pendingDisc != r.pendingDisc || old[k]!.tracks.map(\.title) != r.tracks.map(\.title) { upserts[k] = r }
            for k in old.keys where fresh[k] == nil { deletions.insert(k) }
            for k in old.keys { records[k] = nil }
            for (k, r) in fresh { records[k] = r }
            if let p = progress { lastScanStats.checked += p.checked; lastScanStats.reindexed += p.reindexed }
            progress = nil
        }
        guard !upserts.isEmpty || !deletions.isEmpty || metaChanged else { return }
        metaChanged = false
        rebuildTracks()
        try store.save(meta: meta, upserts: upserts, deletions: deletions)
        if !upserts.isEmpty || !deletions.isEmpty { onChange?() }
    }

    private func rebuildTracks() {
        tracks = Self.sorted(records.values.flatMap(\.tracks))
        byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // 曲目变了，整理后的专辑、歌手、歌曲也要重建（否则重新扫描后新加的歌要等重启才出现）
        cachedCatalog = nil
    }

    static func sorted(_ list: [IndexedTrack]) -> [IndexedTrack] {
        list.sorted { ($0.artists.first ?? "", $0.album ?? "", $0.discNumber ?? 0, $0.trackNumber ?? 0, $0.title)
            < ($1.artists.first ?? "", $1.album ?? "", $1.discNumber ?? 0, $1.trackNumber ?? 0, $1.title) }
    }

    /// 列出文件夹下所有相关文件及其指纹；文件夹不存在时返回 nil。
    nonisolated static func listFiles(in folder: URL) -> [String: Fingerprint]? {
        let wanted = audioExtensions.union(descriptorExtensions).union(["bin", "img", "mdf", "raw"])
        return FileAccess.listFiles(folder, extensions: wanted)?.mapValues {
            Fingerprint(size: $0.size, modified: $0.modified.timeIntervalSince1970)
        }
    }

    /// SACD 镜像：每个区一张专辑（多声道区的专辑名加“（多声道）”）。碟上没有文字时用文件名和“第几首”。
    static func indexSACD(_ url: URL, folderID: String) -> [IndexedTrack] {
        guard SACDImage.isSACD(url), let image = try? SACDImage(url: url) else { return [] }
        let fallback = url.deletingPathExtension().lastPathComponent
        let album = image.albumTitle ?? fallback
        let split: (String?) -> [String] = ArtistSplitter.split
        var result: [IndexedTrack] = []
        for area in image.areas {
            let name = area.kind == .multichannel ? "\(album)（多声道）" : album
            for t in area.tracks {
                var track = IndexedTrack(path: url.path(percentEncoded: false), folderID: folderID,
                                         title: t.title.flatMap { $0.isEmpty || $0.hasPrefix("Track ") ? nil : $0 } ?? "第 \(t.number) 首",
                                         artists: split(t.performer ?? image.albumArtist), album: name,
                                         durationMS: Int(t.duration * 1000), trackNumber: t.number, discNumber: nil, embeddedLyrics: nil)
                track.albumArtist = image.albumArtist
                track.sacdArea = area.kind.rawValue
                track.setFormat(.dsd(area.sampleRate))
                result.append(track)
            }
        }
        return result
    }

    /// 整张 CD 镜像：一张专辑。没有 CD-Text 时用文件名当专辑名、“第几轨”当歌名。
    static func indexCDImage(_ image: CDImage, descriptor: URL, folderID: String) -> [IndexedTrack] {
        let album = image.title ?? descriptor.deletingPathExtension().lastPathComponent
        let split: (String?) -> [String] = ArtistSplitter.split
        return image.tracks.map { t in
            var track = IndexedTrack(path: descriptor.path(percentEncoded: false), folderID: folderID,
                                     title: t.title ?? (t.number == 0 ? "隐藏音轨" : "第 \(t.number) 轨"),
                                     artists: split(t.performer ?? image.performer), album: album,
                                     durationMS: Int(t.seconds * 1000), trackNumber: t.number, discNumber: nil, embeddedLyrics: nil)
            track.albumArtist = image.performer
            track.cdTrack = t.number
            track.setFormat(.cd)
            return track
        }
    }

    /// 数据光盘镜像：把里面的音乐文件当一个文件夹收录（标签与时长从文件本身读）。
    static func indexDataDisc(_ url: URL, folderID: String) async -> [IndexedTrack] {
        guard let iso = ISO9660(url: url) else { return [] }
        let playable: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "mp4"]
        let album = iso.volumeName.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
        var result: [IndexedTrack] = []
        for f in iso.files where playable.contains((f.path as NSString).pathExtension.lowercased()) {
            let ext = (f.path as NSString).pathExtension.lowercased()
            let sliceURL = SliceAssetLoader.url(path: url.path(percentEncoded: false), offset: f.offset, length: f.size, wav: false, ext: ext)
            var track: IndexedTrack
            if let (asset, loader) = SliceAssetLoader.asset(for: sliceURL) {
                track = await indexAsset(asset, fallbackTitle: ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                         path: url.path(percentEncoded: false), folderID: folderID, ext: ext)
                _ = loader
            } else { continue }
            if track.album == nil {
                var replaced = IndexedTrack(path: track.path, folderID: folderID, title: track.title, artists: track.artists,
                                            album: album, durationMS: track.durationMS, trackNumber: track.trackNumber,
                                            discNumber: track.discNumber, embeddedLyrics: track.embeddedLyrics)
                replaced.sampleRate = track.sampleRate; replaced.bitDepth = track.bitDepth
                replaced.codec = track.codec; replaced.lossless = track.lossless
                track = replaced
            }
            track.innerPath = f.path
            result.append(track)
        }
        return result
    }

    /// CUE 分轨：每首歌成为一条虚拟曲目（同一个整轨文件中的一段）。返回曲目和被覆盖的整轨文件路径。
    static func indexCue(_ cueURL: URL, folderID: String) async -> (tracks: [IndexedTrack], files: Set<String>) {
        guard let sheet = CueSheet.load(cueURL) else { return ([], []) }
        let dir = cueURL.deletingLastPathComponent()
        var result: [IndexedTrack] = []
        var files = Set<String>()
        let byFile = Dictionary(grouping: sheet.tracks, by: \.file)
        for (name, list) in byFile {
            // CUE 里写的文件名常与实际不符（例如写 .wav 实际是 .flac），按同名换扩展名再找
            var audio = dir.appending(path: name)
            if !FileAccess.exists(audio) {
                let base = audio.deletingPathExtension()
                guard let alt = audioExtensions.map({ base.appendingPathExtension($0) })
                    .first(where: { FileAccess.exists($0) }) else { continue }
                audio = alt
            }
            guard audioExtensions.contains(audio.pathExtension.lowercased()) else { continue }
            let path = audio.path(percentEncoded: false)
            let total: Int? = switch audio.pathExtension.lowercased() {
            case "dsf", "dff": (try? DSDFile(url: audio)).map { Int($0.duration * 1000) }
            case "ape": (try? APEFile(url: audio)).map { Int($0.duration * 1000) }
            default: await { let a = FileAccess.asset(for: audio); defer { withExtendedLifetime(a.owner) {} }; return (try? await a.asset.load(.duration)).map { $0.seconds }.flatMap { $0.isFinite ? Int($0 * 1000) : nil } }()
            }
            let format = await AudioFormat.probe(audio)
            let fileTags = TagValues.of(audio)
            let sorted = list.sorted { $0.startMS < $1.startMS }
            for (i, t) in sorted.enumerated() {
                // 起点超出文件长度的音轨（CUE 与文件不匹配）跳过
                if let total, t.startMS >= total { continue }
                let end = i + 1 < sorted.count ? min(sorted[i + 1].startMS, total ?? .max) : total
                let performer = t.performer ?? sheet.performer
                let artists = ArtistSplitter.split(performer)
                var track = IndexedTrack(path: path, folderID: folderID, title: t.title ?? "音轨 \(t.number)", artists: artists,
                                         album: sheet.title, durationMS: end.map { $0 - t.startMS },
                                         trackNumber: t.number, discNumber: nil, embeddedLyrics: nil)
                track.albumArtist = sheet.performer ?? fileTags?.albumArtist
                track.artistTag = performer
                // CUE 的 REM 信息优先，其次整轨文件自带的标签
                track.year = sheet.date.flatMap { Int($0.prefix(4)) } ?? fileTags?.year
                track.discNumber = sheet.discNumber ?? fileTags?.discNumber
                track.discTotal = sheet.discTotal ?? fileTags?.discTotal
                track.musicBrainzAlbumID = fileTags?.musicBrainzAlbumID
                track.startMS = t.startMS
                track.endMS = end
                track.cueTrack = t.number
                track.setFormat(format)
                result.append(track)
            }
            files.insert(path)
        }
        return (result, files)
    }

    /// 读取文件自带标签；没有标签时用文件名作歌名，未知字段留空（SEA-04）。
    static func index(_ url: URL, folderID: String) async -> IndexedTrack {
        if ["dsf", "dff", "ape"].contains(url.pathExtension.lowercased()) { return await indexFile(url, folderID: folderID) }
        let made = FileAccess.asset(for: url)
        defer { withExtendedLifetime(made.owner) {} }
        return await indexAsset(made.asset, fallbackTitle: url.deletingPathExtension().lastPathComponent,
                                path: url.path(percentEncoded: false), folderID: folderID, ext: url.pathExtension.lowercased())
    }

    static func indexFile(_ url: URL, folderID: String) async -> IndexedTrack {
        // DSD 文件系统读不了，用自己的读取器取标签与时长
        let fallback = url.deletingPathExtension().lastPathComponent
        if ["dsf", "dff"].contains(url.pathExtension.lowercased()), let dsd = try? DSDFile(url: url) {
            var raw = dsd.rawTags
            // DFF 只有歌名与歌手
            if raw["TITLE"] == nil, let t = dsd.title { raw["TITLE"] = [t] }
            if raw["ARTIST"] == nil, let a = dsd.artist { raw["ARTIST"] = [a] }
            var track = IndexedTrack.make(path: url.path(percentEncoded: false), folderID: folderID, tags: TagValues(raw),
                                          fallbackTitle: fallback, durationMS: Int(dsd.duration * 1000))
            track.setFormat(.dsd(dsd.sampleRate))
            return track
        }
        // APE 同样由自己的解码器读取标签（APEv2）
        if url.pathExtension.lowercased() == "ape", let ape = try? APEFile(url: url) {
            var track = IndexedTrack.make(path: url.path(percentEncoded: false), folderID: folderID, tags: TagValues(ape.rawTags),
                                          fallbackTitle: fallback, durationMS: Int(ape.duration * 1000))
            track.setFormat(AudioFormat(sampleRate: ape.sampleRate, bitDepth: ape.bitsPerSample, codec: "ape", lossless: true))
            return track
        }
        let made = FileAccess.asset(for: url)
        defer { withExtendedLifetime(made.owner) {} }
        return await indexAsset(made.asset, fallbackTitle: url.deletingPathExtension().lastPathComponent,
                                path: url.path(percentEncoded: false), folderID: folderID, ext: url.pathExtension.lowercased())
    }

    static func indexAsset(_ asset: AVAsset, fallbackTitle: String, path: String, folderID: String, ext: String = "") async -> IndexedTrack {
        var (tags, lyrics) = await TagValues.asset(asset)
        // FLAC 自己读 Vorbis 注释：字段全、能拿到多值歌手（数据光盘里的 FLAC 仍用系统读的）
        if ext == "flac", !path.hasSuffix(".iso"), let own = TagValues.flac(URL(fileURLWithPath: path)) {
            tags = own
            if lyrics == nil, let l = TagValues.flacLyrics(URL(fileURLWithPath: path)) { lyrics = l }
        }
        let seconds = (try? await asset.load(.duration)).map { $0.seconds }
        var indexed = IndexedTrack.make(path: path, folderID: folderID, tags: tags, fallbackTitle: fallbackTitle,
                                        durationMS: seconds.flatMap { $0.isFinite ? Int($0 * 1000) : nil }, lyrics: lyrics)
        indexed.setFormat(await AudioFormat.read(asset, ext: ext))
        return indexed
    }

    // MARK: 查询

    public func allTracks() -> [IndexedTrack] { tracks }

    /// 全部曲目及其所在文件在索引里记录的大小与修改时间（共享文件夹建目录用，不必再查文件）。
    public func tracksWithFingerprints() -> [(track: IndexedTrack, fingerprint: (size: Int64, modified: Date)?)] {
        records.values.flatMap { r in
            r.tracks.map { t in (t, r.files[t.path].map { ($0.size, Date(timeIntervalSince1970: $0.modified)) }) }
        }
    }

    func track(path: String) -> IndexedTrack? { byID[path] }

    // MARK: 专辑与歌手

    func albums() -> [LibraryCatalog.Album] { catalog.albums }

    func album(_ id: String) -> LibraryCatalog.Album? { catalog.albumByID[id].map { catalog.albums[$0] } }

    /// 去重后的全部歌曲（多个音质版本取最好的一份）。
    func songs() -> [LibraryCatalog.Song] { catalog.songs }

    func song(trackID: String) -> LibraryCatalog.Song? { catalog.songByTrackID[trackID] }

    func artists() -> [LibraryCatalog.Artist] { catalog.artists }

    /// 歌手：编号是规整后的名字，传原名也能找到。
    func artist(_ idOrName: String) -> LibraryCatalog.Artist? {
        let c = catalog
        let i = c.artistByKey[idOrName] ?? c.artistByKey[NameNormalizer.shared.key(idOrName)]
        return i.map { c.artists[$0] }
    }

    func artistSongs(_ idOrName: String) -> [LibraryCatalog.Song] {
        guard let a = artist(idOrName) else { return [] }
        let n = NameNormalizer.shared
        return catalog.songs.filter { s in s.artists.contains { n.key($0) == a.key } || n.key(s.albumArtist) == a.key }
    }

    func artistAlbums(_ idOrName: String) -> [LibraryCatalog.Album] {
        guard let a = artist(idOrName) else { return [] }
        return a.albumIDs.compactMap(album)
    }

    /// 搜索：名字规整后比较（全半角、大小写、繁简都不影响）。
    func search(_ query: String) -> [LibraryCatalog.Song] {
        let n = NameNormalizer.shared
        let words = n.key(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return catalog.songs.filter { s in
            let text = n.key(([s.title, s.album, s.albumArtist] + s.artists).joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// 播放与读取歌词前取得文件访问权（沙盒）；调用方用完后须停止访问。
    func accessibleFolder(for track: IndexedTrack) -> URL? {
        guard let folder = meta.folders.first(where: { $0.id == track.folderID }) else { return nil }
        return resolve(folder)
    }

    private func resolve(_ folder: Folder) -> URL? {
        folder.bookmark.isEmpty ? URL(fileURLWithPath: folder.displayPath, isDirectory: true) : FolderBookmark.resolve(folder.bookmark)
    }
}

/// 音乐库索引的存储方式：客户端用一个文件，服务器用数据库（只写变化的条目）。
public protocol MusicLibraryStore: AnyObject, Sendable {
    func load() throws -> (meta: LocalMusicLibrary.Meta, records: [String: LocalMusicLibrary.Record])?
    func save(meta: LocalMusicLibrary.Meta, upserts: [String: LocalMusicLibrary.Record], deletions: Set<String>) throws
}

/// 整个索引存成一个 JSON 文件（本机音乐，数量有限）。兼容旧格式（只有文件夹与曲目列表）。
public final class JSONLibraryStore: MusicLibraryStore, @unchecked Sendable {
    struct Snapshot: Codable {
        var meta: LocalMusicLibrary.Meta
        var records: [String: LocalMusicLibrary.Record]
    }
    struct Legacy: Codable {
        var folders: [LocalMusicLibrary.Folder] = []
        var tracks: [LocalMusicLibrary.IndexedTrack] = []
    }

    let file: URL
    private var snapshot: Snapshot?
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    public func load() throws -> (meta: LocalMusicLibrary.Meta, records: [String: LocalMusicLibrary.Record])? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        if let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            lock.withLock { snapshot = s }
            return (s.meta, s.records)
        }
        // 旧格式：曲目先照常显示，指纹为空，下次扫描时重新索引
        guard let old = try? JSONDecoder().decode(Legacy.self, from: data) else { return nil }
        var meta = LocalMusicLibrary.Meta()
        meta.folders = old.folders
        let records = Dictionary(grouping: old.tracks, by: \.path).mapValues {
            LocalMusicLibrary.Record(folderID: $0[0].folderID, files: [:], covers: [], tracks: $0)
        }
        lock.withLock { snapshot = Snapshot(meta: meta, records: records) }
        return (meta, records)
    }

    public func save(meta: LocalMusicLibrary.Meta, upserts: [String: LocalMusicLibrary.Record], deletions: Set<String>) throws {
        let data = try lock.withLock { () -> Data in
            var s = snapshot ?? Snapshot(meta: meta, records: [:])
            s.meta = meta
            for (k, v) in upserts { s.records[k] = v }
            for k in deletions { s.records[k] = nil }
            snapshot = s
            return try JSONEncoder().encode(s)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// 本地音乐模块：搜索、资料库（全部本地歌曲）、歌词（同名 .lrc 或内嵌歌词）、播放（本地文件）。
public struct LocalMusicProvider: CatalogSearching, CatalogDetailReading, ArtistReading, LibraryReading, LyricsProviding, StreamResolving {
    public let library: LocalMusicLibrary

    public let descriptor: ProviderDescriptor
    var platform: PlatformID { descriptor.platform }

    /// - Parameters:
    ///   - platform: 本机为 `.local`；家庭服务器上的音乐库为 `.serverLibrary`。
    ///   - role: 来源用途；服务器音乐库为 `.musicLibrary`，客户端据此单独显示。
    public init(library: LocalMusicLibrary, platform: PlatformID = .local, displayName: String = "本地音乐",
                role: ProviderRole? = nil) {
        self.library = library
        var d = Self.descriptor(platform: platform, displayName: displayName)
        d.role = role
        descriptor = d
    }

    static func descriptor(platform: PlatformID, displayName: String) -> ProviderDescriptor { ProviderDescriptor(
        platform: platform, displayName: displayName, moduleVersion: "1.0.0",
        integration: .officialSDK, accountRequirement: .none,
        capabilities: [
            .init(.search(.track), .implemented),
            .init(.detail(.track), .implemented),
            .init(.libraryRead(.savedTracks), .implemented),
            .init(.libraryRead(.savedAlbums), .implemented),
            .init(.libraryRead(.followedArtists), .implemented),
            .init(.detail(.album), .implemented),
            .init(.detail(.artist), .implemented),
            .init(.lyrics(.plainText), .implemented),
            .init(.lyrics(.lineSynced), .implemented),
            .init(.resolveStream, .implemented),
            .init(.fullPlayback, .implemented),
            .init(.pause, .implemented),
            .init(.seek, .implemented),
            .init(.skip, .implemented),
        ]) }

    public func health() async -> ProviderHealth { .healthy }

    public var supportedSearchKinds: Set<SearchKind> { [.track] }
    public var readableSections: Set<LibrarySection> { [.savedTracks, .savedAlbums, .followedArtists] }
    public var lyricsFeatures: Set<LyricsFeature> { [.plainText, .lineSynced] }
    public var streamQualityLevels: [StreamQualityLevel] { [] }

    public func search(_ query: String, kind: SearchKind, cursor: PageCursor?, context: RequestContext) async throws -> Page<SearchItem> {
        let found = await library.search(query)
        return Page(items: found.map { .track(track($0)) }, nextCursor: nil, reportedTotal: found.count)
    }

    public func library(_ section: LibrarySection, cursor: PageCursor?, context: RequestContext) async throws -> Page<SearchItem> {
        switch section {
        case .savedAlbums:
            let albums = await library.albums()
            return Page(items: albums.map { .album(album($0)) }, nextCursor: nil, reportedTotal: albums.count)
        case .followedArtists:
            let artists = await library.artists()
            return Page(items: artists.map { .artist(PlatformArtist(ref: PlatformResourceRef(platform: platform, kind: .artist, platformID: $0.key), name: $0.name)) },
                        nextCursor: nil, reportedTotal: artists.count)
        default:
            let all = await library.songs()
            return Page(items: all.map { .track(track($0)) }, nextCursor: nil, reportedTotal: all.count)
        }
    }

    public func artistTracks(_ ref: PlatformResourceRef, cursor: PageCursor?, context: RequestContext) async throws -> Page<PlatformTrack> {
        let list = await library.artistSongs(ref.platformID)
        return Page(items: list.map(track), nextCursor: nil, reportedTotal: list.count)
    }

    public func artistAlbums(_ ref: PlatformResourceRef, cursor: PageCursor?, context: RequestContext) async throws -> Page<PlatformAlbum> {
        let albums = await library.artistAlbums(ref.platformID)
        return Page(items: albums.map(album), nextCursor: nil, reportedTotal: albums.count)
    }

    public func track(_ ref: PlatformResourceRef, context: RequestContext) async throws -> PlatformTrack {
        if let s = await library.song(trackID: ref.platformID), s.track.id == ref.platformID { return track(s) }
        guard let t = await library.track(path: ref.platformID) else {
            throw MusicError(.resourceRemoved, platform: platform, userMessage: "本地文件已不存在，请重新扫描")
        }
        return track(t)
    }

    public func albumTracks(_ ref: PlatformResourceRef, cursor: PageCursor?, context: RequestContext) async throws -> Page<PlatformTrack> {
        let list = await library.album(ref.platformID)?.songs ?? []
        return Page(items: list.map(track), nextCursor: nil, reportedTotal: list.count)
    }

    public func playlistTracks(_ ref: PlatformResourceRef, cursor: PageCursor?, context: RequestContext) async throws -> Page<PlatformTrack> {
        Page(items: [], nextCursor: nil)
    }

    public func lyrics(for query: LyricsQuery, context: RequestContext) async throws -> LyricsResult {
        guard let ref = query.platformRef, ref.platform == platform, let t = await library.track(path: ref.platformID) else {
            return LyricsResult(status: .uncertainMatch, tracks: [], matchedRef: nil)
        }
        let folder = await library.accessibleFolder(for: t)
        let accessing = folder?.startAccessingSecurityScopedResource() ?? false
        defer { if accessing { folder?.stopAccessingSecurityScopedResource() } }
        guard t.cueTrack == nil else { return LyricsResult(status: .noResult, tracks: [], matchedRef: ref) }
        let lrcURL = URL(filePath: t.path).deletingPathExtension().appendingPathExtension("lrc")
        let text = FileAccess.data(lrcURL).flatMap { String(data: $0, encoding: .utf8) } ?? t.embeddedLyrics
        guard let text, !text.isEmpty else { return LyricsResult(status: .noResult, tracks: [], matchedRef: ref) }
        let parsed = LRCParser.parse(text)
        let track = LyricsTrack(role: .original, language: nil, lines: parsed.lines, source: .local,
                                sourceFormat: parsed.isSynced ? .lrc : .plain)
        return LyricsResult(status: .available, tracks: [track], matchedRef: ref)
    }

    public func resolveStream(_ ref: PlatformResourceRef, preferredLevel: String?, context: RequestContext) async throws -> ResolvedStream {
        guard let t = await library.track(path: ref.platformID) else {
            throw MusicError(.resourceRemoved, platform: platform, userMessage: "本地文件已不存在，请重新扫描")
        }
        // 沙盒下开始访问文件夹；本软件运行期间保持访问（文件夹数量有限）
        _ = await library.accessibleFolder(for: t)?.startAccessingSecurityScopedResource()
        let url = URL(filePath: t.path)
        guard FileAccess.exists(url) else {
            throw MusicError(.resourceRemoved, platform: platform, userMessage: "无法读取本地文件：\(url.lastPathComponent)")
        }
        let ext = url.pathExtension.lowercased()
        if let n = t.cdTrack {
            guard let image = CDImage.load(url), let ct = image.tracks.first(where: { $0.number == n }) else {
                throw MusicError(.resourceRemoved, platform: platform, userMessage: "光盘镜像读不出这一轨，请重新扫描")
            }
            return ResolvedStream(url: SliceAssetLoader.url(path: ct.file.path(percentEncoded: false), offset: ct.offset, length: ct.length,
                                                            wav: true, bigEndian: ct.bigEndian, stride: ct.sectorStride),
                                  quality: AudioQuality(platformLabel: "CD 镜像", platformQualityKey: "cd", codec: "wav",
                                                        sampleRateHz: 44100, bitDepth: 16, isLosslessClaimedByPlatform: true,
                                                        tier: .lossless, multichannel: false),
                                  duration: .milliseconds(Int(ct.seconds * 1000)), previewRange: nil)
        }
        if let inner = t.innerPath {
            guard let iso = ISO9660(url: url), let f = iso.files.first(where: { $0.path == inner }) else {
                throw MusicError(.resourceRemoved, platform: platform, userMessage: "光盘镜像里找不到这个文件，请重新扫描")
            }
            let innerExt = (inner as NSString).pathExtension.lowercased()
            return ResolvedStream(url: SliceAssetLoader.url(path: url.path(percentEncoded: false), offset: f.offset, length: f.size,
                                                            wav: false, ext: innerExt),
                                  quality: AudioQuality(platformLabel: "光盘镜像", platformQualityKey: "file", codec: innerExt,
                                                        sampleRateHz: t.sampleRate, bitDepth: t.bitDepth,
                                                        isLosslessClaimedByPlatform: t.lossless, tier: t.qualityTier),
                                  duration: t.durationMS.map { .milliseconds($0) }, previewRange: nil)
        }
        if let area = t.sacdArea, let n = t.trackNumber {
            let rate = (try? SACDImage(url: url))?.areas.first { $0.kind.rawValue == area }?.sampleRate ?? 2_822_400
            return ResolvedStream(url: URL(string: url.absoluteString + "#sacd=\(area),\(n)")!,
                                  quality: AudioQuality(platformLabel: "SACD 镜像", platformQualityKey: "sacd", codec: "dsd",
                                                        sampleRateHz: rate, bitDepth: 1, isLosslessClaimedByPlatform: true,
                                                        tier: .dsd, multichannel: area == 6),
                                  duration: t.durationMS.map { .milliseconds($0) }, previewRange: nil)
        }
        if ["dsf", "dff"].contains(ext), let dsd = try? DSDFile(url: url) {
            return ResolvedStream(url: url,
                                  quality: AudioQuality(platformLabel: "本地文件", platformQualityKey: "file", codec: ext,
                                                        sampleRateHz: dsd.sampleRate, bitDepth: 1, isLosslessClaimedByPlatform: true,
                                                        tier: .dsd, multichannel: dsd.channels > 2),
                                  duration: t.durationMS.map { .milliseconds($0) }, previewRange: nil,
                                  clipRange: t.startMS.map { start in Duration.milliseconds(start) ..< Duration.milliseconds(t.endMS ?? Int.max / 2) })
        }
        if ext == "ape" {
            guard let ape = try? APEFile(url: url) else {
                throw MusicError(.resourceRemoved, platform: platform, userMessage: "这个 APE 文件读不了：\(url.lastPathComponent)")
            }
            return ResolvedStream(url: SliceAssetLoader.apeURL(path: t.path, file: ape),
                                  quality: AudioQuality(platformLabel: "本地文件", platformQualityKey: "file", codec: "ape",
                                                        sampleRateHz: ape.sampleRate, bitDepth: ape.bitsPerSample, isLosslessClaimedByPlatform: true,
                                                        tier: QualityTier.classify(codec: "ape", sampleRateHz: ape.sampleRate, bitDepth: ape.bitsPerSample, lossless: true)),
                                  duration: t.durationMS.map { .milliseconds($0) }, previewRange: nil,
                                  clipRange: t.startMS.map { start in Duration.milliseconds(start) ..< Duration.milliseconds(t.endMS ?? Int.max / 2) })
        }
        return ResolvedStream(url: url,
                              quality: AudioQuality(platformLabel: "本地文件", platformQualityKey: "file", codec: ext,
                                                    sampleRateHz: t.sampleRate, bitDepth: t.bitDepth,
                                                    isLosslessClaimedByPlatform: t.lossless,
                                                    estimatedSizeBytes: FileAccess.size(url).map { Int64($0) },
                                                    tier: t.qualityTier),
                              duration: t.durationMS.map { .milliseconds($0) }, previewRange: nil,
                              clipRange: t.startMS.map { start in Duration.milliseconds(start) ..< Duration.milliseconds(t.endMS ?? Int.max / 2) })
    }

    func album(_ a: LibraryCatalog.Album) -> PlatformAlbum {
        var album = PlatformAlbum(ref: PlatformResourceRef(platform: platform, kind: .album, platformID: a.id),
                                  title: a.displayTitle, artists: [a.artist], trackCount: a.songs.count)
        album.editionNote = a.versionLabel
        return album
    }

    /// 整理后的歌：歌名、歌手、专辑、碟号用整理结果，播放的是其中最好的一份。
    func track(_ s: LibraryCatalog.Song) -> PlatformTrack {
        PlatformTrack(ref: PlatformResourceRef(platform: platform, kind: .track, platformID: s.track.id),
                      metadata: TrackMetadata(title: s.title, artists: s.artists, album: s.album,
                                              duration: s.track.durationMS.map { .milliseconds($0) },
                                              discNumber: s.disc, trackNumber: s.number,
                                              originalURL: URL(filePath: s.track.path)))
    }

    func track(_ t: LocalMusicLibrary.IndexedTrack) -> PlatformTrack {
        PlatformTrack(ref: PlatformResourceRef(platform: platform, kind: .track, platformID: t.id),
                      metadata: TrackMetadata(title: t.title, artists: t.artists, album: t.album,
                                              duration: t.durationMS.map { .milliseconds($0) },
                                              discNumber: t.discNumber, trackNumber: t.trackNumber,
                                              originalURL: URL(filePath: t.path)))
    }
}
