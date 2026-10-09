# 家庭音乐服务器协议与轻量音乐服务器

一套开放的“家庭音乐服务器协议”，以及用它写成的一个最小服务器。服务器把音乐提供出来，播放器通过加密连接来浏览、搜索、播放；播放器只认协议，不关心音乐从哪里来。

第一次看，请从 [docs/入门指南.md](docs/入门指南.md) 开始：五分钟跑起来，以及自己写一个兼容服务器要做哪些事。协议全文见 [docs/protocol.md](docs/protocol.md)。

## 两部分

| 位置 | 是什么 |
|---|---|
| 根目录（Swift 包 `AccessibleMusicKit`） | **共享组件**：协议的权威定义和可以直接复用的代码。`MusicCore` 数据结构，`MusicAPI` 接口路径与回复结构，`SecureTransport` 加密连接（TLS 1.2 预共享密钥 + 最小 HTTP），`ProviderKit` 来源协议、歌词解析与音频格式解码，`LocalMusic` 本地音乐文件夹扫描 |
| `LightServer/` | **轻量音乐服务器**：一个菜单栏小程序，把电脑上的一个音乐文件夹按协议提供给播放器。既能直接用，也是“怎么写服务器”的完整示例。自带 3 张原创示例专辑 |

只用 Swift 和系统框架，不依赖任何第三方库，也不包含任何在线音乐平台的代码。

## 编译与测试

需要 macOS 14 或更新、Xcode（Swift 6）。菜单栏应用的工程用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成。

```sh
# 共享组件（在仓库根目录）
swift build
swift test

# 轻量音乐服务器
cd LightServer
swift build
swift test
scripts/编译安装.sh --no-install                 # 编译菜单栏应用（本机自签名）
swift run lms-check 127.0.0.1 7710 demo <密码>    # 连接测试：登录、列专辑、取封面、完整读一首歌
```

更多用法见 [LightServer/README.md](LightServer/README.md)。

## 许可

- 代码：MIT，见 [LICENSE](LICENSE)。
- 例外：`Sources/ProviderKit/APEDecoder.swift`（APE 无损音频解码）按 Monkey's Audio SDK 改写，同时受其 BSD 三条款许可约束（版权 Matthew T. Ashland），原文见 [LICENSES/MonkeysAudio-BSD-3-Clause.txt](LICENSES/MonkeysAudio-BSD-3-Clause.txt)。
- 示例音乐、封面与歌词：本项目原创，程序合成，CC0，见 [LightServer/示例素材授权.md](LightServer/示例素材授权.md)。
