// swift-tools-version: 6.0
// 聚合音乐共享组件：服务端与各客户端（电脑、手机）共用的数据结构、模块协议、接口定义、加密连接与本地音乐扫描。
// 本仓库只包含本项目自己编写的代码，不含任何移植自 GPL 项目的代码，可以宽松许可证开源。

import PackageDescription

let package = Package(
    name: "AccessibleMusicKit",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MusicCore", targets: ["MusicCore"]),
        .library(name: "ProviderKit", targets: ["ProviderKit"]),
        .library(name: "MusicAPI", targets: ["MusicAPI"]),
        .library(name: "SecureTransport", targets: ["SecureTransport"]),
        .library(name: "LocalMusic", targets: ["LocalMusic"]),
    ],
    targets: [
        // 统一领域模型：只依赖 Foundation。
        .target(name: "MusicCore"),
        // 模块协议、描述信息、注册表、通用工具（LRC 解析、音频格式解码、日志等）。
        .target(name: "ProviderKit", dependencies: ["MusicCore"]),
        // 客户端与服务端之间的接口定义。
        .target(name: "MusicAPI", dependencies: ["ProviderKit"]),
        // 客户端与服务端之间的加密连接（TLS 预共享密钥）。
        .target(name: "SecureTransport"),
        // 本地音乐文件夹扫描与播放（客户端本机音乐、服务端“服务器音乐库”共用）。
        .target(name: "LocalMusic", dependencies: ["ProviderKit"]),

        .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"]),
        .testTarget(name: "ProviderKitTests", dependencies: ["ProviderKit"]),
        .testTarget(name: "SecureTransportTests", dependencies: ["SecureTransport"]),
        .testTarget(name: "LocalMusicTests", dependencies: ["LocalMusic"]),
        .testTarget(name: "MusicAPITests", dependencies: ["MusicAPI", "ProviderKit"]),
    ]
)
