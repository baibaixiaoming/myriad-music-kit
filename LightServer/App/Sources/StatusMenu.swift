import AppKit
import LightServerCore

/// 菜单栏图标与菜单。从上到下：状态、地址、账号、打开音乐文件夹、开机自动启动、放入示例音乐、退出。
/// 每次打开菜单前刷新文字（地址可能变了、示例可能已放入、登录项可能在系统设置里被改了）。
/// 地址行与账号行点按后拷贝，并用读屏通知说一声。
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let server: LightServer
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let statusLine = NSMenuItem()
    private let retryItem = NSMenuItem(title: "重试启动", action: #selector(retry), keyEquivalent: "")
    private let addressLine = NSMenuItem()
    private let accountLine = NSMenuItem()
    private let openFolderItem = NSMenuItem(title: "打开音乐文件夹", action: #selector(openFolder), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin), keyEquivalent: "")
    private let samplesItem = NSMenuItem(title: "放入示例音乐", action: #selector(installSamples), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")

    init(server: LightServer) {
        self.server = server
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "music.note.house", accessibilityDescription: "轻量音乐服务器")
            image?.isTemplate = true
            button.image = image
            button.setAccessibilityLabel("轻量音乐服务器")
            button.toolTip = "轻量音乐服务器"
        }
        menu.autoenablesItems = false
        menu.delegate = self
        addressLine.action = #selector(copyAddress)
        accountLine.action = #selector(copyPassword)
        statusLine.action = #selector(doNothing)
        for i in [statusLine, retryItem, addressLine, accountLine, openFolderItem, loginItem, samplesItem, quitItem] { i.target = self }
        menu.items = [statusLine, retryItem, addressLine, accountLine, .separator(),
                      openFolderItem, loginItem, samplesItem, .separator(), quitItem]
        item.menu = menu
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func refresh() {
        let state = server.state
        switch state {
        case .stopped: statusLine.title = "已停止"
        case .starting: statusLine.title = "正在启动…"
        case .running:
            let count = server.songCount
            statusLine.title = count > 0 ? "运行中，共 \(count) 首歌" : "运行中，音乐文件夹里还没有歌"
        case .failed(let reason): statusLine.title = "启动失败：\(reason)"
        }
        retryItem.isHidden = { if case .failed = state { false } else { true } }()

        let port: UInt16 = { if case .running(let p) = state { p } else { server.requestedPort } }()
        if let address = NetworkAddress.lanIPv4().first {
            addressLine.title = "地址：\(address)　端口：\(port)"
            addressLine.toolTip = "点按拷贝地址"
            addressLine.isEnabled = true
        } else {
            addressLine.title = "地址：没有连接局域网　端口：\(port)"
            addressLine.toolTip = nil
            addressLine.isEnabled = true
        }

        if let account = server.account {
            accountLine.title = "账号：\(account.username)　密码：\(account.password)"
            accountLine.toolTip = "点按拷贝密码"
        } else {
            accountLine.title = "账号：正在准备…"
            accountLine.toolTip = nil
        }

        loginItem.state = LoginItem.isEnabled ? .on : .off
        samplesItem.isEnabled = !server.hasSampleMusic
        samplesItem.title = server.hasSampleMusic ? "放入示例音乐（已放入）" : "放入示例音乐"
    }

    // MARK: 操作

    @objc private func doNothing() {}

    @objc private func retry() { Task { await server.start() } }

    @objc private func copyAddress() {
        guard let address = NetworkAddress.lanIPv4().first else { return }
        copy(address, announcement: "已拷贝地址 \(address)")
    }

    @objc private func copyPassword() {
        guard let password = server.account?.password else { return }
        copy(password, announcement: "已拷贝密码")
    }

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: server.paths.music, withIntermediateDirectories: true)
        NSWorkspace.shared.open(server.paths.music)
    }

    @objc private func toggleLogin() {
        LoginItem.toggle()
        refresh()
    }

    @objc private func installSamples() {
        guard let bundled = Bundle.main.url(forResource: "示例音乐", withExtension: nil) else {
            show("找不到示例音乐", "应用里没有示例音乐文件夹，请重新安装轻量音乐服务器。")
            return
        }
        do {
            try server.installSampleMusic(from: bundled)
            announce("已放入示例音乐，播放器刷新后就能看到")
        } catch {
            show("放入示例音乐失败", error.localizedDescription)
        }
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 工具

    private func copy(_ text: String, announcement: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        announce(announcement)
    }

    /// 读屏通知（菜单关闭后说）。
    private func announce(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func show(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
