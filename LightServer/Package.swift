// swift-tools-version: 6.0
// 轻量音乐服务器：把一个音乐文件夹按家庭服务器协议提供给播放器（MIT 许可）。
// 只依赖共享组件（MIT，本地相对路径）与系统框架；不含任何移植自 GPL 项目的代码。
// 菜单栏应用见 App/（XcodeGen），示例音乐生成程序见 scripts/生成示例音乐/。

import PackageDescription

let package = Package(
    name: "LightMusicServer",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LightServerCore", targets: ["LightServerCore"]),
        .executable(name: "lms-check", targets: ["lms-check"]),
    ],
    dependencies: [
        .package(name: "AccessibleMusicKit", path: ".."),
    ],
    targets: [
        // 服务器核心：账号与设备、音乐库与封面、文件夹监听、接口分派、音频读取、组装与状态。
        .target(name: "LightServerCore", dependencies: [
            .product(name: "MusicAPI", package: "AccessibleMusicKit"),
            .product(name: "SecureTransport", package: "AccessibleMusicKit"),
            .product(name: "LocalMusic", package: "AccessibleMusicKit"),
            .product(name: "ProviderKit", package: "AccessibleMusicKit"),
        ]),
        // 连接测试：像播放器一样登录、列专辑、取封面、完整读一首歌。
        .executableTarget(name: "lms-check", dependencies: [
            .product(name: "MusicAPI", package: "AccessibleMusicKit"),
            .product(name: "SecureTransport", package: "AccessibleMusicKit"),
            .product(name: "ProviderKit", package: "AccessibleMusicKit"),
        ]),
        .testTarget(name: "LightServerCoreTests", dependencies: [
            "LightServerCore",
            .product(name: "MusicAPI", package: "AccessibleMusicKit"),
            .product(name: "SecureTransport", package: "AccessibleMusicKit"),
            .product(name: "LocalMusic", package: "AccessibleMusicKit"),
            .product(name: "ProviderKit", package: "AccessibleMusicKit"),
        ]),
    ]
)
