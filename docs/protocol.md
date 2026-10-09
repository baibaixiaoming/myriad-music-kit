# 家庭音乐服务器协议（第 2 版）

本文供想自己实现家庭音乐服务器的人使用。客户端只依赖本协议，不关心服务器内部如何取得音乐。权威定义以共享组件源码为准：
- 加密连接：`Sources/SecureTransport/`
- 接口路径与数据结构：`Sources/MusicAPI/API.swift`
- 数据结构的字段：`Sources/MusicCore/`、`Sources/ProviderKit/`（均为 Swift `Codable`，按 JSON 编码；日期为 ISO 8601；时长 `Duration` 编码为 `[秒, 阿秒]` 两个整数）

## 1. 连接

- 一个 TCP 端口，**只接受** TLS 1.2 预共享密钥连接，密码套件 **TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256（0xCCAC）**。双方握手后核对套件，不是 0xCCAC 即断开。**不得启用会话复用**（会话复用不经过预共享密钥选择，无法确认身份）。
- 身份与密钥：
  - 首次登录：身份 `u:<小写用户名>`，密钥 = PBKDF2-HMAC-SHA256（密码，盐 = `AccessibleMusic/v1/user/<小写用户名>`，600000 次，32 字节）。服务器保存派生密钥，不保存密码。
  - 之后：身份 `d:<设备编号>`，密钥为服务器发放的 32 字节随机设备密钥。
- 加密连接上是最小 HTTP/1.1：请求带 `Content-Length` 与 `Connection: close`；每个连接一个请求。响应带 `Content-Length`，或无长度、以关闭连接结束（事件流、音频）。

## 2. 登录与设备

- `POST /v1/session/login`（只有 `u:` 身份可用）：`{"deviceName": "…"}` → `{"user": {…}, "deviceID": "…", "deviceKey": "<Base64>"}`。
- 其余接口都用 `d:` 身份。服务器按身份确定用户。

## 3. 必须实现的接口

| 方法与路径 | 说明 |
|---|---|
| `GET /v1/server` | `{"serverVersion": "…", "protocolVersion": 2, "features": ["favorites", …]}`。客户端据此判断兼容性，并只显示服务器声明了的功能（见下文“服务器功能”） |
| `GET /v1/providers` | 来源列表（`[ProviderDescriptor]`）：名称、能力及证据等级、扫码方式。**客户端完全按这里显示功能**，只有证据等级为“已实现”及以上的能力才出现在界面 |
| `GET /v1/me` | 当前用户、各来源的账户状态、家庭成员 |

**来源编号就是槽位号，固定不变**：每个来源的编号（`ProviderDescriptor.platform`，以及收发数据里所有出现来源编号的地方）是服务器分配的“槽位号”——十进制数字字符串 `"1"`、`"2"`、`"3"`……服务器每接入一个新来源（自有音乐库、在线来源、歌词来源等，凡是出现在来源列表里的）就分配下一个没用过的号，分配后永久不变；来源去掉了，它的号也不回收给别的来源。客户端按编号记住用户在该来源上的偏好（例如音质）。**显示顺序另由来源列表的先后决定**，与号的大小无关。显示名称、能力、音质级别可以随时改，客户端每次连上都按最新的来源列表生成界面。

对客户端来说编号只是不透明的字符串：不要解析它，也不要假设它一定是数字（旧版服务器发的是别的字符串，照样能用）。要认出“服务器自己的音乐文件库”这类特殊来源，看来源描述里的可选字段 `role`（目前只有 `musicLibrary`；不认识的值当作普通来源），不要看编号。详见下文“来源编号与槽位”。

一台只提供自有音乐库的最简服务器，只需再实现 `search`、`library`、`track`、`lyrics`、`stream/open`、`stream/{编号}`，并在 `providers` 中声明相应能力。

## 4. 其余接口

见 `API.Path`：搜索、资料库、曲目、专辑与歌单曲目、歌手的热门歌曲与专辑（能力 `detail(artist)`）、歌词（含跨来源）、音频打开与按字节范围读取（必须支持 `Range` 并返回 206 与 `Content-Range`）、平台登录（短信、扫码事件流 `text/event-stream`，每条 `data: <JSON>`）、平台选择与借用、软件歌单 / 收藏 / 播放历史、下载候选与按音质打开。

服务器音乐库可以在来源能力里声明 `libraryRead(recentlyAdded)`：`GET /v1/library?platform=<音乐库槽位号>&section=recentlyAdded` 按首次加入时间（文件第一次被扫描进音乐库的时间，一张专辑取其中最早的文件）从新到旧列专辑，回复 `PageResponse<SearchItem>`（内容为 `.album`）。这一项不归 `catalogBrowse` 管，没配资料库也能用。

## 5. 错误

非 2xx 响应体为 `{"category": "<MusicErrorCategory>", "message": "<给用户看的说明>"}`。客户端直接向用户显示 `message`。

## 6. 版本

### 服务器功能

`features` 是可选的字符串数组。客户端只为声明了的功能显示页面和菜单；没有这个字段时视为都不提供。客户端忽略不认识的名称，所以新增功能不需要改协议版本。

| 名称 | 含义 | 相关接口 |
|---|---|---|
| `favorites` | 软件收藏 | `/v1/my/favorites…` |
| `playlists` | 软件播放列表 | `/v1/my/playlist…` |
| `history` | 播放历史 | `/v1/my/history…` |
| `playlistSharing` | 把软件播放列表只读分享给其他用户 | 播放列表的分享字段 |
| `downloads` | 由服务器提供下载 | `/v1/download/…` |
| `lyricsForTrack` | 按歌曲在多个来源查找歌词 | `/v1/lyrics/for-track` |
| `platformAccounts` | 平台账户登录与借用设置 | `/v1/platform-login/…`、`/v1/platform-choice`、`/v1/lending` |
| `rankedSearch` | 统一搜索：服务器同时搜各来源并排序 | `/v1/search/all` |
| `discLookup` | 按光盘目录查整张 CD 的歌名（由服务器联网查询） | `/v1/disc/lookup` |
| `diagnostics` | 接收客户端上传的崩溃记录与运行日志 | `/v1/diagnostics/upload` |
| `catalog` | 唱片资料查询：认唱片、取整张唱片的曲目、作品、作曲家与参与人员（只在服务器配置了资料库时声明） | `/v1/catalog/info`、`/v1/catalog/match`、`/v1/catalog/release` |
| `sourceIDMapping` | 旧来源编号换算：把客户端本机按旧编号保存的设置对到现在的槽位号 | `/v1/providers/ids` |
| `catalogBrowse` | 逐层浏览与简介（作曲家、艺人、作品、录音、专辑、唱片公司），只在资料库与浏览索引都配置且是同一期时声明 | `/v1/catalog/browse/…` |

搜索、详情、资料库、播放等内容能力不在这里声明，而是由 `/v1/providers` 中每个来源的能力描述决定。一个只提供自己音乐文件的服务器可以把 `features` 留空。

协议有不兼容改动时 `protocolVersion` 加一；只增加可选字段不加一。客户端遇到更旧的服务器提示“请更新服务器”，遇到更新的服务器提示“请更新客户端”。


### 自动换源（播放）

`POST /v1/stream/open` 可带 `track`（完整曲目信息）、`levels`（各来源编号 → 用户选的音质级别键）与 `maxTier`（用户设的“最高音质”，通用档位数字，可选）。原来源无法播放或只能试听时，服务器可在其他来源找同一录音：回复中 `substituteSource` 为实际来源的说明，`substituteNotice` 为一句话说明（如“来源 A 无法播放，已换成来源 B”；来源名称都由服务器给出），客户端按用户设置决定是否播报。

换源时目标来源的音质：
1. `levels` 里有目标来源的级别：照用（原有规则，旧客户端只发这个）；
2. 否则取“想要的档位”——原来源这次所请求级别标注的通用档位，再以 `maxTier` 为上限（只有其中一个时就用那一个）——在目标来源标了档位的级别里挑**不超过它的最高一档**；全都高于它时挑最低的一档；
3. 都没有：用该来源默认。

参考客户端会把“最高音质”先换算成每个来源不超过它的最高级别，连同用户给各来源单独选的级别一起放进 `levels`。


### 统一搜索

`GET /v1/search/all?q=…&kind=track|album|artist|playlist`（服务器功能 `rankedSearch`）：服务器同时搜所有来源，合并后返回 `{"items": [...], "failures": [{"platform", "message"}]}`。不去重。歌曲的排序由服务器决定（参考实现：搜索词提到的歌手的正常版本在前，现场版其次，同名但其他歌手的再次，DJ / 混音、剪辑、变速、伴奏、改编、翻唱以及“热播”等营销字样的版本在最后）；专辑、歌手、歌单只按各来源排名交错。


### 诊断上传

`POST /v1/diagnostics/upload`（服务器功能 `diagnostics`）：内容为 `DiagnosticUpload`（类型 `crash`、`system`、`log` 之一，原文件名、发生时间、设备、系统、应用版本、文字内容）。单次请求体不超过 4 MB，较大的日志由客户端分段上传。服务器按用户保存，只用于排查问题。


### 唱片资料

服务器功能 `catalog`，数据结构见 `Sources/MusicAPI/CatalogAPI.swift`：

- `GET /v1/catalog/info` → `CatalogInfo`（是否已配置资料库、资料版本）。
- `POST /v1/catalog/match`：`CatalogMatchRequest`（条码、唱片公司与唱片编号、专辑名、艺人、每碟每轨的曲名与时长，都可不填）→ `CatalogMatchResponse`（候选唱片，带 0 到 1 的吻合程度与判断依据，从最像到最不像）。
- `GET /v1/catalog/release?id=…` → `CatalogRelease`（整张唱片：碟、曲目、作品与乐章、作品目录号、作曲家、参与人员与乐器、唱片公司与编号、两个来源的原始编号）；查不到为 404。中文名按用户的曲名语言设置附在 `localized…` 字段里。

资料库没配置时，`info` 回复 `configured: false`，其余两个接口返回 502。


### 逐层浏览

服务器功能 `catalogBrowse`，数据结构见 `Sources/MusicAPI/CatalogBrowseAPI.swift`。按作曲家、艺人、作品、录音（演绎）、专辑（发行）、唱片公司逐层浏览唱片资料，并显示简介。只新增接口，`/v1/catalog/info`、`match`、`release` 不变；协议版本仍为 2。

**声明条件**：以下同时满足才声明——唱片资料大库已配置并能打开；浏览索引已配置、能打开、格式版本受支持；浏览索引记录的大库期次与正在用的大库一致；至少有一个领域。中文维基资料库没配置时照样声明，只是没有简介；音乐库对照没做完时照样声明，只是暂时没有“已有”标记。运行中浏览索引被换掉、期次不一致时，下一次 `/v1/server` 不再声明，期间的浏览请求回 502。

**接口**：

| 接口 | 参数 | 回复 |
|---|---|---|
| `GET /v1/catalog/browse/domains` | — | `BrowseDomains`：领域清单（第一版只有古典），每个领域带“我的资料库”列表 |
| `GET /v1/catalog/browse/page` | `kind`、`id`、`domain`（可选） | `BrowsePage`：页头＋简介摘要＋主按钮＋前往＋标签＋概览分段 |
| `GET /v1/catalog/browse/list` | `kind`、`id`、`section`，可选 `domain`、`sort`、`order`、`view`、`f.<筛选编号>`、`q`、`cursor`、`limit`（默认 50，最多 200） | `BrowseListPage` |
| `GET /v1/catalog/browse/article` | `kind`、`id` | `BrowseArticle`：全部章节与关键资料，只在用户打开“简介”时取 |
| `GET /v1/catalog/browse/search` | `q`（1 到 200 字），可选 `domain`、`onlyLibrary`、`groups`、`limit`（默认 5，最多 20） | `BrowseSearchResult`：最佳结果＋按类别分组 |
| `GET /v1/catalog/browse/search/list` | `q`、`group`，可选 `domain`、`onlyLibrary`、`cursor`、`limit` | `BrowseListPage`：一个类别的完整结果 |
| `GET /v1/catalog/browse/tracks` | `kind`、`id`，可选 `copy`、`shuffle`、`cursor`、`limit`（默认 500，最多 2000） | `BrowseTracks`：服务器音乐库里可播放的曲目 |
| `GET /v1/catalog/browse/for-library` | `platform`（音乐库槽位号）、`kind`（`track` / `album`）、`id` | `BrowseLibraryLinks`：曲目或专辑的“前往”去向与识别状态 |

领域首页就是 `page?kind=domain&id=<领域编号>`。

**页面与列表**：
- 哪一页有哪些标签、分段、排序、显示方式、筛选，全由服务器下发；客户端不写死“古典”“作曲家”等领域词。标签 `kind` 为 `overview` 时内容是页面的 `sections`，为 `list` 时内容是一个分页列表（`list` 说明＋可选 `firstPage`）。分段的 `tab` 表示激活段标题时切到哪个标签，`list` 表示推入完整列表页；两者都没有表示已全部列出。
- 概览每段项数参考值：人物、作品、录音、曲目 5 项，专辑 8 项，乐章全部列出（最多 50 项）。
- 列表参数：筛选写法 `f.<编号>=1|0`（开关）、`f.<编号>=a,b`（多选）、前加 `!` 表示排除（只在 `supportsExclude` 为真时）、`f.<编号>.match=any|all`（只在 `supportsAny` 为真时，默认 all）；`q` 文字过滤只在 `textFilter` 为真时可用，最多 100 字。不认识的筛选编号或不支持的写法回 400。翻页用回复里的不透明游标 `nextCursor`。
- 列表规则由服务器执行：作品的录音列表、专辑的“版本”列表里已有的总排在最前；“只看完整录音”只作用于资料库外的录音；全资料库的人物与作品列表默认按热度，“我的资料库”里的列表默认按名称（中文模式按拼音）。

**开放取值**：对象类型 `BrowseKind`、显示方式 `BrowseDisplay` 是字符串包装，新服务器多出新值时旧客户端照样能解码：不认识的对象类型按通用对象显示，不认识的显示方式当 `list`，不认识的标签类型当 `list`，不认识的筛选类型不显示这一项。

**“已有”**：只用一个标记 `owned: true`（不是已有时不出现）。只看服务器音乐库，只认已对上大库的专辑：发行——音乐库里有专辑对上这一张发行；演绎——它的录音出现在任何一个已有的发行里；作品——它或它的乐章有任何一个已有的演绎（`ownedCount` 为已有演绎数）；作曲家、艺人、唱片公司——资料库里有与其相关的已有演绎或发行。“已有”每次请求实时叠加，音乐库变化即时可见。

**“版本”与“演绎”**：“版本”（专辑页标签 `versions`）只指同一专辑的其他发行；“演绎”（对象类型 `performance`，界面叫“录音”）只指同一批演奏者对同一作品的一次录音。两者在字段名、分区编号与显示文字里都不混用。

**名称**：`title` 原名，`localizedTitle` 中文名（账户曲名语言为中文且有中文名时才给），人物、团体、唱片公司也用这一对字段，规则与唱片资料接口相同；客户端显示 `localizedTitle ?? title`。`subtitle`、`line`、`countText`、`kindTitle`、段标题、标签名、排序与筛选名、出处句都由服务器拼好，客户端原样显示。

**简介与出处**：摘要 `BrowseSummary` 与全文 `BrowseArticle` 都带出处 `BrowseAttribution`（来源短名、完整出处句、原文链接、条目标题、许可与许可链接）和语言（BCP 47）。客户端必须在显示简介处显示出处（维基百科内容的署名要求），不写死任何来源名；按 `language` 给文字设语言，英文简介读屏自动换语音。来源顺序：中文维基 → 没有时其他资料来源的英文简介 → 都没有就不给正文。

**搜索**：资料库内外混合，按相关程度排序，资料库内加分（不保证一律排在前）；`onlyLibrary=1` 只返回已有的对象。搜索词能识别成“作曲家＋作品目录号”（如“贝多芬 op 67”“BWV 1007”“K.525”）时，回复带 `interpretation`，并按“作曲家＋目录体系＋完整编号”精确查，精确结果在 `top` 与“作品”组最前，模糊结果作补充。名称按精确、前缀、任意位置包含查找，各种语言与写法对到同一对象；命中的是别名时在 `matched` 里给出。规范化规则由唱片资料一侧定，浏览索引记有规则版本。

**可播放曲目与反查**：`browse/tracks` 与 `browse/for-library` 返回服务器音乐库的现有曲目、专辑结构（`PlatformTrack` / `PlatformAlbum`），来源编号是音乐库槽位号，客户端用现有 `/v1/track`、`/v1/album-tracks`、`/v1/stream/open` 播放，不新增播放方式。录音播这个演绎的各段；专辑播整张；作品播排第一的已有录音；作曲家、艺人、唱片公司播资料库里相关的全部录音（`shuffle=1` 时服务器逐首打乱后分页给）。没有可播内容时回 404。`for-library` 的 `status` 为 `recognized`、`unrecognized`（客户端标“未识别”）或 `pending`（客户端不显示）；其他来源的编号回 400。

**错误、超时与缓存**：错误体沿用 `{category, message}`。

| 情况 | 状态码 | 类别 |
|---|---|---|
| 参数缺失或无效 | 400 | `parseFailure` |
| 对象不存在（旧编号也转不到）、分区不存在、没有可播放的曲目 | 404 | `resourceRemoved` |
| 游标来自旧一期资料 | 409 | `upstreamChanged`（客户端从第一页重取） |
| 没配置资料库或浏览索引、两者期次不一致、文件读不到 | 502 | `moduleUnavailable` |
| 查询超时 | 502 | `timeout` |

服务器对每条数据库查询设 3 秒上限。页头超时整页回 502 `timeout`；某个分段超时只这一段 `items` 为空、`message` 给出说明，页面其余照常；列表只是数总数超时时照常回行、不给 `total`。建议客户端对浏览接口的等待上限 10 秒。旧编号服务器自动转成新编号，回复里的 `ref` 是新编号。每个回复都带 `dataVersion`（客户端不解析）；看到与已存页面不同的 `dataVersion` 时丢掉旧页面和旧游标。




### 来源编号与槽位

- 编号规则见第 3 节：槽位号，永久不变、不回收；显示顺序看来源列表的先后。
- 参考服务器内部仍用自己的名字（会话文件夹、用户目录、软件歌单与收藏里存的曲目都照旧），只在收发客户端数据的边界上转换：发出的数据里所有来源编号换成槽位号；收到的槽位号换回内部名，收到旧客户端发来的旧编号原样接受。所以旧客户端连新服务器、新客户端连旧服务器都能用。对照表存在服务器数据文件夹 `server/source-slots.json`，随整站备份。
- `POST /v1/providers/ids`（服务器功能 `sourceIDMapping`）：`{"ids": ["<旧编号>", …]}` → `{"ids": {"<旧编号>": "<现在的编号>", …}}`。客户端在本机按来源保存的设置里发现当前来源列表没有的编号时调用一次，把设置对到新编号上；服务器不认识的编号不出现在结果里。参考客户端另外记下“编号 → 显示名称”，服务器给不出对照时按唯一同名的来源对上；两样都对不上的旧设置原样保留、不删除。


### 通用音质档位

各来源自己的音质名称各不相同。服务器可以给每个音质级别（`ProviderDescriptor.streamLevels` 里的 `StreamQualityLevel`）和实际返回的音质（`AudioQuality`，见播放与下载的回复）标上固定的通用档位，客户端据此统一显示、比较高低，并把用户的“最高音质”换算成各来源的级别。这些都是可选字段：旧服务器不发，客户端照常按来源自己的名称显示。

`tier`（整数）：

| 值 | 显示名称 | 含义 |
|---|---|---|
| 1 | 省流 | 有损，约 128kbps 及以下 |
| 2 | 标准 | 有损，约 192kbps |
| 3 | 高品质 | 有损，约 320kbps |
| 4 | 无损 | CD 规格，16bit/44.1kHz（48kHz 及以下的 16bit 无损都算这一档） |
| 5 | 高解析 | 24bit，48kHz 及以下 |
| 6 | 高解析 96 | 24bit，88.2~96kHz |
| 7 | 高解析 192 | 24bit，176.4kHz 及以上 |
| 8 | DSD | DSD（含 SACD） |

另有两个独立标注，不混进档位高低：`multichannel`（true 多声道 / false 双声道）、`spatial`（是否空间音频，如杜比全景声）。未知时不发。客户端遇到不认识的档位数字照样能解码，显示为“档位 N”。

按文件实际格式归档的规则（服务器自有音乐库、客户端本机音乐共用，见 `QualityTier.classify`）：DSD 为 8；无损格式按采样率与位深——176.4kHz 及以上为 7，88.2kHz 及以上为 6，位深超过 16 或采样率超过 48kHz 为 5，其余为 4；有损格式按码率——256kbps 及以上为 3，160kbps 及以上为 2，其余为 1，码率不明时不归档。

“不超过上限的最高档”（`StreamQualityLevel.best`）：在标了档位的级别里挑档位不超过上限的最高一档，同档取列表里靠后的；全都高于上限时挑档位最低的；没有任何级别标档位时不选（由来源默认）；标了空间音频或多声道的级别只在没有普通级别时才考虑。

