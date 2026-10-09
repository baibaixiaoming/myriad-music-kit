import Foundation
import Testing
@testable import ProviderKit

struct LogTests {
    @Test func writesLinesAndRotates() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "am-log-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(root: root)
        Log.write(category: "播放", "开始播放：测试", paths: paths)
        Log.flush()
        let text = try String(contentsOf: paths.logs.appending(path: "app.log"), encoding: .utf8)
        #expect(text.contains("[播放] 开始播放：测试"))
        // 写满 4 MB 换新文件，最多留 5 个
        let line = String(repeating: "x", count: 1000)
        for _ in 0..<(4 * 6 * 1100) { Log.write(category: "测试", line, paths: paths) }
        let files = Log.files(paths: paths)
        #expect(files.count == 5)
        for f in files {
            let size = (try FileManager.default.attributesOfItem(atPath: f.path(percentEncoded: false))[.size] as? Int) ?? 0
            #expect(size <= 4 << 20)
        }
    }
}
