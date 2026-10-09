import AVFoundation
import Foundation

/// 读音乐文件里内嵌的封面：FLAC 自己读 PICTURE 块（优先“封面正面”），其他格式（M4A、MP3 等）交给系统读。
enum EmbeddedArtwork {
    /// 单张封面的上限。
    static let maxBytes = 10 * 1024 * 1024

    /// 文件里有没有内嵌封面（只看文件头部的信息，不读图片本身）。
    static func exists(in url: URL) async -> Bool {
        if url.pathExtension.lowercased() == "flac" { return flacPictureLocation(url) != nil }
        return await systemArtwork(url, loadData: false) != nil
    }

    static func read(from url: URL) async -> Data? {
        if url.pathExtension.lowercased() == "flac" {
            guard let (offset, length) = flacPictureLocation(url), length <= maxBytes,
                  let h = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? h.close() }
            guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: length), data.count == length else { return nil }
            return data
        }
        return await systemArtwork(url, loadData: true)
    }

    // MARK: FLAC

    /// FLAC 的 PICTURE 块里图片数据的位置。有“封面正面”（类型 3）就用它，否则用第一张。
    static func flacPictureLocation(_ url: URL) -> (offset: UInt64, length: Int)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.read(upToCount: 4)) == Data("fLaC".utf8) else { return nil }
        var pos: UInt64 = 4
        var fallback: (UInt64, Int)?
        for _ in 0..<128 {
            guard (try? h.seek(toOffset: pos)) != nil, let head = try? h.read(upToCount: 4), head.count == 4 else { break }
            let bytes = [UInt8](head)
            let last = bytes[0] & 0x80 != 0, type = bytes[0] & 0x7F
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            if type == 6, let picture = parsePictureHeader(h, blockStart: pos + 4, blockLength: length) {
                if picture.kind == 3 { return (picture.offset, picture.length) }
                if fallback == nil { fallback = (picture.offset, picture.length) }
            }
            pos += 4 + UInt64(length)
            if last { break }
        }
        return fallback
    }

    /// PICTURE 块：类型、MIME 长度与内容、描述长度与内容、宽高色深色数、数据长度、数据（都是大端）。
    private static func parsePictureHeader(_ h: FileHandle, blockStart: UInt64, blockLength: Int) -> (kind: UInt32, offset: UInt64, length: Int)? {
        // 头部最多读 64KB（MIME 与描述都很短）
        guard (try? h.seek(toOffset: blockStart)) != nil,
              let data = try? h.read(upToCount: min(blockLength, 64 * 1024)) else { return nil }
        let b = [UInt8](data)
        var p = 0
        func u32() -> UInt32? {
            guard p + 4 <= b.count else { return nil }
            defer { p += 4 }
            return UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3])
        }
        guard let kind = u32(), let mimeLength = u32() else { return nil }
        p += Int(mimeLength)
        guard let descLength = u32() else { return nil }
        p += Int(descLength)
        p += 16
        guard let dataLength = u32() else { return nil }
        let length = Int(dataLength)
        guard length > 0, p + length <= blockLength else { return nil }
        return (kind, blockStart + UInt64(p), length)
    }

    // MARK: 系统读取

    private static func systemArtwork(_ url: URL, loadData: Bool) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        let artwork = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork)
        guard let item = artwork.first else { return nil }
        guard loadData else { return Data([1]) }
        guard let data = try? await item.load(.dataValue), data.count <= maxBytes else { return nil }
        return data
    }
}
