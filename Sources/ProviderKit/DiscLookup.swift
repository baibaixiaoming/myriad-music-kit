import CryptoKit
import Foundation

/// 音乐 CD 的目录：各轨在光盘上的起点与结尾（以扇区计，含光盘开头的 150 扇区）。
/// 用来到公开的 CD 资料库按光盘查歌名。只含目录数字，不含任何个人信息。
public struct DiscTOC: Codable, Sendable, Hashable {
    public let firstTrack: Int
    public let lastTrack: Int
    /// 结尾位置（导出区起点）。
    public let leadOut: Int
    /// 各轨起点，依次对应 firstTrack…lastTrack。
    public let offsets: [Int]

    public init(firstTrack: Int, lastTrack: Int, leadOut: Int, offsets: [Int]) {
        self.firstTrack = firstTrack
        self.lastTrack = lastTrack
        self.leadOut = leadOut
        self.offsets = offsets
    }

    /// 公开 CD 资料库使用的光盘编号：目录按固定格式写成文字，取 SHA-1 后用改过三个符号的 Base64 表示。
    public var discID: String {
        var text = String(format: "%02X%02X", firstTrack, lastTrack)
        var table = [Int](repeating: 0, count: 100)
        table[0] = leadOut
        for (i, o) in offsets.enumerated() where firstTrack + i < 100 { table[firstTrack + i] = o }
        for v in table { text += String(format: "%08X", v) }
        let digest = Insecure.SHA1.hash(data: Data(text.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: ".").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "-")
    }

    /// 按目录模糊查找用的参数：“首轨 末轨 结尾 各轨起点”，以加号连接。
    public var tocQuery: String { ([firstTrack, lastTrack, leadOut] + offsets).map(String.init).joined(separator: "+") }
}

/// 按光盘查到的专辑信息。
public struct DiscInfo: Codable, Sendable, Hashable {
    public struct Track: Codable, Sendable, Hashable {
        public let number: Int
        public let title: String
        public let artist: String?
        public init(number: Int, title: String, artist: String?) {
            self.number = number; self.title = title; self.artist = artist
        }
    }
    public let album: String
    public let artist: String?
    public let tracks: [Track]
    public init(album: String, artist: String?, tracks: [Track]) {
        self.album = album; self.artist = artist; self.tracks = tracks
    }
}

/// 按光盘目录查歌名。只由家庭服务器实现（客户端经服务器查询，不直接访问外部资料库）。
public typealias DiscLookup = @Sendable (DiscTOC) async -> DiscInfo?
