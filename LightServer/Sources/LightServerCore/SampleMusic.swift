import Foundation

/// 示例音乐：随应用打包的一个文件夹，用户在菜单里选“放入示例音乐”时拷进音乐文件夹的“示例音乐”子文件夹。
/// 先拷到数据文件夹里的中转处，拷完整个移进去：音乐文件夹里不会出现拷了一半的文件。
public enum SampleMusic {
    public static let folderName = "示例音乐"

    public enum InstallError: Error, LocalizedError {
        case alreadyInstalled
        case missingBundle
        public var errorDescription: String? {
            switch self {
            case .alreadyInstalled: "音乐文件夹里已经有“\(folderName)”了"
            case .missingBundle: "应用里没有找到示例音乐"
            }
        }
    }

    public static func destination(in music: URL) -> URL { music.appending(path: folderName, directoryHint: .isDirectory) }

    public static func isInstalled(in music: URL) -> Bool {
        FileManager.default.fileExists(atPath: destination(in: music).path(percentEncoded: false))
    }

    /// 把 `bundled`（应用里的示例音乐文件夹）放进音乐文件夹。
    public static func install(from bundled: URL, paths: ServerPaths) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundled.path(percentEncoded: false)) else { throw InstallError.missingBundle }
        let target = destination(in: paths.music)
        guard !fm.fileExists(atPath: target.path(percentEncoded: false)) else { throw InstallError.alreadyInstalled }
        try fm.createDirectory(at: paths.music, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.stagingFolder, withIntermediateDirectories: true)
        let staged = paths.stagingFolder.appending(path: "\(folderName)-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: bundled, to: staged)
        do {
            try fm.moveItem(at: staged, to: target)
        } catch CocoaError.fileWriteFileExists {
            throw InstallError.alreadyInstalled
        } catch {
            // 不在同一个磁盘上时移动会失败：改为直接拷贝（拷到一半失败就删掉不完整的那份）
            guard !fm.fileExists(atPath: target.path(percentEncoded: false)) else { throw InstallError.alreadyInstalled }
            do { try fm.copyItem(at: staged, to: target) }
            catch CocoaError.fileWriteFileExists { throw InstallError.alreadyInstalled }
            catch { try? fm.removeItem(at: target); throw error }
        }
        serverLog("音乐库", "已放入示例音乐")
    }
}
