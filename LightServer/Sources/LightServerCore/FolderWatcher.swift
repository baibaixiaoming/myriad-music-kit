import Foundation
#if os(macOS)
import CoreServices

/// 监听音乐文件夹（含子文件夹）的变化：系统先合并 1 秒内的事件，这里再等 1.5 秒没有新变化才通知一次，
/// 拷贝一大批文件时不会反复扫描。只是隐藏文件（如访达的 .DS_Store）变了不通知。
final class FolderWatcher: @unchecked Sendable {
    private let path: String
    private let debounce: TimeInterval
    private let handler: @Sendable () -> Void
    private let queue = DispatchQueue(label: "LightMusic.FolderWatcher")
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    init(folder: URL, debounce: TimeInterval = 1.5, handler: @escaping @Sendable () -> Void) {
        path = folder.path(percentEncoded: false)
        self.debounce = debounce
        self.handler = handler
    }

    deinit { stopOnQueue() }

    /// 开始监听；已在监听时不重复开。返回是否成功。
    @discardableResult
    func start() -> Bool {
        queue.sync {
            guard stream == nil else { return true }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                watcher.received(Array(list.prefix(count)))
            }
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                                                 | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
            guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0, flags) else { return false }
            FSEventStreamSetDispatchQueue(s, queue)
            guard FSEventStreamStart(s) else {
                FSEventStreamInvalidate(s)
                FSEventStreamRelease(s)
                return false
            }
            stream = s
            return true
        }
    }

    /// 停止监听并取消还没发出的通知。停止后不会再调用 handler。
    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        pending?.cancel()
        pending = nil
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    /// 在监听队列上调用。
    private func received(_ paths: [String]) {
        guard stream != nil else { return }
        let meaningful = paths.contains { !(($0 as NSString).lastPathComponent.hasPrefix(".")) }
        guard meaningful else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.stream != nil else { return }
            self.pending = nil
            self.handler()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
#else
/// 手机上内置的演示服务器：示例音乐是只读的、不会变，不监听文件夹（start 返回 false，调用方只记一条日志）。
final class FolderWatcher: @unchecked Sendable {
    init(folder: URL, debounce: TimeInterval = 1.5, handler: @escaping @Sendable () -> Void) {}
    func start() -> Bool { false }
    func stop() {}
}
#endif
