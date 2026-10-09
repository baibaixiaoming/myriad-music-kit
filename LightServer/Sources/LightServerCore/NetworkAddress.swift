import Darwin
import Foundation

/// 本机的局域网 IPv4 地址（菜单里显示给用户，照着填进播放器）。
public enum NetworkAddress {
    /// 已连接、非回环的 IPv4 地址；有线与无线（en 开头）排在前面，跳过隧道、点对点等虚拟接口。
    public static func lanIPv4() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: p.pointee.ifa_name)
            guard !["utun", "awdl", "llw", "bridge", "anpi", "ap"].contains(where: { name.hasPrefix($0) }) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // 自动分配的链路本地地址（169.254）别人一般连不上
            guard !text.hasPrefix("169.254.") else { continue }
            found.append((name, text))
        }
        return found.sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }.map(\.address)
    }

    private static func rank(_ name: String) -> Int { name.hasPrefix("en") ? 0 : 1 }
}
