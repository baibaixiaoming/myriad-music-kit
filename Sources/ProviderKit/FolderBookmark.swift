import Foundation

/// 用户选择的文件夹的访问书签。macOS 沙盒用“安全访问”书签；iOS 用普通书签（访问时同样调用 startAccessing）。
public enum FolderBookmark {
    public static func make(_ url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    public static func resolve(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
    }
}
