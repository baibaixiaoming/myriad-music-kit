import Foundation

/// 只有本人可读写（600）的小文件：先写同一文件夹里的临时文件（建出来就是 600），写完落盘再改名替换，
/// 中途失败时原文件不受影响，也不会有一瞬间是别人可读的。
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let path = temp.path(percentEncoded: false)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = false
        defer { if !ok { unlink(path) } }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        }
        guard rename(path, url.path(percentEncoded: false)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        ok = true
    }

    /// 读取；文件不存在时返回 nil，其他读取错误照实抛出。
    static func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
        catch let e as CocoaError where e.code == .fileNoSuchFile { return nil }
    }

    /// 坏掉的文件改名留底（不删除），方便事后查看。
    static func setAside(_ url: URL) {
        let target = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).damaged-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
