import AppKit
import ServiceManagement

/// 开机自动启动（系统的“登录项”）。只有放在“应用程序”文件夹里才允许打开，免得登记的是下载文件夹里的临时副本。
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// 应用是否在“应用程序”文件夹（系统的或用户自己的）里。
    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
        let user = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path(percentEncoded: false)
        return ["/Applications", user].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// 切换开关；失败或需要用户处理时弹出说明。
    static func toggle() {
        if isEnabled {
            do { try SMAppService.mainApp.unregister() }
            catch { alert("无法关闭开机自动启动", error.localizedDescription) }
            return
        }
        guard isInApplicationsFolder else {
            alert("请先把应用放进“应用程序”文件夹",
                  "开机自动启动只能用于“应用程序”文件夹里的轻量音乐服务器。请把它拖进“应用程序”文件夹，从那里打开后再试。")
            return
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            alert("无法打开开机自动启动", error.localizedDescription)
            return
        }
        if SMAppService.mainApp.status == .requiresApproval {
            alert("需要在系统设置里允许", "请在“系统设置 › 通用 › 登录项与扩展”里允许轻量音乐服务器。按“好”打开系统设置。")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "好")
        a.runModal()
    }
}
