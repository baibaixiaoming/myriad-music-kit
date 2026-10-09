import Foundation

/// 本软件唯一的数据根目录。程序设置、各平台登录信息、缓存、日志和软件资料库都放在这里，
/// 不散落到用户主目录的其他位置，也不使用 `UserDefaults`。删除这个文件夹即可完全清除本软件的数据。
///
/// 默认：`~/Library/Application Support/AccessibleMusic/`
/// 应用可在自己的 Info.plist 写 `AppDataFolderName` 换掉末尾的文件夹名（播放器用 MyriadPlayer）；
/// 没写这个键的（服务器、命令行、测试）一律仍是 AccessibleMusic。
/// 覆盖：环境变量 `ACCESSIBLE_MUSIC_HOME`（开发调试时用）。
///
/// ```
/// AccessibleMusic/
///   config/settings.json  程序设置（窗口位置、偏好、快捷键等）
///   data/<平台>/      各平台的登录信息（Cookie、令牌）与平台相关设置
///   cache/<平台>/     各平台的数据缓存
///   cache/http/       网络请求缓存
///   runtime/<平台>/   外部程序（仅在确需时使用）
///   logs/             日志
///   library/          软件资料库（歌单、收藏、下载任务记录）
/// ```
public struct AppPaths: Sendable {
    public static let environmentOverrideKey = "ACCESSIBLE_MUSIC_HOME"
    public static let shared = AppPaths()
    /// Info.plist 里指定数据文件夹名的键。
    public static let folderNameInfoKey = "AppDataFolderName"
    /// 没指定时的文件夹名。
    public static let fallbackFolderName = "AccessibleMusic"
    /// 本应用的数据文件夹名：Info.plist 的 `AppDataFolderName`（非空），否则 AccessibleMusic。
    public static var defaultFolderName: String {
        folderName(info: Bundle.main.infoDictionary ?? [:])
    }

    static func folderName(info: [String: Any]) -> String {
        guard let name = info[folderNameInfoKey] as? String, !name.isEmpty, !name.contains("/") else { return fallbackFolderName }
        return name
    }

    public let root: URL

    public init(root: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                folderName: String = AppPaths.defaultFolderName) {
        if let root {
            self.root = root
        } else if let override = environment[Self.environmentOverrideKey], !override.isEmpty {
            self.root = URL(filePath: override, directoryHint: .isDirectory)
        } else {
            self.root = URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
        }
    }

    public func runtime(_ platform: PlatformID) -> URL { dir("runtime", platform.rawValue) }
    public func data(_ platform: PlatformID) -> URL { dir("data", platform.rawValue) }
    public func cache(_ platform: PlatformID) -> URL { dir("cache", platform.rawValue) }
    public var config: URL { dir("config") }
    public var settingsFile: URL { config.appending(path: "settings.json") }
    public var httpCache: URL { dir("cache", "http") }
    public var logs: URL { dir("logs") }
    public var library: URL { dir("library") }

    /// 创建全部目录（已存在则跳过）。
    public func ensureDirectories(for platforms: [PlatformID]) throws {
        var all = [config, httpCache, logs, library]
        for p in platforms { all += [runtime(p), data(p), cache(p)] }
        for url in all {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func dir(_ components: String...) -> URL {
        components.reduce(root) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }
}
