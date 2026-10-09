import Foundation
import LocalMusic
import ProviderKit

/// 对外的音乐库查询：在本地音乐模块的结果上
/// - 把曲目编号换成音乐文件夹里的相对路径（不把用户主目录的完整路径发出去），去掉文件地址；
/// - 补上封面地址；
/// - 补上专辑、歌手搜索（本地音乐模块只搜歌曲）。
struct LibraryQueries: Sendable {
    let service: MusicLibraryService
    var provider: LocalMusicProvider { service.provider }
    var context: RequestContext { MusicLibraryService.context }

    /// 本服务器唯一的来源描述：本地音乐模块的能力，加上专辑、歌手搜索。
    var descriptor: ProviderDescriptor {
        let base = provider.descriptor
        var caps = base.capabilities
        caps.insert(contentsOf: [.init(.search(.album), .implemented), .init(.search(.artist), .implemented)], at: 1)
        var d = ProviderDescriptor(platform: base.platform, displayName: base.displayName, moduleVersion: base.moduleVersion,
                                   integration: base.integration, accountRequirement: base.accountRequirement,
                                   dependencies: base.dependencies, capabilities: caps)
        d.role = base.role
        return d
    }

    static let searchKinds: Set<SearchKind> = [.track, .album, .artist]
    static let sections: Set<LibrarySection> = [.savedTracks, .savedAlbums, .followedArtists]

    // MARK: 编号

    func wireID(_ internalID: String) -> String {
        let prefix = service.rootPath + "/"
        return internalID.hasPrefix(prefix) ? String(internalID.dropFirst(prefix.count)) : internalID
    }

    func internalID(_ wireID: String) -> String {
        wireID.hasPrefix("/") ? wireID : service.rootPath + "/" + wireID
    }

    func ref(_ kind: PlatformResourceRef.Kind, _ id: String) -> PlatformResourceRef {
        PlatformResourceRef(platform: MusicLibraryService.sourceID, kind: kind, platformID: kind == .track ? internalID(id) : id)
    }

    // MARK: 对外改写

    func wire(_ track: PlatformTrack) async -> PlatformTrack {
        var metadata = track.metadata
        let path = metadata.originalURL?.path(percentEncoded: false)
        metadata.originalURL = nil
        if let path { metadata.artworkURL = await service.artwork.url(forTrackPath: path) }
        let ref = PlatformResourceRef(platform: track.ref.platform, kind: .track, platformID: wireID(track.ref.platformID))
        return PlatformTrack(ref: ref, metadata: metadata, accessRequirement: track.accessRequirement)
    }

    func wire(_ album: PlatformAlbum) async -> PlatformAlbum {
        var a = album
        a.artworkURL = await service.artwork.url(forAlbum: album.ref.platformID)
        return a
    }

    func wire(_ item: SearchItem) async -> SearchItem {
        switch item {
        case .track(let t): .track(await wire(t))
        case .album(let a): .album(await wire(a))
        default: item
        }
    }

    func wire<T>(_ items: [T], _ transform: (T) async -> T) async -> [T] {
        var out: [T] = []
        out.reserveCapacity(items.count)
        for item in items { out.append(await transform(item)) }
        return out
    }

    // MARK: 查询

    func search(_ query: String, kind: SearchKind) async throws -> [SearchItem] {
        let words = SearchText.words(query)
        guard !words.isEmpty else { return [] }
        switch kind {
        case .track:
            return await wire(try await provider.search(query, kind: .track, cursor: nil, context: context).items, wire)
        case .album:
            let all = try await provider.library(.savedAlbums, cursor: nil, context: context).items
            let hits = all.filter { item in
                guard case .album(let a) = item else { return false }
                return SearchText.matches(words, in: [a.title] + a.artists)
            }
            return await wire(hits, wire)
        case .artist:
            let all = try await provider.library(.followedArtists, cursor: nil, context: context).items
            return all.filter { item in
                guard case .artist(let a) = item else { return false }
                return SearchText.matches(words, in: [a.name])
            }
        case .playlist:
            return []
        }
    }

    func section(_ section: LibrarySection) async throws -> [SearchItem] {
        await wire(try await provider.library(section, cursor: nil, context: context).items, wire)
    }

    func track(_ id: String) async throws -> PlatformTrack {
        await wire(try await provider.track(ref(.track, id), context: context))
    }

    func albumTracks(_ id: String) async throws -> [PlatformTrack] {
        await wire(try await provider.albumTracks(ref(.album, id), cursor: nil, context: context).items, wire)
    }

    func artistTracks(_ id: String) async throws -> [PlatformTrack] {
        await wire(try await provider.artistTracks(ref(.artist, id), cursor: nil, context: context).items, wire)
    }

    func artistAlbums(_ id: String) async throws -> [PlatformAlbum] {
        await wire(try await provider.artistAlbums(ref(.artist, id), cursor: nil, context: context).items, wire)
    }

    /// 歌词：同名 .lrc 文件，其次文件内嵌歌词（本地音乐模块负责读）。
    func lyrics(_ id: String) async throws -> LyricsResult {
        let r = ref(.track, id)
        let query = LyricsQuery(unifiedTrack: UnifiedTrackID(), metadata: TrackMetadata(title: "", artists: []), platformRef: r)
        let result = try await provider.lyrics(for: query, context: context)
        let matched = result.matchedRef.map {
            PlatformResourceRef(platform: $0.platform, kind: $0.kind, platformID: wireID($0.platformID))
        }
        return LyricsResult(status: result.status, tracks: result.tracks, matchedRef: matched)
    }

    func resolve(_ id: String) async throws -> ResolvedStream {
        try await provider.resolveStream(ref(.track, id), preferredLevel: nil, context: context)
    }
}

/// 搜索用的文字规整：兼容字符、全半角、繁简、大小写都不影响；按空格分词，每个词都要出现。
enum SearchText {
    static func key(_ s: String) -> String {
        var t = s.precomposedStringWithCompatibilityMapping
        t = t.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? t
        t = t.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? t
        return t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func words(_ query: String) -> [String] { key(query).split(separator: " ").map(String.init) }

    static func matches(_ words: [String], in fields: [String]) -> Bool {
        let text = key(fields.joined(separator: " "))
        return words.allSatisfy { text.contains($0) }
    }
}
