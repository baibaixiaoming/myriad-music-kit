import AVFoundation
import Foundation

/// 一首歌的标签。
struct TrackTags {
    let title: String
    let artist: String
    let album: String
    let trackNumber: Int
    let trackTotal: Int
    let year: Int
    let genre: String
    let comment: String
}

enum WriterError: Error { case failed(String) }

/// FLAC：先用系统编码器写出音频，再自己重写元数据块（Vorbis 注释 + 封面图片 + 留白）。
enum FLACWriter {
    static func write(_ pcm: [Int16], to url: URL, tags: TrackTags, cover: Data, coverSize: Int) throws {
        try? FileManager.default.removeItem(at: url)
        let raw = url.deletingPathExtension().appendingPathExtension("raw.flac")
        try? FileManager.default.removeItem(at: raw)
        defer { try? FileManager.default.removeItem(at: raw) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2, interleaved: true) else {
            throw WriterError.failed("音频格式")
        }
        do {
            let file = try AVAudioFile(forWriting: raw, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let frames = pcm.count / 2
            let chunk = 16384
            var offset = 0
            while offset < frames {
                let n = min(chunk, frames - offset)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { throw WriterError.failed("缓冲") }
                buffer.frameLength = AVAudioFrameCount(n)
                pcm.withUnsafeBufferPointer { src in
                    buffer.int16ChannelData![0].update(from: src.baseAddress! + offset * 2, count: n * 2)
                }
                try file.write(from: buffer)
                offset += n
            }
        }
        try rewriteMetadata(raw: raw, to: url, tags: tags, cover: cover, coverSize: coverSize)
    }

    /// 保留 STREAMINFO 与 SEEKTABLE，去掉原有的注释、图片、留白，换成自己的。
    static func rewriteMetadata(raw: URL, to url: URL, tags: TrackTags, cover: Data, coverSize: Int) throws {
        let data = try Data(contentsOf: raw)
        let b = [UInt8](data)
        guard b.count > 8, Array(b[0..<4]) == Array("fLaC".utf8) else { throw WriterError.failed("不是 FLAC") }
        var pos = 4
        var keep: [(type: UInt8, body: [UInt8])] = []
        while true {
            guard pos + 4 <= b.count else { throw WriterError.failed("元数据块不完整") }
            let last = b[pos] & 0x80 != 0, type = b[pos] & 0x7F
            let length = Int(b[pos + 1]) << 16 | Int(b[pos + 2]) << 8 | Int(b[pos + 3])
            let body = Array(b[(pos + 4) ..< (pos + 4 + length)])
            if type == 0 || type == 3 { keep.append((type, body)) }
            pos += 4 + length
            if last { break }
        }
        var comments = [
            "TITLE=\(tags.title)", "ARTIST=\(tags.artist)", "ALBUMARTIST=\(tags.artist)", "ALBUM=\(tags.album)",
            "TRACKNUMBER=\(tags.trackNumber)", "TRACKTOTAL=\(tags.trackTotal)", "DATE=\(tags.year)",
            "GENRE=\(tags.genre)", "COMMENT=\(tags.comment)",
        ]
        comments.sort()
        var vorbis: [UInt8] = []
        func le32(_ v: Int) { vorbis += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        let vendor = Array("轻量音乐服务器 示例音乐生成程序".utf8)
        le32(vendor.count); vorbis += vendor
        le32(comments.count)
        for c in comments { let u = Array(c.utf8); le32(u.count); vorbis += u }
        keep.append((4, vorbis))

        var picture: [UInt8] = []
        func be32(_ v: Int) { picture += [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        let mime = Array("image/jpeg".utf8)
        be32(3)                     // 封面正面
        be32(mime.count); picture += mime
        be32(0)                     // 没有描述
        be32(coverSize); be32(coverSize); be32(24); be32(0)
        be32(cover.count); picture += [UInt8](cover)
        keep.append((6, picture))
        keep.append((1, [UInt8](repeating: 0, count: 1024)))   // 留白，以后改标签不用重写整个文件

        var out = Array("fLaC".utf8)
        for (i, block) in keep.enumerated() {
            let lastFlag: UInt8 = i == keep.count - 1 ? 0x80 : 0
            let n = block.body.count
            out += [lastFlag | block.type, UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            out += block.body
        }
        out += b[pos...]
        try Data(out).write(to: url, options: .atomic)
    }
}

/// ALAC（.m4a）：用系统的写入器把 16 位 PCM 编成苹果无损，同时写入 iTunes 标签与封面。
enum ALACWriter {
    static func write(_ pcm: [Int16], to url: URL, tags: TrackTags, cover: Data) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw WriterError.failed("不能添加音轨") }
        writer.add(input)
        writer.metadata = metadata(tags, cover: cover)
        guard writer.startWriting() else { throw WriterError.failed("开始写入：\(writer.error.map { "\($0)" } ?? "")") }
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { throw WriterError.failed("格式描述") }

        let frames = pcm.count / 2
        let chunk = 8192
        var offset = 0
        while offset < frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let n = min(chunk, frames - offset)
            let bytes = n * 4
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            guard let block else { throw WriterError.failed("数据块") }
            pcm.withUnsafeBytes { src in
                _ = CMBlockBufferReplaceDataBytes(with: src.baseAddress! + offset * 4, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: formatDescription,
                                                                 sampleCount: n, presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(sampleRate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            guard let sample, input.append(sample) else { throw WriterError.failed("追加数据：\(writer.error.map { "\($0)" } ?? "")") }
            offset += n
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw WriterError.failed("完成写入：\(writer.error.map { "\($0)" } ?? "")") }
    }

    static func metadata(_ tags: TrackTags, cover: Data) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, dataType: String? = nil) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.value = value
            if let dataType { m.dataType = dataType }
            return m
        }
        // 音轨号：iTunes 的 trkn 是 8 字节（0、0、音轨号、总数、0、0，各 16 位大端）
        var trkn = Data(count: 8)
        trkn[3] = UInt8(tags.trackNumber); trkn[5] = UInt8(tags.trackTotal)
        return [
            item(.iTunesMetadataSongName, tags.title as NSString),
            item(.iTunesMetadataArtist, tags.artist as NSString),
            item(.iTunesMetadataAlbumArtist, tags.artist as NSString),
            item(.iTunesMetadataAlbum, tags.album as NSString),
            item(.iTunesMetadataUserGenre, tags.genre as NSString),
            item(.iTunesMetadataReleaseDate, "\(tags.year)" as NSString),
            item(.iTunesMetadataUserComment, tags.comment as NSString),
            item(.iTunesMetadataTrackNumber, trkn as NSData, dataType: kCMMetadataBaseDataType_RawData as String),
            item(.iTunesMetadataCoverArt, cover as NSData, dataType: kCMMetadataBaseDataType_JPEG as String),
        ]
    }
}
