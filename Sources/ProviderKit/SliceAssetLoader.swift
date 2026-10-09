import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// “文件中的一段”当作独立音频文件播放：CD 镜像里的一轨（原始 PCM 前面临时加上 WAV 头），
/// 或数据光盘镜像里的一个音乐文件（原样提供那一段字节）。系统播放器按需读取，支持跳转。
///
/// 地址格式：amslice://local?path=文件路径&offset=起点&length=长度[&wav=1][&ext=flac][&be=1][&stride=2448]
/// - stride：文件里每个扇区实际占的字节（含 96 字节子码时为 2448），只取每扇区前 2352 字节。
/// - wav=1：内容是 44.1kHz、16 位、双声道的原始 PCM，前面补 44 字节 WAV 头。be=1 表示原始数据是高字节在前（需逐采样翻转）。
/// - ext：内容本身是一个音乐文件时，它的扩展名（决定格式）。
/// - codec=ape：内容是 APE 文件解出的 PCM（offset 无用、length 为 PCM 总字节数），前面补 WAV 头；
///   rate、bits、ch、float 给出格式。
public final class SliceAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    public static let scheme = "amslice"
    public let queue = DispatchQueue(label: "amslice")

    let path: String
    let offset: UInt64
    let length: UInt64
    let wav: Bool
    let bigEndian: Bool
    let ext: String
    let stride: UInt64
    let codec: String?
    let rate: Int
    let bits: Int
    let channels: Int
    let isFloat: Bool
    private var handle: FileReader?
    private var ape: APEFile?

    /// 生成地址。
    public static func url(path: String, offset: UInt64, length: UInt64, wav: Bool, ext: String? = nil, bigEndian: Bool = false,
                           stride: Int = 2352) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "local"
        c.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "offset", value: "\(offset)"),
                        URLQueryItem(name: "length", value: "\(length)")]
            + (wav ? [URLQueryItem(name: "wav", value: "1")] : [])
            + (bigEndian ? [URLQueryItem(name: "be", value: "1")] : [])
            + (stride != 2352 ? [URLQueryItem(name: "stride", value: "\(stride)")] : [])
            + (ext.map { [URLQueryItem(name: "ext", value: $0)] } ?? [])
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value,
              let offset = items.first(where: { $0.name == "offset" })?.value.flatMap(UInt64.init),
              let length = items.first(where: { $0.name == "length" })?.value.flatMap(UInt64.init) else { return nil }
        self.path = path
        self.offset = offset
        self.length = length
        wav = items.contains { $0.name == "wav" }
        bigEndian = items.contains { $0.name == "be" }
        ext = items.first(where: { $0.name == "ext" })?.value ?? (wav ? "wav" : "")
        stride = items.first(where: { $0.name == "stride" })?.value.flatMap(UInt64.init) ?? 2352
        codec = items.first(where: { $0.name == "codec" })?.value
        func int(_ name: String, _ fallback: Int) -> Int { items.first(where: { $0.name == name })?.value.flatMap(Int.init) ?? fallback }
        rate = int("rate", 44100)
        bits = int("bits", 16)
        channels = int("ch", 2)
        isFloat = items.contains { $0.name == "float" }
    }

    /// APE 文件当作 WAV 播放的地址。
    public static func apeURL(path: String, file: APEFile) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "local"
        c.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "offset", value: "0"),
                        URLQueryItem(name: "length", value: "\(file.totalBlocks * Int64(file.blockAlign))"),
                        URLQueryItem(name: "wav", value: "1"), URLQueryItem(name: "codec", value: "ape"),
                        URLQueryItem(name: "rate", value: "\(file.sampleRate)"), URLQueryItem(name: "bits", value: "\(file.bitsPerSample)"),
                        URLQueryItem(name: "ch", value: "\(file.channels)")]
            + (file.isFloat ? [URLQueryItem(name: "float", value: "1")] : [])
        return c.url!
    }

    /// 生成可播放的资源；返回的加载器须在播放期间保持存活。
    public static func asset(for url: URL) -> (AVURLAsset, SliceAssetLoader)? {
        guard let loader = SliceAssetLoader(url: url) else { return nil }
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return (asset, loader)
    }

    /// 内容是补了 WAV 头的 PCM。
    public var isWAV: Bool { wav }
    /// 内容本身是音乐文件时的扩展名。
    public var fileExtension: String { ext }

    public var totalLength: UInt64 { length + (wav ? headerSize : 0) }

    /// 超过双声道时用扩展格式写明声道布局。
    var extensible: Bool { channels > 2 }
    var headerSize: UInt64 { extensible ? 68 : 44 }

    /// PCM 的 WAV 头（默认 44.1kHz、16 位、双声道）。
    var wavHeader: Data { Self.wavHeader(rate: rate, bits: bits, channels: channels, isFloat: isFloat, dataLength: length) }

    /// 生成 WAV 头：超过双声道时用扩展格式写明声道布局。
    public static func wavHeader(rate: Int, bits: Int, channels: Int, isFloat: Bool = false, dataLength: UInt64) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let extensible = channels > 2
        let headerSize: UInt64 = extensible ? 68 : 44
        let align = bits / 8 * channels
        let format: UInt16 = isFloat ? 3 : 1
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(truncatingIfNeeded: headerSize - 8 + dataLength))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(extensible ? 40 : 16)
        u16(extensible ? 0xFFFE : format); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * align)); u16(UInt16(align)); u16(UInt16(bits))
        if extensible {
            // 常见布局：4 声道为前后各二，6 声道为 5.1，8 声道为 7.1
            let mask: UInt32 = switch channels { case 4: 0x33; case 6: 0x3F; case 8: 0x63F; default: 0 }
            u16(22); u16(UInt16(bits)); u32(mask)
            u32(UInt32(format)); u32(0x0010_0000); u32(0xAA00_0080); u32(0x719B_3800)
        }
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(truncatingIfNeeded: dataLength))
        return d
    }

    /// 读取虚拟文件中 [start, start+count) 的内容。
    public func bytes(from start: UInt64, count: Int) throws -> Data {
        var out = Data()
        var pos = start, remaining = UInt64(count)
        if wav, pos < headerSize {
            let h = wavHeader
            let take = min(remaining, headerSize - pos)
            out.append(h[Int(pos) ..< Int(pos + take)])
            pos += take; remaining -= take
        }
        guard remaining > 0 else { return out }
        let inner = pos - (wav ? headerSize : 0)
        guard inner < length else { return out }
        let n = min(remaining, length - inner)
        if codec == "ape" {
            if ape == nil { ape = try APEFile(url: URL(fileURLWithPath: path)) }
            let file = ape!, align = UInt64(file.blockAlign)
            let first = inner / align, last = (inner + n + align - 1) / align
            let pcm = try file.read(fromBlock: Int64(first), count: Int(last - first))
            let skip = Int(inner - first * align)
            guard skip < pcm.count else { return out }
            out.append(contentsOf: pcm[skip ..< min(pcm.count, skip + Int(n))])
            return out
        }
        if handle == nil { handle = try FileReader(forReadingFrom: URL(fileURLWithPath: path)) }
        // 高字节在前的原始数据按 2 字节翻转，保证翻转从采样边界开始
        let aligned = bigEndian ? inner & ~1 : inner
        var chunk = try readPayload(from: aligned, count: Int(n + (inner - aligned) + (bigEndian ? 1 : 0)))
        if bigEndian {
            chunk.withUnsafeMutableBytes { p in
                var i = 0
                while i + 1 < p.count { p.swapAt(i, i + 1); i += 2 }
            }
        }
        let skip = Int(inner - aligned)
        out.append(chunk.subdata(in: skip ..< min(chunk.count, skip + Int(n))))
        return out
    }

    /// 读取有效数据：没有子码时直接读；有子码时逐扇区取前 2352 字节。
    private func readPayload(from start: UInt64, count: Int) throws -> Data {
        guard stride != 2352 else {
            try handle!.seek(toOffset: offset + start)
            return try handle!.read(upToCount: count) ?? Data()
        }
        var out = Data()
        var pos = start
        while out.count < count {
            let sectorIndex = pos / 2352, within = pos % 2352
            let take = Int(min(UInt64(count - out.count), 2352 - within))
            try handle!.seek(toOffset: offset + sectorIndex * stride + within)
            guard let d = try handle!.read(upToCount: take), !d.isEmpty else { break }
            out.append(d)
            pos += UInt64(d.count)
        }
        return out
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = (UTType(filenameExtension: ext) ?? .audio).identifier
            info.contentLength = Int64(totalLength)
            info.isByteRangeAccessSupported = true
        }
        if let data = request.dataRequest {
            var pos = UInt64(data.currentOffset != 0 ? data.currentOffset : data.requestedOffset)
            let end = data.requestsAllDataToEndOfResource ? totalLength : min(totalLength, UInt64(data.requestedOffset) + UInt64(data.requestedLength))
            do {
                while pos < end {
                    let n = Int(min(end - pos, 256 * 1024))
                    let chunk = try bytes(from: pos, count: n)
                    guard !chunk.isEmpty else { break }
                    data.respond(with: chunk)
                    pos += UInt64(chunk.count)
                }
                request.finishLoading()
            } catch {
                request.finishLoading(with: error)
            }
        } else {
            request.finishLoading()
        }
        return true
    }
}
