import AppKit
import LightServerCore

/// 应用生命周期：启动服务器、建菜单栏图标；退出前停止服务器。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: LightServer?
    private var menu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        // 调试用：环境变量 LIGHT_MUSIC_PORT 换端口、LIGHT_MUSIC_HOME 换数据位置（见 ServerPaths）
        let port = ProcessInfo.processInfo.environment["LIGHT_MUSIC_PORT"].flatMap(UInt16.init) ?? LightServer.defaultPort
        let server = LightServer(paths: .standard(), port: port, serverVersion: version)
        self.server = server
        let menu = StatusMenu(server: server)
        self.menu = menu
        server.setStateHandler { _ in Task { @MainActor in menu.refresh() } }
        server.setLibraryHandler { _ in Task { @MainActor in menu.refresh() } }
        Task { await server.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }
}
