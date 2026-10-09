import Foundation
import ProviderKit

/// 数据光盘镜像（ISO 9660，优先用 Joliet 扩展读中文等长文件名）：列出所有文件及其在镜像中的位置。
/// 镜像可以是 2048 字节扇区（常见的 .iso），也可以是 2352 字节原始扇区（每扇区数据从第 16 字节开始）。
struct ISO9660 {
    struct File: Equatable {
        let path: String          // 镜像内路径，如 “音乐/01 晴天.flac”
        let offset: UInt64        // 在镜像文件里的字节位置（2048 扇区时有效）
        let size: UInt64
    }

    let url: URL
    let files: [File]
    let volumeName: String?

    init?(url: URL) {
        self.url = url
        guard let h = try? FileReader(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func sector(_ n: Int) -> Data? {
            try? h.seek(toOffset: UInt64(n * 2048))
            return try? h.read(upToCount: 2048)
        }
        // 卷描述符从第 16 扇区开始：类型 1 为主描述符，类型 2 且带 Joliet 转义序列为补充描述符
        var primary: Data?, joliet: Data?
        for n in 16..<64 {
            guard let d = sector(n), d.count == 2048, d.subdata(in: 1..<6) == Data("CD001".utf8) else { break }
            let type = d[d.startIndex]
            if type == 1 { primary = d }
            if type == 2 {
                let esc = d.subdata(in: 88..<91)
                if esc == Data([0x25, 0x2F, 0x40]) || esc == Data([0x25, 0x2F, 0x43]) || esc == Data([0x25, 0x2F, 0x45]) { joliet = d }
            }
            if type == 255 { break }
        }
        guard let vd = joliet ?? primary else { return nil }
        let unicode = joliet != nil
        let label = vd.subdata(in: 40..<72)
        volumeName = (unicode ? String(data: label, encoding: .utf16BigEndian) : String(data: label, encoding: .ascii))?
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0")))
        // 根目录记录在描述符第 156 字节
        let root = vd.subdata(in: 156..<190)
        var result: [File] = []
        var visited = Set<UInt32>()
        func walk(extent: UInt32, size: UInt32, prefix: String, depth: Int) {
            guard depth < 16, !visited.contains(extent) else { return }
            visited.insert(extent)
            try? h.seek(toOffset: UInt64(extent) * 2048)
            guard let dir = try? h.read(upToCount: Int(size)) else { return }
            var p = 0
            while p < dir.count {
                let len = Int(dir[dir.startIndex + p])
                if len == 0 { p = (p / 2048 + 1) * 2048; continue }     // 记录不跨扇区，跳到下一扇区
                guard p + len <= dir.count, len >= 34 else { break }
                let r = dir.subdata(in: dir.startIndex + p ..< dir.startIndex + p + len)
                let ext = r.le32(2), fsize = r.le32(10), flags = r[r.startIndex + 25]
                let nameLen = Int(r[r.startIndex + 32])
                let nameData = r.subdata(in: 33 ..< 33 + nameLen)
                p += len
                if nameLen == 1, nameData.first == 0 || nameData.first == 1 { continue }   // “.” 与 “..”
                var name = (unicode ? String(data: nameData, encoding: .utf16BigEndian) : String(data: nameData, encoding: .isoLatin1)) ?? ""
                if let semi = name.firstIndex(of: ";") { name = String(name[..<semi]) }    // 去掉版本号 “;1”
                if name.hasSuffix(".") { name.removeLast() }
                let path = prefix.isEmpty ? name : prefix + "/" + name
                if flags & 0x02 != 0 {
                    walk(extent: ext, size: fsize, prefix: path, depth: depth + 1)
                } else {
                    result.append(File(path: path, offset: UInt64(ext) * 2048, size: UInt64(fsize)))
                }
            }
        }
        walk(extent: root.le32(2), size: root.le32(10), prefix: "", depth: 0)
        files = result
    }
}

/// 供服务器共享文件夹等外部模块查数据光盘里某个文件的位置。
public enum ISO9660Access {
    public static func file(_ image: URL, _ inner: String) -> (offset: UInt64, size: Int64)? {
        guard let iso = ISO9660(url: image), let f = iso.files.first(where: { $0.path == inner }) else { return nil }
        return (f.offset, Int64(f.size))
    }
}
