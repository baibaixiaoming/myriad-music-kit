import Foundation
import Testing
@testable import MusicCore

@Suite struct AppPathsTests {
    @Test func everythingStaysUnderRoot() {
        let root = URL(filePath: "/tmp/am-test", directoryHint: .isDirectory)
        let paths = AppPaths(root: root)
        for url in [paths.config, paths.httpCache, paths.logs, paths.library,
                    paths.runtime(PlatformID("test")), paths.cache(PlatformID("test"))] {
            #expect(url.path(percentEncoded: false).hasPrefix("/tmp/am-test"), "指向了数据文件夹以外：\(url)")
        }
        #expect(paths.data(PlatformID("test")).path(percentEncoded: false).hasPrefix("/tmp/am-test/data/test"))
    }

    @Test func environmentOverrideIsHonored() {
        let paths = AppPaths(environment: [AppPaths.environmentOverrideKey: "/tmp/am-override"])
        #expect(paths.root.path(percentEncoded: false).hasPrefix("/tmp/am-override"))
    }

    /// 没写 AppDataFolderName 的（服务器、命令行、测试）仍是 AccessibleMusic；空值、带斜杠的也不用。
    @Test func folderNameFallsBackToAccessibleMusic() {
        #expect(AppPaths.folderName(info: [:]) == "AccessibleMusic")
        #expect(AppPaths.folderName(info: ["AppDataFolderName": ""]) == "AccessibleMusic")
        #expect(AppPaths.folderName(info: ["AppDataFolderName": "a/b"]) == "AccessibleMusic")
        #expect(AppPaths.defaultFolderName == "AccessibleMusic")
        #expect(AppPaths(environment: [:]).root.lastPathComponent == "AccessibleMusic")
    }

    @Test func folderNameFromInfoIsUsed() {
        #expect(AppPaths.folderName(info: ["AppDataFolderName": "MyriadPlayer"]) == "MyriadPlayer")
        let paths = AppPaths(environment: [:], folderName: "MyriadPlayer")
        #expect(paths.root.lastPathComponent == "MyriadPlayer")
        #expect(paths.root.deletingLastPathComponent().standardizedFileURL.path == URL.applicationSupportDirectory.standardizedFileURL.path)
        // 环境变量仍然优先
        let over = AppPaths(environment: [AppPaths.environmentOverrideKey: "/tmp/am-override"], folderName: "MyriadPlayer")
        #expect(over.root.path(percentEncoded: false).hasPrefix("/tmp/am-override"))
    }
}
