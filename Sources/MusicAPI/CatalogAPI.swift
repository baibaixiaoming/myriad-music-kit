import Foundation

/// 唱片资料查询（服务器上的唱片资料大库，MusicBrainz 与 Discogs 合并而成）。
/// 用途：整理唱片文件夹的工具（例如给文件改名、写入内嵌信息）先“认唱片”，再取这张唱片的完整资料；
/// 本软件以后按作曲家、作品、演奏者、唱片公司浏览也用这套查询。
/// 只查资料，不传音频；改名、写信息由调用方在自己的电脑上完成。
extension API.Path {
    public static let catalogInfo = "/v1/catalog/info"          // GET → CatalogInfo
    public static let catalogMatch = "/v1/catalog/match"        // POST CatalogMatchRequest → CatalogMatchResponse
    public static let catalogRelease = "/v1/catalog/release"    // GET id → CatalogRelease（查不到为 404）
}

extension API {
    /// 资料库状态。没配置（服务器管理员还没选资料库文件）时 configured 为 false，其余接口返回 502。
    public struct CatalogInfo: Codable, Sendable, Hashable {
        public var configured: Bool
        /// 两个来源各是哪一期、何时建的、数据许可（资料库 meta 表原样）。
        public var meta: [String: String]
        public init(configured: Bool, meta: [String: String] = [:]) { self.configured = configured; self.meta = meta }
    }

    /// 一轨的已知信息（从文件里读到的），都可以不填。
    public struct CatalogTrackHint: Codable, Sendable, Hashable {
        public var title: String?
        /// 时长（毫秒）。认唱片时最有用：整张唱片各轨时长对得上，基本就是这一版。
        public var lengthMs: Int?
        public init(title: String? = nil, lengthMs: Int? = nil) { self.title = title; self.lengthMs = lengthMs }
    }

    /// 认唱片：把一张唱片已知的信息发给服务器，有多少给多少。
    /// 至少要有条码、唱片编号、专辑名之一，服务器才能找到候选；曲目时长用来判断是哪个版本。
    public struct CatalogMatchRequest: Codable, Sendable, Hashable {
        public var barcode: String?
        /// 唱片公司名与唱片编号（目录号），如 Deutsche Grammophon、415 276-2。
        public var label: String?
        public var catalogNumber: String?
        public var title: String?
        public var artist: String?
        /// 每张碟的曲目（按碟、按曲目顺序）。只有一张碟时也放在数组里。
        public var discs: [[CatalogTrackHint]]?
        /// 最多返回几个候选（默认 10，最多 50）。
        public var limit: Int?
        public init(barcode: String? = nil, label: String? = nil, catalogNumber: String? = nil, title: String? = nil,
                    artist: String? = nil, discs: [[CatalogTrackHint]]? = nil, limit: Int? = nil) {
            self.barcode = barcode; self.label = label; self.catalogNumber = catalogNumber; self.title = title
            self.artist = artist; self.discs = discs; self.limit = limit
        }
    }

    public struct CatalogMatchResponse: Codable, Sendable, Hashable {
        /// 从最像到最不像。
        public var candidates: [CatalogCandidate]
        public init(candidates: [CatalogCandidate]) { self.candidates = candidates }
    }

    public struct CatalogCandidate: Codable, Sendable, Hashable {
        /// 资料库里的唱片编号，用来取完整资料。
        public var releaseID: Int64
        public var title: String
        public var artist: String?
        public var date: String?
        public var country: String?
        public var barcode: String?
        public var labels: [CatalogLabel]
        /// 每张碟的曲目数。
        public var trackCounts: [Int]
        /// 吻合程度，0 到 1。
        public var score: Double
        /// 判断依据，例如“条码一致”“12 轨中 12 轨时长相差不到 3 秒”。
        public var reasons: [String]
        public init(releaseID: Int64, title: String, artist: String?, date: String?, country: String?, barcode: String?,
                    labels: [CatalogLabel], trackCounts: [Int], score: Double, reasons: [String]) {
            self.releaseID = releaseID; self.title = title; self.artist = artist; self.date = date; self.country = country
            self.barcode = barcode; self.labels = labels; self.trackCounts = trackCounts; self.score = score; self.reasons = reasons
        }
    }

    public struct CatalogLabel: Codable, Sendable, Hashable {
        public var labelID: Int64?
        public var name: String?
        public var catalogNumber: String?
        public init(labelID: Int64?, name: String?, catalogNumber: String?) {
            self.labelID = labelID; self.name = name; self.catalogNumber = catalogNumber
        }
    }

    /// 一个人或团体在资料里的署名。
    public struct CatalogCredit: Codable, Sendable, Hashable {
        public var artistID: Int64?
        /// 资料里的原写法。
        public var name: String
        /// 中文名（账户的曲名语言为中文、且有核实过的译名时才有）。
        public var localizedName: String?
        /// 分工，原样保留两个来源的写法：conductor、instrument、composer（MusicBrainz）；Conductor、Violin、Orchestra（Discogs）……
        public var role: String?
        /// 具体乐器或声部，如 violin、cello、soprano。
        public var attributes: String?
        /// Discogs 写的适用曲目（如 “1-3, 5”）；空表示整张或这一轨。
        public var tracks: String?
        /// 来源：MusicBrainz、Discogs。
        public var source: String?
        public init(artistID: Int64?, name: String, localizedName: String?, role: String?, attributes: String?, tracks: String?, source: String?) {
            self.artistID = artistID; self.name = name; self.localizedName = localizedName; self.role = role
            self.attributes = attributes; self.tracks = tracks; self.source = source
        }
    }

    /// 作品（古典唱片里一轨通常是某部作品的一个乐章）。
    public struct CatalogWork: Codable, Sendable, Hashable {
        public var workID: Int64
        public var title: String
        public var localizedTitle: String?
        /// 作品目录号（统一写法），如 “BWV 1007”“K 525”“OP 67”。
        public var catalogNumbers: [String]
        public var composers: [CatalogCredit]
        /// 所属的上一级作品（乐章 → 整部作品），以及这是第几部分。
        public var parent: CatalogWorkRef?
        public init(workID: Int64, title: String, localizedTitle: String?, catalogNumbers: [String], composers: [CatalogCredit], parent: CatalogWorkRef?) {
            self.workID = workID; self.title = title; self.localizedTitle = localizedTitle; self.catalogNumbers = catalogNumbers
            self.composers = composers; self.parent = parent
        }
    }

    public struct CatalogWorkRef: Codable, Sendable, Hashable {
        public var workID: Int64
        public var title: String
        public var localizedTitle: String?
        public var position: Int?
        public init(workID: Int64, title: String, localizedTitle: String?, position: Int?) {
            self.workID = workID; self.title = title; self.localizedTitle = localizedTitle; self.position = position
        }
    }

    public struct CatalogTrack: Codable, Sendable, Hashable {
        public var trackID: Int64
        /// 曲目号（原样，可能是 “1”“A1”）。
        public var position: String?
        public var title: String
        public var localizedTitle: String?
        public var lengthMs: Int?
        /// 这一轨的署名（整句，如 “Beethoven; Mutter, Ma, Karajan”）。
        public var artist: String?
        public var recordingID: Int64?
        /// 演的是哪部（哪些）作品。
        public var works: [CatalogWork]
        /// 这一轨的参与人员（录音上的与曲目上的）。
        public var credits: [CatalogCredit]
        public init(trackID: Int64, position: String?, title: String, localizedTitle: String?, lengthMs: Int?, artist: String?,
                    recordingID: Int64?, works: [CatalogWork], credits: [CatalogCredit]) {
            self.trackID = trackID; self.position = position; self.title = title; self.localizedTitle = localizedTitle
            self.lengthMs = lengthMs; self.artist = artist; self.recordingID = recordingID; self.works = works; self.credits = credits
        }
    }

    public struct CatalogDisc: Codable, Sendable, Hashable {
        public var position: Int
        /// 介质：CD、SACD、Vinyl……
        public var format: String?
        public var title: String?
        public var tracks: [CatalogTrack]
        public init(position: Int, format: String?, title: String?, tracks: [CatalogTrack]) {
            self.position = position; self.format = format; self.title = title; self.tracks = tracks
        }
    }

    /// 一张唱片的完整资料。
    public struct CatalogRelease: Codable, Sendable, Hashable {
        public var releaseID: Int64
        /// 同一张专辑的各个版本共用的专辑编号。
        public var albumID: Int64?
        public var title: String
        public var localizedTitle: String?
        public var artist: String?
        public var date: String?
        public var country: String?
        public var barcode: String?
        public var status: String?
        public var notes: String?
        public var labels: [CatalogLabel]
        public var genres: [String]
        /// 唱片级的参与人员（Discogs 的分工多写在这里，tracks 字段注明适用曲目）。
        public var credits: [CatalogCredit]
        public var discs: [CatalogDisc]
        /// 两个来源的原始编号：MusicBrainz 标准编号、Discogs 编号。
        public var musicBrainzID: String?
        public var discogsID: Int64?
        public init(releaseID: Int64, albumID: Int64?, title: String, localizedTitle: String?, artist: String?, date: String?,
                    country: String?, barcode: String?, status: String?, notes: String?, labels: [CatalogLabel], genres: [String],
                    credits: [CatalogCredit], discs: [CatalogDisc], musicBrainzID: String?, discogsID: Int64?) {
            self.releaseID = releaseID; self.albumID = albumID; self.title = title; self.localizedTitle = localizedTitle
            self.artist = artist; self.date = date; self.country = country; self.barcode = barcode; self.status = status
            self.notes = notes; self.labels = labels; self.genres = genres; self.credits = credits; self.discs = discs
            self.musicBrainzID = musicBrainzID; self.discogsID = discogsID
        }
    }
}
