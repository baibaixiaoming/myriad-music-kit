import AppKit

// 轻量音乐服务器：只在菜单栏显示（Info.plist 里 LSUIElement）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
