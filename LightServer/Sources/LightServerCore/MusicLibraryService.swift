import Foundation
import LocalMusic
import ProviderKit

/// 音乐库：一个音乐文件夹，由共享组件的本地音乐模块扫描与查询；扫描后重建封面索引。
/// 来源编号就是槽位号 "1"，名称“本地音乐”，用途标为服务器音乐库。
actor MusicLibraryService {
    static let sourceID = PlatformID("1")
    static let sourceName = "本地音乐"
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "alac", "mp4",
                                               "dsf", "dff", "ape", "iso"]

    nonisolated let root: URL
    /// 音乐文件夹的规范路径（与本地音乐模块登记的写法一致）。
    nonisolated let rootPath: String
    nonisolated let library: LocalMusicLibrary
    nonisolated let provider: LocalMusicProvider
    nonisolated let artwork = ArtworkIndex()

    private var running = false
    private var pending = false
    private var songCount = 0
    private var onChange: (@Sendable (Int) -> Void)?

    init(root: URL, indexFile: URL) {
        rootPath = Self.normalized(root.path(percentEncoded: false))
        self.root = URL(fileURLWithPath: rootPath, isDirectory: true)
        library = LocalMusicLibrary(store: JSONLibraryStore(file: indexFile))
        provider = LocalMusicProvider(library: library, platform: Self.sourceID, displayName: Self.sourceName, role: .musicLibrary)
    }

    /// 扫描完成后通知（参数为歌曲数）。
    func setOnChange(_ handler: (@Sendable (Int) -> Void)?) { onChange = handler }

    var count: Int { songCount }

    /// 重新扫描（增量）。正在扫时再要求，会在这一轮结束后再扫一轮；多次要求合并成一轮。
    func rescan() async {
        if running { pending = true; return }
        running = true
        repeat {
            pending = false
            let begin = Date()
            do {
                try await syncFolderRegistration()
                try await library.rescan()
            } catch {
                serverLog("音乐库", "扫描出错：\(error)")
            }
            await rebuildArtwork()
            songCount = (try? await provider.library(.savedTracks, cursor: nil, context: Self.context).items.count) ?? 0
            let stats = await library.lastScanStats
            serverLog("音乐库", "扫描完成：\(songCount) 首歌，检查 \(stats.checked) 个文件、重新读取 \(stats.reindexed) 个，用时 \(Int(Date().timeIntervalSince(begin) * 1000)) 毫秒")
        } while pending
        running = false
        onChange?(songCount)
    }

    static var context: RequestContext { RequestContext(platform: sourceID, account: nil) }

    /// 让本地音乐模块只登记这一个文件夹。
    /// 本地音乐模块在“原来有歌、现在一个文件都没有”时会保留旧索引（为网络盘掉线设计）；这里的文件夹在本机，
    /// 文件夹不在了或里面已经没有音乐文件，就清掉旧索引，免得播放器里还看得到已删除的歌。
    private func syncFolderRegistration() async throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: rootPath, isDirectory: &isDir) && isDir.boolValue
        for folder in await library.folders where Self.normalized(folder.displayPath) != rootPath {
            try await library.removeFolder(id: folder.id)
        }
        let mine = await library.folders.filter { Self.normalized($0.displayPath) == rootPath }
        if !mine.isEmpty, await library.trackCount > 0, !exists || !Self.hasAudio(root) {
            for folder in mine { try await library.removeFolder(id: folder.id) }
            serverLog("音乐库", exists ? "音乐文件夹已经空了，清掉旧索引" : "音乐文件夹不见了，清掉旧索引")
        }
        if exists, await library.folders.isEmpty { try await library.addFolder(path: rootPath) }
    }

    /// 规范写法：去掉“.”“..”与末尾的斜杠（本地音乐模块登记文件夹时会带上末尾斜杠，比较时要去掉）。
    static func normalized(_ path: String) -> String {
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
        return clean.count > 1 && clean.hasSuffix("/") ? String(clean.dropLast()) : clean
    }

    /// 文件夹里（含子文件夹，不含隐藏文件）有没有音乐文件；找到一个就停。
    static func hasAudio(_ folder: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        for case let url as URL in e where audioExtensions.contains(url.pathExtension.lowercased()) { return true }
        return false
    }

    private func rebuildArtwork() async {
        let tracks = await library.tracksWithFingerprints().map { item in
            (path: item.track.path, fingerprint: item.fingerprint.map { ArtworkIndex.Fingerprint(size: $0.size, modified: $0.modified) })
        }
        var albums: [String: [String]] = [:]
        let context = Self.context
        if let page = try? await provider.library(.savedAlbums, cursor: nil, context: context) {
            for case .album(let album) in page.items {
                let songs = try? await provider.albumTracks(album.ref, cursor: nil, context: context)
                albums[album.ref.platformID] = songs?.items.compactMap { $0.metadata.originalURL?.path(percentEncoded: false) } ?? []
            }
        }
        await artwork.rebuild(tracks: tracks, albums: albums)
    }
}
