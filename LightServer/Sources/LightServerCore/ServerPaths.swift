import Foundation

/// 轻量音乐服务器的各个位置：
/// - 数据（账号、设备密钥、音乐库索引）：~/Library/Application Support/轻量音乐服务器/
/// - 日志：~/Library/Logs/轻量音乐服务器/
/// - 音乐文件夹：~/Music/轻量音乐服务器/
///
/// 调试时可以用环境变量 `LIGHT_MUSIC_HOME` 把三者都放到同一个文件夹下（data、logs、music 三个子文件夹）。
public struct ServerPaths: Sendable, Equatable {
    public static let appName = "轻量音乐服务器"
    public static let environmentKey = "LIGHT_MUSIC_HOME"

    public let support: URL
    public let logs: URL
    public let music: URL

    public init(support: URL, logs: URL, music: URL) {
        self.support = support
        self.logs = logs
        self.music = music
    }

    /// 测试与调试用：三个位置都放在 `home` 下。
    public init(home: URL) {
        self.init(support: home.appending(path: "data", directoryHint: .isDirectory),
                  logs: home.appending(path: "logs", directoryHint: .isDirectory),
                  music: home.appending(path: "music", directoryHint: .isDirectory))
    }

    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ServerPaths {
        if let home = environment[environmentKey], !home.isEmpty {
            return ServerPaths(home: URL(fileURLWithPath: home, isDirectory: true))
        }
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let musicRoot = fm.urls(for: .musicDirectory, in: .userDomainMask)[0]
        return ServerPaths(support: library.appending(path: "Application Support/\(appName)", directoryHint: .isDirectory),
                           logs: library.appending(path: "Logs/\(appName)", directoryHint: .isDirectory),
                           music: musicRoot.appending(path: appName, directoryHint: .isDirectory))
    }

    var accountFile: URL { support.appending(path: "account.json") }
    var devicesFile: URL { support.appending(path: "devices.json") }
    var libraryIndexFile: URL { support.appending(path: "library-index.json") }
    /// 放入示例音乐时的中转位置（与音乐文件夹通常在同一个磁盘上，拷完整体移过去）。
    var stagingFolder: URL { support.appending(path: "staging", directoryHint: .isDirectory) }

    /// 建好数据、日志、音乐三个文件夹。数据文件夹只有本人可读写（700）。
    /// 返回音乐文件夹是不是这次新建的。
    @discardableResult
    public func prepare() throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: support.path(percentEncoded: false))
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let existed = fm.fileExists(atPath: music.path(percentEncoded: false))
        try fm.createDirectory(at: music, withIntermediateDirectories: true)
        return !existed
    }
}
