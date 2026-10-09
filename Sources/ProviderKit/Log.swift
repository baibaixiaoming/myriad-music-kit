import Foundation

/// 运行日志：追加写入统一数据文件夹的 logs/app.log。不得写入 Cookie、令牌、密码、手机号等敏感内容。
/// - 每行：本地时间（精确到毫秒）[类别] 内容。
/// - 文件保持打开，写入在一个后台队列里依次进行，不阻塞调用方。
/// - 超过 4 MB 换新文件：app.log → app.1.log → … → app.4.log，最多留 5 个（约 20 MB）。
public enum Log {
    private static let queue = DispatchQueue(label: "AccessibleMusic.Log")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var handlePath: String?
    nonisolated(unsafe) private static var size: UInt64 = 0
    static let rotateBytes: UInt64 = 4 << 20
    static let keep = 5

    /// 在自动测试里运行（测试不写正式日志，也不去占用正式端口）。
    public static let isTesting: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name.contains("swiftpm-testing-helper") || name.contains("xctest") || name.hasSuffix("PackageTests")
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 按平台记（平台模块用）。
    public static func write(_ platform: PlatformID?, _ message: String, paths: AppPaths = .shared) {
        write(category: platform?.rawValue ?? "app", message, paths: paths)
    }

    /// 按类别记（如“播放”“缓存”“连接”“界面”）。
    public static func write(category: String, _ message: String, paths: AppPaths = .shared) {
        if isTesting && paths.root == AppPaths.shared.root { return }
        let now = Date()
        let line = "\(stamp.string(from: now)) [\(category)] \(message)\n"
        let dir = paths.logs
        queue.async { append(Data(line.utf8), dir: dir) }
    }

    /// 等已经提交的日志都写进文件（上传前调用）。
    public static func flush() { queue.sync { try? handle?.synchronize() } }

    /// 日志文件，从旧到新（上传用）。
    public static func files(paths: AppPaths = .shared) -> [URL] {
        flush()
        let dir = paths.logs
        let names = (1..<keep).reversed().map { "app.\($0).log" } + ["app.log"]
        return names.map { dir.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    // MARK: 写入（只在 queue 里调用）

    private static func append(_ data: Data, dir: URL) {
        let file = dir.appending(path: "app.log")
        let path = file.path(percentEncoded: false)
        if handlePath != path || handle == nil { open(file, dir: dir) }
        if size + UInt64(data.count) > rotateBytes {
            rotate(dir: dir)
            open(file, dir: dir)
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += UInt64(data.count)
        } catch {
            // 文件被删掉等情况：下次重新打开
            Self.handle = nil
        }
    }

    private static func open(_ file: URL, dir: URL) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = file.path(percentEncoded: false)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        size = (try? h.seekToEnd()) ?? 0
        handle = h
        handlePath = path
    }

    private static func rotate(dir: URL) {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        func url(_ i: Int) -> URL { dir.appending(path: i == 0 ? "app.log" : "app.\(i).log") }
        try? fm.removeItem(at: url(keep - 1))
        for i in (0..<(keep - 1)).reversed() { try? fm.moveItem(at: url(i), to: url(i + 1)) }
        size = 0
    }
}
