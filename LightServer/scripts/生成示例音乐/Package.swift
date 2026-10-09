// swift-tools-version: 6.0
// 示例音乐生成程序：用程序合成 3 张专辑、9 首约 30 秒的原创音乐，画封面、写标签与歌词。
// 只用系统框架。运行：scripts/生成示例音乐.sh（输出到仓库的 Resources/示例音乐）。

import PackageDescription

let package = Package(
    name: "SampleMusicGenerator",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "生成示例音乐", path: "Sources/生成示例音乐"),
    ]
)
