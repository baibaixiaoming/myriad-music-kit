import Foundation

/// 整理后的资料库目录：专辑、歌手、歌曲都“干净”，像影视软件的媒体库一样。只改显示的目录，不动文件和原始索引。
///
/// 规则（参考 Navidrome、beets、Jellyfin、Lyrion 的做法自行编写）：
/// 1. 每首歌先补全信息：标签优先；缺的从文件名、文件夹（“歌手 - 专辑”“歌手/专辑/01 歌名”）、碟子文件夹推断。
/// 2. 同一位置先分组：碟子文件夹结构（CD1、Disc 2、碟三……，包括古典大套装）整个文件夹算一张专辑。
/// 3. 不同位置的同一张专辑合并：唱片资料库编号相同，或“专辑歌手 + 专辑名”相同、年份不冲突且同位置的歌名对得上。
/// 4. 音质版本：采样率、位深不同或 DSD 与 PCM、DSD 倍率不同的，只有两份曲目大量重合时才分成不同版本；
///    同一采样率的有损与无损算同一等级（取无损）。个别曲目格式不同的专辑不拆。
/// 5. 同一版本里同一首歌只留一份：碟号、曲号（或歌名）相同、歌名对得上且时长相差不超过 3 秒；无损、位深高、采样率高优先。
/// 6. 歌手：名字规整后（全半角、大小写、繁简、空格）相同的算一个人，显示最常见的写法。
struct LibraryCatalog: Sendable {
    typealias Track = LocalMusicLibrary.IndexedTrack

    struct Song: Sendable {
        /// 实际播放的那一份。
        let track: Track
        /// 同一首歌的其他副本（隐藏，不删除）。
        let alternates: [Track]
        let title: String
        let artists: [String]
        let albumID: String
        let album: String
        let albumArtist: String
        let disc: Int
        let number: Int?
    }

    struct Album: Sendable {
        let id: String
        let title: String
        let artist: String
        let year: Int?
        /// 有多个音质版本时的标注，如“24bit/96kHz”“DSD64”。
        let versionLabel: String?
        let songs: [Song]
        var discCount: Int { Set(songs.map(\.disc)).count }
        var displayTitle: String { versionLabel.map { "\(title) · \($0)" } ?? title }
    }

    struct Artist: Sendable {
        let key: String
        let name: String
        /// 作为专辑歌手的专辑，以及只是参与的专辑。
        let albumIDs: [String]
        let songCount: Int
    }

    var albums: [Album] = []
    var albumByID: [String: Int] = [:]
    var artists: [Artist] = []
    var artistByKey: [String: Int] = [:]
    /// “歌曲”列表：每首歌一份（有多个音质版本时取最好的版本）。
    var songs: [Song] = []
    /// 曲目编号 → 整理后的歌（含隐藏的副本，播放、取歌词时用）。
    var songByTrackID: [String: Song] = [:]

    static let variousArtists = "群星"
    static let unknownArtist = "未知歌手"
    static let unknownAlbum = "未知专辑"

    // MARK: 整理

    static func build(_ tracks: [Track], normalizer n: NameNormalizer = .shared) -> LibraryCatalog {
        // 1. 补全信息
        let infos = tracks.map { Info($0, n) }

        // 2. 同一位置分组
        var local: [String: [Info]] = [:]
        for i in infos { local[i.localKey, default: []].append(i) }
        var groups = local.values.map { Group($0, n) }

        // 3. 跨位置合并
        groups.sort { $0.sortKey < $1.sortKey }
        var merged: [Group] = []
        var byKey: [String: [Int]] = [:]
        for g in groups {
            if let candidates = byKey[g.mergeKey], let i = candidates.first(where: { merged[$0].compatible(with: g, n) }) {
                merged[i].absorb(g)
            } else {
                byKey[g.mergeKey, default: []].append(merged.count)
                merged.append(g)
            }
        }

        // 4、5. 音质版本与去重
        var catalog = LibraryCatalog()
        for g in merged {
            for version in g.versions(n) {
                var album = version.album(n)
                // 同名但不能合并的专辑（如不同年份）：编号里加上位置
                if catalog.albumByID[album.id] != nil { album = version.album(n, salt: g.sortKey) }
                catalog.albumByID[album.id] = catalog.albums.count
                catalog.albums.append(album)
                for s in album.songs {
                    catalog.songByTrackID[s.track.id] = s
                    for alt in s.alternates { catalog.songByTrackID[alt.id] = s }
                }
                if version.isPrimary { catalog.songs += album.songs }
            }
        }
        catalog.albums.sort {
            let c = $0.artist.localizedStandardCompare($1.artist)
            if c != .orderedSame { return c == .orderedAscending }
            return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
        }
        catalog.albumByID = Dictionary(uniqueKeysWithValues: catalog.albums.enumerated().map { ($1.id, $0) })
        catalog.songs.sort { ($0.albumArtist, $0.album, $0.disc, $0.number ?? 0, $0.title) < ($1.albumArtist, $1.album, $1.disc, $1.number ?? 0, $1.title) }

        // 6. 歌手
        var names: [String: [String: Int]] = [:]          // 规整后的名字 → 各种写法的出现次数
        var albumsOf: [String: [String]] = [:], primaryOf: [String: Set<String>] = [:]
        var songCount: [String: Int] = [:]
        for album in catalog.albums {
            let ak = n.key(album.artist)
            names[ak, default: [:]][album.artist, default: 0] += 1
            if primaryOf[ak, default: []].insert(album.id).inserted { albumsOf[ak, default: []].append(album.id) }
        }
        for s in catalog.songs {
            for a in s.artists {
                let k = n.key(a)
                names[k, default: [:]][a, default: 0] += 1
                songCount[k, default: 0] += 1
                if !(albumsOf[k]?.contains(s.albumID) ?? false) { albumsOf[k, default: []].append(s.albumID) }
            }
        }
        catalog.artists = names.map { key, forms in
            let name = forms.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
            // 作为专辑歌手的专辑排在前面
            let ids = (albumsOf[key] ?? []).sorted { (primaryOf[key]?.contains($0) == true ? 0 : 1) < (primaryOf[key]?.contains($1) == true ? 0 : 1) }
            return Artist(key: key, name: name, albumIDs: ids, songCount: songCount[key] ?? 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        catalog.artistByKey = Dictionary(uniqueKeysWithValues: catalog.artists.enumerated().map { ($1.key, $0) })
        return catalog
    }

    // MARK: 每首歌补全后的信息

    struct Info {
        let track: Track
        let title: String
        let artists: [String]
        let album: String
        let albumArtistTag: String?
        let disc: Int
        let number: Int?
        let year: Int?
        let localKey: String
        let rootName: String
        /// 是否处在碟子文件夹结构里（整个父文件夹算一张专辑，如古典大套装）。
        let boxed: Bool

        init(_ t: Track, _ n: NameNormalizer) {
            track = t
            let url = URL(fileURLWithPath: t.path)
            let folder = url.deletingLastPathComponent()
            let folderName = folder.lastPathComponent
            let folderDisc = PathHints.discNumber(folder: folderName)
            let root = folderDisc != nil ? folder.deletingLastPathComponent() : folder
            rootName = root.lastPathComponent
            boxed = folderDisc != nil
            // 歌名：标签里没有（等于文件名）时从文件名解析
            var title = t.title, number = t.trackNumber
            var artists = t.artists
            let base = url.deletingPathExtension().lastPathComponent
            if t.cueTrack == nil, t.cdTrack == nil, t.sacdArea == nil, t.innerPath == nil, t.title == base {
                let parsed = PathHints.fileName(base)
                title = parsed.title
                number = number ?? parsed.track
                if artists.isEmpty, let a = parsed.artist { artists = ArtistSplitter.split(a) }
            }
            // 专辑：标签优先（去掉末尾碟号说明），否则用文件夹名（“歌手 - 专辑”取专辑部分）
            let folderPair = PathHints.artistAlbum(folder: rootName)
            var albumName = t.album
            var albumDisc: Int?
            if let a = albumName { (albumName, albumDisc) = PathHints.stripDisc(a) }
            let album = albumName ?? folderPair?.album ?? rootName
            if artists.isEmpty, let a = folderPair?.artist { artists = ArtistSplitter.split(a) }
            self.title = title
            self.artists = artists
            self.album = album.isEmpty ? LibraryCatalog.unknownAlbum : album
            albumArtistTag = t.albumArtist.flatMap { $0.isEmpty ? nil : $0 }
            disc = t.discNumber ?? albumDisc ?? folderDisc ?? 1
            self.number = number
            year = t.year
            // 碟子文件夹结构：整个父文件夹算一张；否则“文件夹 + 专辑名”
            if let mb = t.musicBrainzAlbumID { localKey = "mb:" + mb }
            else if boxed { localKey = "box:" + root.path }
            else { localKey = "dir:" + folder.path + "\u{1F}" + n.key(self.album) }
        }
    }

    // MARK: 一张专辑的候选（一个或多个位置）

    struct Group {
        var infos: [Info]
        var title: String
        var artist: String
        var year: Int?
        var mergeKey: String
        var sortKey: String

        init(_ infos: [Info], _ n: NameNormalizer) {
            self.infos = infos
            // 专辑名：大家一致就用它；碟子文件夹结构里各碟名字不同（大套装）时取共同前缀，取不到用文件夹名
            let names = infos.map(\.album)
            let distinct = Set(names.map(n.key))
            if distinct.count <= 1 { title = names[0] }
            else if infos.contains(where: \.boxed) {
                let prefix = Group.commonPrefix(names)
                title = prefix.count >= 4 ? prefix : (PathHints.artistAlbum(folder: infos[0].rootName)?.album ?? infos[0].rootName)
            } else {
                title = Group.mostCommon(names) ?? names[0]
            }
            artist = Group.albumArtist(infos, n)
            year = Group.mostCommon(infos.compactMap(\.year))
            if let mb = infos.first?.track.musicBrainzAlbumID, infos.allSatisfy({ $0.track.musicBrainzAlbumID == mb }) {
                mergeKey = "mb:" + mb
            } else {
                mergeKey = n.key(artist) + "\u{1F}" + n.key(title)
            }
            sortKey = infos.map(\.track.path).min() ?? ""
        }

        static func commonPrefix(_ names: [String]) -> String {
            guard var prefix = names.first.map(Array.init) else { return "" }
            for name in names.dropFirst() {
                let c = Array(name)
                var i = 0
                while i < min(prefix.count, c.count), prefix[i] == c[i] { i += 1 }
                prefix = Array(prefix[..<i])
            }
            return String(prefix).trimmingCharacters(in: CharacterSet(charactersIn: " -–—:：,，(（[【").union(.whitespaces))
        }

        static func mostCommon<T: Hashable>(_ values: [T]) -> T? {
            Dictionary(grouping: values, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        }

        /// 专辑歌手：标签里写了就用多数写法；没写时看曲目歌手里最多的那位是否占一半以上；合辑或分散的归“群星”。
        static func albumArtist(_ infos: [Info], _ n: NameNormalizer) -> String {
            let tagged = infos.compactMap(\.albumArtistTag)
            if tagged.count * 2 >= infos.count, let best = mostCommon(tagged) {
                let key = n.key(best)
                if ["various artists", "various", "va", "群星", "合辑", "多位艺术家"].contains(key) { return variousArtists }
                return best
            }
            if infos.contains(where: { $0.track.compilation == true }) { return variousArtists }
            let primary = infos.compactMap { $0.artists.first }
            guard let best = mostCommon(primary.map(n.key)) else { return unknownArtist }
            let count = primary.filter { n.key($0) == best }.count
            if count == infos.count || (count >= 2 && count * 2 >= infos.count) || infos.count == 1 {
                return mostCommon(primary.filter { n.key($0) == best }) ?? unknownArtist
            }
            return variousArtists
        }

        /// 能否与另一个位置的同名专辑合并：年份不冲突，且同位置（碟号 + 曲号）的歌名基本对得上。
        func compatible(with other: Group, _ n: NameNormalizer) -> Bool {
            if mergeKey.hasPrefix("mb:") { return true }
            if let a = year, let b = other.year, a != b { return false }
            var mine: [String: Info] = [:]
            for i in infos { if let num = i.number { mine["\(i.disc)-\(num)"] = i } }
            var overlap = 0, conflict = 0
            for i in other.infos {
                guard let num = i.number, let m = mine["\(i.disc)-\(num)"] else { continue }
                overlap += 1
                let sameTitle = n.key(m.title) == n.key(i.title)
                let sameLength = abs((m.track.durationMS ?? 0) - (i.track.durationMS ?? 0)) <= 5000
                if !sameTitle && !sameLength { conflict += 1 }
            }
            return overlap == 0 || conflict * 10 <= overlap
        }

        mutating func absorb(_ other: Group) {
            infos += other.infos
            year = year ?? other.year
        }

        // MARK: 音质版本

        struct Version {
            let group: Group
            let infos: [Info]
            let label: String?
            let isPrimary: Bool

            func album(_ n: NameNormalizer, salt: String = "") -> Album {
                let baseID = group.mergeKey + (label.map { "\u{1F}" + $0 } ?? "") + salt
                let id = String(baseID.utf8.reduce(into: UInt64(1469598103934665603)) { $0 = ($0 ^ UInt64($1)) &* 1099511628211 }, radix: 36)
                // 同一首歌：碟号 + 曲号（没有曲号用歌名），歌名对得上且时长相差不超过 3 秒
                var buckets: [String: [[Info]]] = [:]
                var order: [String] = []
                for i in infos {
                    let key = "\(i.disc)-" + (i.number.map(String.init) ?? n.key(i.title))
                    if buckets[key] == nil { order.append(key) }
                    var list = buckets[key] ?? []
                    if let k = list.firstIndex(where: { same($0[0], i, n) }) { list[k].append(i) } else { list.append([i]) }
                    buckets[key] = list
                }
                var songs: [Song] = []
                for key in order {
                    for copies in buckets[key] ?? [] {
                        let sorted = copies.sorted { quality($0.track) > quality($1.track) }
                        let best = sorted[0]
                        songs.append(Song(track: best.track, alternates: sorted.dropFirst().map(\.track), title: best.title,
                                          artists: best.artists.isEmpty ? [group.artist] : best.artists, albumID: id,
                                          album: group.title, albumArtist: group.artist, disc: best.disc, number: best.number))
                    }
                }
                songs.sort { ($0.disc, $0.number ?? Int.max, $0.title) < ($1.disc, $1.number ?? Int.max, $1.title) }
                return Album(id: id, title: group.title, artist: group.artist, year: group.year, versionLabel: label, songs: songs)
            }

            func same(_ a: Info, _ b: Info, _ n: NameNormalizer) -> Bool {
                let close = abs((a.track.durationMS ?? 0) - (b.track.durationMS ?? 0)) <= 3000
                return close && (n.key(a.title) == n.key(b.title) || (a.number != nil && a.number == b.number))
            }

            /// 同一首歌的副本里谁更好：无损 > 有损，位深高、采样率高优先。
            func quality(_ t: Track) -> Int {
                (t.lossless == true ? 1 << 40 : 0) + (t.bitDepth ?? 0) << 32 + (t.sampleRate ?? 0)
            }
        }

        /// 音质等级：DSD 按倍率；PCM 按采样率与位深；有损按采样率（与同采样率的无损算同一等级）。
        static func qualityClass(_ t: Track) -> (key: String, label: String, rank: Int) {
            if t.codec == "dsd", let rate = t.sampleRate {
                return ("dsd:\(rate)", "DSD\(rate / 44100)", 1_000_000_000 + rate)
            }
            let rate = t.sampleRate ?? 44100
            let khz = Double(rate) / 1000
            let rateText = khz == khz.rounded() ? "\(Int(khz))kHz" : String(format: "%.1fkHz", khz)
            if t.lossless == true {
                let bits = t.bitDepth ?? 16
                return ("pcm:\(rate):\(bits)", "\(bits)bit/\(rateText)", rate * 64 + bits)
            }
            return ("lossy:\(rate)", rateText, rate * 64)
        }

        func versions(_ n: NameNormalizer) -> [Version] {
            // 先按等级分；有损并入同采样率的无损等级
            var classes: [String: [Info]] = [:]
            var labels: [String: (String, Int)] = [:]
            for i in infos {
                let c = Group.qualityClass(i.track)
                classes[c.key, default: []].append(i)
                labels[c.key] = (c.label, c.rank)
            }
            for key in classes.keys where key.hasPrefix("lossy:") {
                let rate = key.dropFirst(6)
                if let target = classes.keys.filter({ $0.hasPrefix("pcm:\(rate):") }).max(by: { labels[$0]!.1 < labels[$1]!.1 }) {
                    classes[target]! += classes.removeValue(forKey: key)!
                }
            }
            guard classes.count > 1 else { return [Version(group: self, infos: infos, label: nil, isPrimary: true)] }
            // 只有两份曲目大量重合（较小的一份有一半以上在另一份里）才分成不同版本
            func positions(_ list: [Info]) -> Set<String> { Set(list.map { "\($0.disc)-" + ($0.number.map(String.init) ?? n.key($0.title)) }) }
            let keys = classes.keys.sorted { labels[$0]!.1 > labels[$1]!.1 }
            var separate = false
            outer: for (i, a) in keys.enumerated() {
                for b in keys[(i + 1)...] {
                    let pa = positions(classes[a]!), pb = positions(classes[b]!)
                    if pa.intersection(pb).count * 2 >= min(pa.count, pb.count) { separate = true; break outer }
                }
            }
            guard separate else { return [Version(group: self, infos: infos, label: nil, isPrimary: true)] }
            return keys.enumerated().map { i, k in Version(group: self, infos: classes[k]!, label: labels[k]!.0, isPrimary: i == 0) }
        }
    }
}
