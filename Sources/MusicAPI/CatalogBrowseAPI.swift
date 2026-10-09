import Foundation
import ProviderKit

/// 逐层浏览与简介（功能名 `catalogBrowse`）：按作曲家、艺人、作品、录音（演绎）、专辑（发行）、唱片公司浏览服务器上的唱片资料。
/// 定稿见 docs/设计/逐层浏览/协议定稿.md，说明见 docs/protocol.md“逐层浏览”一节。
///
/// 约定：
/// - 只新增，不改旧接口；协议版本不变。
/// - 页面、标签、分区、排序、筛选全由服务器下发，客户端不写死领域词。
/// - 对象类型、显示方式等是开放取值（字符串包装），遇到不认识的值照样解码，按通用对象 / 普通行显示。
/// - 名称：`title` 原名，`localizedTitle` 中文名（只在账户曲名语言为中文且有中文名时给）；客户端显示 `localizedTitle ?? title`。
///   `subtitle`、`line`、`countText` 等说明文字由服务器拼好，客户端原样显示。
/// - “版本”（versions）只指同一专辑的其他发行；“演绎”（performance，界面叫“录音”）只指不同的演奏录音，两者不混用。
/// - 编号一律是不透明字符串。可播放内容用现有 `PlatformTrack` / `PlatformAlbum`，来源编号是服务器音乐库的槽位号。
extension API.Path {
    public static let browseDomains = "/v1/catalog/browse/domains"        // GET → BrowseDomains
    public static let browsePage = "/v1/catalog/browse/page"              // GET kind, id, domain → BrowsePage
    public static let browseList = "/v1/catalog/browse/list"              // GET kind, id, section, … → BrowseListPage
    public static let browseArticle = "/v1/catalog/browse/article"        // GET kind, id → BrowseArticle
    public static let browseSearch = "/v1/catalog/browse/search"          // GET q, … → BrowseSearchResult
    public static let browseSearchList = "/v1/catalog/browse/search/list" // GET q, group, … → BrowseListPage
    public static let browseTracks = "/v1/catalog/browse/tracks"          // GET kind, id, … → BrowseTracks
    public static let browseForLibrary = "/v1/catalog/browse/for-library" // GET platform, kind, id → BrowseLibraryLinks
}

// MARK: - 领域清单

extension API {
    public struct BrowseDomains: Codable, Sendable, Hashable {
        /// 可浏览的领域，按显示顺序。第一版只有古典。
        public var domains: [BrowseDomain]
        /// 资料期次，客户端不解析；与已存页面不同时丢掉旧页面与旧游标。
        public var dataVersion: String
        public init(domains: [BrowseDomain], dataVersion: String) {
            self.domains = domains; self.dataVersion = dataVersion
        }
    }

    public struct BrowseDomain: Codable, Sendable, Hashable {
        /// 领域编号，如 "classical"。也是领域首页的对象编号（kind=domain）。
        public var id: String
        /// 显示名，如“古典音乐”。
        public var title: String
        /// 图标的系统符号名，可不给；客户端没有这个符号时用默认图标。
        public var symbol: String?
        /// “我的资料库”里按这个领域整理的列表（服务器音乐库页的“作曲家”“作品”标签用），默认按名称排序。
        /// 音乐库对照还没有结果时为空数组。
        public var libraryLists: [BrowseListSpec]
        public init(id: String, title: String, symbol: String? = nil, libraryLists: [BrowseListSpec] = []) {
            self.id = id; self.title = title; self.symbol = symbol; self.libraryLists = libraryLists
        }
    }
}

// MARK: - 对象页

extension API {
    /// 对象类型。字符串包装，客户端遇到不认识的值照样解码，当通用对象显示。
    public struct BrowseKind: RawRepresentable, Codable, Sendable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// 领域首页
        public static let domain = BrowseKind(rawValue: "domain")
        /// 人物与团体：作曲家、指挥、乐团、独奏、歌唱家、合唱团
        public static let artist = BrowseKind(rawValue: "artist")
        /// 作品（含乐章，乐章也用这个类型）
        public static let work = BrowseKind(rawValue: "work")
        /// 演绎：同一批演奏者对同一作品的一次录音（界面叫“录音”）
        public static let performance = BrowseKind(rawValue: "performance")
        /// 一张具体发行（界面叫“专辑”）
        public static let release = BrowseKind(rawValue: "release")
        /// 唱片公司
        public static let label = BrowseKind(rawValue: "label")
        /// 发行上的一轨（只出现在专辑页的曲目列表里）
        public static let track = BrowseKind(rawValue: "track")
    }

    /// 对一个资料对象的引用。
    public struct BrowseRef: Codable, Sendable, Hashable {
        public var kind: BrowseKind
        /// 不透明编号（资料对象为大库编号的十进制写法）。
        public var id: String
        public init(kind: BrowseKind, id: String) { self.kind = kind; self.id = id }
    }

    /// 点一行（或一个链接）去哪里。
    public struct BrowseTarget: Codable, Sendable, Hashable {
        public var ref: BrowseRef
        /// 打开后焦点停在哪个分组（对应 BrowseGroup.id）。不给时停在第一行。
        public var focusGroup: String?
        /// 打开后先切到哪个标签（BrowseTab.id）。不给时用默认标签。
        public var tab: String?
        public init(ref: BrowseRef, focusGroup: String? = nil, tab: String? = nil) {
            self.ref = ref; self.focusGroup = focusGroup; self.tab = tab
        }
    }

    /// 一个对象页。
    public struct BrowsePage: Codable, Sendable, Hashable {
        /// 实际对象（旧编号已转成新编号），客户端以它为准。
        public var ref: BrowseRef
        public var header: BrowseHeader
        /// 简介摘要；没有简介时不出现。
        public var summary: BrowseSummary?
        /// 有没有可展开的“简介”页内容（全文、其他章节或关键资料）。为真时客户端可取 article。
        public var hasArticle: Bool
        /// 主按钮：有“已有”内容可播时才出现。
        public var play: BrowsePlay?
        /// “前往”菜单的去向，能对上的才列，按显示顺序。
        public var links: [BrowseLink]
        /// 页面顶部的标签，按显示顺序；只有一个标签时客户端可以不显示标签控件。
        public var tabs: [BrowseTab]
        /// “概览”标签的分段（tabs 里有 kind == "overview" 的标签时才有内容）。
        public var sections: [BrowseSection]
        /// 专辑页：服务器音乐库里对上这张发行的专辑（可能不止一份）。其他页面不出现。
        public var libraryCopies: [BrowseLibraryCopy]?
        public var dataVersion: String
        public init(ref: BrowseRef, header: BrowseHeader, summary: BrowseSummary? = nil, hasArticle: Bool = false,
                    play: BrowsePlay? = nil, links: [BrowseLink] = [], tabs: [BrowseTab] = [], sections: [BrowseSection] = [],
                    libraryCopies: [BrowseLibraryCopy]? = nil, dataVersion: String) {
            self.ref = ref; self.header = header; self.summary = summary; self.hasArticle = hasArticle
            self.play = play; self.links = links; self.tabs = tabs; self.sections = sections
            self.libraryCopies = libraryCopies; self.dataVersion = dataVersion
        }
    }

    public struct BrowseHeader: Codable, Sendable, Hashable {
        /// 原名。
        public var title: String
        /// 中文名（曲名语言为中文且有中文名时才有）。
        public var localizedTitle: String?
        /// 一行关键资料，服务器拼好的短句，如“1770–1827，德国，作曲家”。客户端与名称合成一个读屏元素。
        public var line: String?
        /// 对象的类别名，如“作曲家”“作品”“专辑”“唱片公司”。
        public var kindTitle: String?
        /// 整个对象是否“已有”。只在为真时出现。
        public var owned: Bool?
        /// 封面或头像图片地址（经 /v1/artwork 转发）。
        public var artworkURL: URL?
        public init(title: String, localizedTitle: String? = nil, line: String? = nil, kindTitle: String? = nil,
                    owned: Bool? = nil, artworkURL: URL? = nil) {
            self.title = title; self.localizedTitle = localizedTitle; self.line = line; self.kindTitle = kindTitle
            self.owned = owned; self.artworkURL = artworkURL
        }
    }

    /// 简介摘要（概览里那一行）。
    public struct BrowseSummary: Codable, Sendable, Hashable {
        /// 摘要正文：导言开头的整句，不截断句子。
        public var text: String
        /// 正文语言（BCP 47，如 "zh-Hans"、"en"）。客户端据此给文字设语言。
        public var language: String
        public var attribution: BrowseAttribution
        public init(text: String, language: String, attribution: BrowseAttribution) {
            self.text = text; self.language = language; self.attribution = attribution
        }
    }

    /// 出处与许可。全部文字由服务器给，客户端原样显示，不写死来源名；显示简介处必须显示出处。
    public struct BrowseAttribution: Codable, Sendable, Hashable {
        /// 来源短名。摘要后面读出的就是它。
        public var source: String
        /// 完整出处句（来源、条目名、许可）。简介页显示。
        public var line: String
        /// 原文链接（“打开原文”）。
        public var url: URL?
        /// 原条目标题。
        public var articleTitle: String?
        /// 许可名称与链接，如“CC BY-SA 4.0”。
        public var license: String?
        public var licenseURL: URL?
        /// 资料取自哪一期（如快照日期），可不给。
        public var retrieved: String?
        public init(source: String, line: String, url: URL? = nil, articleTitle: String? = nil, license: String? = nil,
                    licenseURL: URL? = nil, retrieved: String? = nil) {
            self.source = source; self.line = line; self.url = url; self.articleTitle = articleTitle
            self.license = license; self.licenseURL = licenseURL; self.retrieved = retrieved
        }
    }

    /// 主按钮。
    public struct BrowsePlay: Codable, Sendable, Hashable {
        /// "play"（作品、录音、专辑）或 "shuffle"（作曲家、艺人、唱片公司）。
        public var style: String
        /// 资料库里可播的曲目数。
        public var trackCount: Int
        public init(style: String, trackCount: Int) { self.style = style; self.trackCount = trackCount }
    }

    /// “前往”的一项。
    public struct BrowseLink: Codable, Sendable, Hashable {
        /// 关系名，如“作曲家”“作品”“指挥”“乐团”“唱片公司”。
        public var title: String
        public var item: BrowseItem
        public init(title: String, item: BrowseItem) { self.title = title; self.item = item }
    }

    public struct BrowseTab: Codable, Sendable, Hashable {
        /// 标签编号，如 "overview"、"works"、"albums"、"performances"、"tracks"、"credits"、"versions"。
        public var id: String
        /// 显示名。
        public var title: String
        /// "overview"（内容是页面的 sections）或 "list"（内容是一个分页列表）。不认识的值当 list。
        public var kind: String
        public var isDefault: Bool
        /// kind 为 list 时：取列表用的说明。
        public var list: BrowseListSpec?
        /// 默认标签是列表时，第一页随页面一起给。
        public var firstPage: BrowseListPage?
        public init(id: String, title: String, kind: String, isDefault: Bool = false, list: BrowseListSpec? = nil,
                    firstPage: BrowseListPage? = nil) {
            self.id = id; self.title = title; self.kind = kind; self.isDefault = isDefault
            self.list = list; self.firstPage = firstPage
        }
    }

    /// 概览里的一段。
    public struct BrowseSection: Codable, Sendable, Hashable {
        /// 分区编号，同时是取完整列表时的 section 参数。
        public var id: String
        /// 段标题。
        public var title: String
        /// 数量文字，服务器拼好，如“312部”。
        public var countText: String?
        /// 总数（数字），可不给。
        public var total: Int?
        public var display: BrowseDisplay
        /// 这一段显示的前几项。
        public var items: [BrowseItem]
        /// 段标题激活时切到哪个标签（与某个 BrowseTab.id 相同）。
        public var tab: String?
        /// 没有对应标签但还有更多时：推入完整列表页用的说明。tab 与 list 都没有表示这一段已经全部列出。
        public var list: BrowseListSpec?
        /// 这一段读取失败或超时时的一句说明；此时 items 为空，页面其余部分照常。
        public var message: String?
        public init(id: String, title: String, countText: String? = nil, total: Int? = nil, display: BrowseDisplay = .list,
                    items: [BrowseItem] = [], tab: String? = nil, list: BrowseListSpec? = nil, message: String? = nil) {
            self.id = id; self.title = title; self.countText = countText; self.total = total; self.display = display
            self.items = items; self.tab = tab; self.list = list; self.message = message
        }
    }

    /// 显示方式提示：客户端据此排版，不按对象类型写死。字符串包装，不认识的值当 list。
    public struct BrowseDisplay: RawRepresentable, Codable, Sendable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        /// 普通行：名称＋一行说明
        public static let list = BrowseDisplay(rawValue: "list")
        /// 封面类（专辑）
        public static let cards = BrowseDisplay(rawValue: "cards")
        /// 曲目行：带序号、时长，按 groupPath 分组
        public static let tracks = BrowseDisplay(rawValue: "tracks")
    }

    /// 列表里的一行（也用于页头链接、搜索结果）。
    public struct BrowseItem: Codable, Sendable, Hashable {
        public var ref: BrowseRef
        /// 原名。
        public var title: String
        /// 中文名（规则同页头）。
        public var localizedTitle: String?
        /// 服务器拼好的一行短说明，名字已按曲名语言选好。
        public var subtitle: String?
        /// “已有”。只在为真时出现。
        public var owned: Bool?
        /// 已有的数量，可不给。
        public var ownedCount: Int?
        /// 演绎行：资料显示这个录音不完整（缺乐章、节选）。只在为真时出现。
        public var incomplete: Bool?
        /// 作品行：与原作的关系（"arrangement"、"orchestration"、"transcription"、"revision"、"excerpt"）。显示文字在 subtitle 里。
        public var relation: String?
        /// 年份（与当前排序一致），可不给。
        public var year: Int?
        /// 时长（毫秒），曲目与乐章行。
        public var durationMs: Int?
        /// 曲目与乐章行的序号文字，如“1”“A1”“第二乐章”。
        public var position: String?
        /// 所在分组（外层在前）。连续几行分组相同时客户端只画一次分组标题。
        public var groupPath: [BrowseGroup]?
        /// 点这一行去哪里。不给表示这一行不是按钮。
        public var target: BrowseTarget?
        /// 已有的曲目行与乐章行：服务器音乐库里对应的曲目。
        public var libraryTrack: PlatformTrack?
        /// 封面地址（经 /v1/artwork 转发）。
        public var artworkURL: URL?
        /// 搜索结果：命中的是哪个写法（只在与 title、localizedTitle 都不同时给）。
        public var matched: String?
        public init(ref: BrowseRef, title: String, localizedTitle: String? = nil, subtitle: String? = nil, owned: Bool? = nil,
                    ownedCount: Int? = nil, incomplete: Bool? = nil, relation: String? = nil, year: Int? = nil,
                    durationMs: Int? = nil, position: String? = nil, groupPath: [BrowseGroup]? = nil,
                    target: BrowseTarget? = nil, libraryTrack: PlatformTrack? = nil, artworkURL: URL? = nil,
                    matched: String? = nil) {
            self.ref = ref; self.title = title; self.localizedTitle = localizedTitle; self.subtitle = subtitle
            self.owned = owned; self.ownedCount = ownedCount; self.incomplete = incomplete; self.relation = relation
            self.year = year; self.durationMs = durationMs; self.position = position; self.groupPath = groupPath
            self.target = target; self.libraryTrack = libraryTrack; self.artworkURL = artworkURL; self.matched = matched
        }
    }

    /// 分组标题（专辑页按碟、按作品分组；乐章按作品分组）。
    public struct BrowseGroup: Codable, Sendable, Hashable {
        /// 分组编号，在同一个列表里唯一；BrowseTarget.focusGroup 用它定位。
        public var id: String
        public var title: String
        public var localizedTitle: String?
        public var subtitle: String?
        /// 分组标题本身能打开的对象。
        public var target: BrowseTarget?
        public init(id: String, title: String, localizedTitle: String? = nil, subtitle: String? = nil, target: BrowseTarget? = nil) {
            self.id = id; self.title = title; self.localizedTitle = localizedTitle; self.subtitle = subtitle; self.target = target
        }
    }

    /// 服务器音乐库里对上这张发行的一份专辑（专辑页用）。
    public struct BrowseLibraryCopy: Codable, Sendable, Hashable {
        /// 服务器音乐库里的专辑（来源为音乐库槽位号）。
        public var album: PlatformAlbum
        /// "recognized"（自动对上）或 "confirmed"（用户确认）。
        public var status: String
        /// 匹配理由。
        public var reasons: [String]
        /// 对上的曲目数与发行的总曲目数。
        public var matchedTracks: Int
        public var releaseTracks: Int
        public init(album: PlatformAlbum, status: String, reasons: [String] = [], matchedTracks: Int, releaseTracks: Int) {
            self.album = album; self.status = status; self.reasons = reasons
            self.matchedTracks = matchedTracks; self.releaseTracks = releaseTracks
        }
    }
}

// MARK: - 分区列表

extension API {
    /// 一个列表的说明：分区编号与可用的列表工具。
    public struct BrowseListSpec: Codable, Sendable, Hashable {
        /// 取列表时的 section 参数。
        public var section: String
        /// 列表标题（推入完整列表页时用）。
        public var title: String
        public var display: BrowseDisplay
        /// 可选的排序项，按菜单顺序；空数组表示不能改排序。
        public var sorts: [BrowseSort]
        public var defaultSort: String?
        /// 可选的显示方式，空数组表示没有。
        public var views: [BrowseOption]
        /// 可用的筛选项，按显示顺序。
        public var filters: [BrowseFilter]
        /// 是否支持文字过滤 q。
        public var textFilter: Bool
        public init(section: String, title: String, display: BrowseDisplay = .list, sorts: [BrowseSort] = [],
                    defaultSort: String? = nil, views: [BrowseOption] = [], filters: [BrowseFilter] = [], textFilter: Bool = false) {
            self.section = section; self.title = title; self.display = display; self.sorts = sorts
            self.defaultSort = defaultSort; self.views = views; self.filters = filters; self.textFilter = textFilter
        }
    }

    public struct BrowseSort: Codable, Sendable, Hashable {
        /// 如 "popularity"、"name"、"year"、"catalog"、"recordingYear"、"releaseYear"、"performer"、"catalogNumber"。
        public var id: String
        public var title: String
        /// 默认方向 "asc" / "desc"。
        public var defaultOrder: String
        public init(id: String, title: String, defaultOrder: String = "asc") {
            self.id = id; self.title = title; self.defaultOrder = defaultOrder
        }
    }

    public struct BrowseOption: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public struct BrowseFilter: Codable, Sendable, Hashable {
        /// 如 "onlyLibrary"、"completeOnly"、"genre"、"role"。
        public var id: String
        public var title: String
        /// "toggle"（开关）或 "multi"（多选）。不认识的类型客户端不显示这一项。
        public var type: String
        /// 开关的默认值。
        public var defaultOn: Bool?
        /// 多选的选项。
        public var options: [BrowseOption]?
        /// 多选是否支持“排除”。
        public var supportsExclude: Bool?
        /// 多选是否支持“任一符合”。
        public var supportsAny: Bool?
        /// 一句说明，可不给。
        public var note: String?
        public init(id: String, title: String, type: String, defaultOn: Bool? = nil, options: [BrowseOption]? = nil,
                    supportsExclude: Bool? = nil, supportsAny: Bool? = nil, note: String? = nil) {
            self.id = id; self.title = title; self.type = type; self.defaultOn = defaultOn; self.options = options
            self.supportsExclude = supportsExclude; self.supportsAny = supportsAny; self.note = note
        }
    }

    /// 列表的一页。分页字段与现有 PageResponse 同名。
    public struct BrowseListPage: Codable, Sendable, Hashable {
        public var items: [BrowseItem]
        /// 还有下一页时给；不透明字符串，里面含资料期次。
        public var nextCursor: String?
        /// 按当前筛选与过滤的总数；算不出（超时）时不给。
        public var total: Int?
        /// 数量文字。
        public var countText: String?
        /// 实际使用的排序、方向与显示方式。
        public var sort: String?
        public var order: String?
        public var view: String?
        public var dataVersion: String
        public init(items: [BrowseItem], nextCursor: String? = nil, total: Int? = nil, countText: String? = nil,
                    sort: String? = nil, order: String? = nil, view: String? = nil, dataVersion: String) {
            self.items = items; self.nextCursor = nextCursor; self.total = total; self.countText = countText
            self.sort = sort; self.order = order; self.view = view; self.dataVersion = dataVersion
        }
    }
}

// MARK: - 简介

extension API {
    public struct BrowseArticle: Codable, Sendable, Hashable {
        public var ref: BrowseRef
        public var title: String
        public var localizedTitle: String?
        /// 正文各章节，按原文顺序；第一节是导言（title 为空）。没有简介时为空数组。
        public var sections: [BrowseArticleSection]
        /// 正文语言。
        public var language: String?
        /// 关键资料，每项一行。
        public var facts: [BrowseFact]
        /// 正文的出处；没有正文时不出现。
        public var attribution: BrowseAttribution?
        public var dataVersion: String
        public init(ref: BrowseRef, title: String, localizedTitle: String? = nil, sections: [BrowseArticleSection] = [],
                    language: String? = nil, facts: [BrowseFact] = [], attribution: BrowseAttribution? = nil, dataVersion: String) {
            self.ref = ref; self.title = title; self.localizedTitle = localizedTitle; self.sections = sections
            self.language = language; self.facts = facts; self.attribution = attribution; self.dataVersion = dataVersion
        }
    }

    public struct BrowseArticleSection: Codable, Sendable, Hashable {
        /// 章节名；导言为空。
        public var title: String?
        /// 纯文字，段落之间用一个换行分隔。
        public var text: String
        public init(title: String? = nil, text: String) { self.title = title; self.text = text }
    }

    public struct BrowseFact: Codable, Sendable, Hashable {
        /// 项目名，如“出生”“国籍”“作品编号”。
        public var label: String
        /// 值（服务器拼好的文字）。
        public var value: String
        /// 值能对上资料对象时附上。
        public var target: BrowseTarget?
        /// 这一项的来源短名。
        public var source: String?
        public init(label: String, value: String, target: BrowseTarget? = nil, source: String? = nil) {
            self.label = label; self.value = value; self.target = target; self.source = source
        }
    }
}

// MARK: - 搜索

extension API {
    public struct BrowseSearchResult: Codable, Sendable, Hashable {
        public var query: String
        /// 服务器把搜索词识别成“作曲家＋作品目录号”时给出。
        public var interpretation: BrowseQueryInterpretation?
        /// 最佳结果（混合类别，0 到 3 项）。
        public var top: [BrowseItem]
        /// 各类别，按相关程度排顺序；没有结果的类别不出现。
        public var groups: [BrowseSearchGroup]
        public var dataVersion: String
        public init(query: String, interpretation: BrowseQueryInterpretation? = nil, top: [BrowseItem] = [],
                    groups: [BrowseSearchGroup] = [], dataVersion: String) {
            self.query = query; self.interpretation = interpretation; self.top = top; self.groups = groups
            self.dataVersion = dataVersion
        }
    }

    public struct BrowseQueryInterpretation: Codable, Sendable, Hashable {
        /// 识别出的作曲家。只说了目录号没说作曲家时不给。
        public var composer: BrowseItem?
        /// 目录体系的统一写法，如 "OP"、"BWV"、"K"。
        public var catalogSystem: String
        /// 完整编号的统一写法，如 "67"、"I:104"、"27 NO 2"。
        public var number: String
        /// 给人看的一句话。
        public var display: String
        public init(composer: BrowseItem? = nil, catalogSystem: String, number: String, display: String) {
            self.composer = composer; self.catalogSystem = catalogSystem; self.number = number; self.display = display
        }
    }

    public struct BrowseSearchGroup: Codable, Sendable, Hashable {
        /// 类别编号："composer"、"artist"、"work"、"album"、"label"。
        public var id: String
        public var title: String
        public var countText: String?
        public var total: Int?
        public var items: [BrowseItem]
        /// 还有更多时为真，客户端用 search/list?group=… 取全部。
        public var hasMore: Bool
        public init(id: String, title: String, countText: String? = nil, total: Int? = nil, items: [BrowseItem] = [],
                    hasMore: Bool = false) {
            self.id = id; self.title = title; self.countText = countText; self.total = total
            self.items = items; self.hasMore = hasMore
        }
    }
}

// MARK: - 可播放曲目与反查

extension API {
    public struct BrowseTracks: Codable, Sendable, Hashable {
        /// 服务器音乐库里的曲目，按播放顺序。
        public var tracks: [PlatformTrack]
        public var nextCursor: String?
        public var total: Int?
        public var dataVersion: String
        public init(tracks: [PlatformTrack], nextCursor: String? = nil, total: Int? = nil, dataVersion: String) {
            self.tracks = tracks; self.nextCursor = nextCursor; self.total = total; self.dataVersion = dataVersion
        }
    }

    public struct BrowseLibraryLinks: Codable, Sendable, Hashable {
        /// "recognized"（已对上）、"unrecognized"（未识别）、"pending"（还没轮到对照）。
        public var status: String
        /// 对上的发行（专辑页），以及打开后定位到的作品分组。
        public var release: BrowseLink?
        /// “前往”的各项，按显示顺序。
        public var links: [BrowseLink]
        public var dataVersion: String
        public init(status: String, release: BrowseLink? = nil, links: [BrowseLink] = [], dataVersion: String) {
            self.status = status; self.release = release; self.links = links; self.dataVersion = dataVersion
        }
    }
}
