import Foundation

/// 运行日志：一行一条，写到日志文件夹的 server.log，超过 2 MB 时改名为 server.1.log 再开新文件（只留一份旧的）。
/// 不写密码、密钥、搜索词与请求参数。
public final class ServerLog: @unchecked Sendable {
    public static let shared = ServerLog()
    static let maxBytes: UInt64 = 2 * 1024 * 1024

    private let queue = DispatchQueue(label: "LightMusic.ServerLog")
    private var file: URL?
    private var handle: FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// 以后的日志写进这个文件夹；没调用前只输出到标准错误。
    public func configure(directory: URL) {
        queue.sync {
            try? handle?.close()
            handle = nil
            file = directory.appending(path: "server.log")
        }
    }

    public var fileURL: URL? { queue.sync { file } }

    public func write(_ category: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(category)] \(message)\n"
        queue.async { [self] in
            guard let file else { FileHandle.standardError.write(Data(line.utf8)); return }
            if handle == nil {
                if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                    FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil)
                }
                handle = try? FileHandle(forWritingTo: file)
                _ = try? handle?.seekToEnd()
            }
            guard let h = handle else { return }
            try? h.write(contentsOf: Data(line.utf8))
            if let size = try? h.offset(), size > Self.maxBytes { rotate(file) }
        }
    }

    /// 等前面的日志都写完（测试与退出前用）。
    public func flush() { queue.sync {} }

    private func rotate(_ file: URL) {
        try? handle?.close()
        handle = nil
        let old = file.deletingLastPathComponent().appending(path: "server.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }
}

func serverLog(_ category: String, _ message: String) { ServerLog.shared.write(category, message) }
