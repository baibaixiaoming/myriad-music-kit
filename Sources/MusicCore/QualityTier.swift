import Foundation

/// 通用音质档位（协议“通用音质档位”一节）：各来源自己的音质名称五花八门，服务器给每个级别标上这个固定档位，
/// 客户端据此统一显示、比较高低，并按用户的“最高音质”换算成各来源的级别。
///
/// 编码为整数（1~8）。用结构体而不是枚举：将来服务器发来不认识的数字也能正常解码，只是显示为“档位 N”。
/// 声道（双声道 / 多声道）与是否空间音频另行标注，不混进档位高低。
public struct QualityTier: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 省流：有损，约 128kbps 及以下
    public static let saver = QualityTier(rawValue: 1)
    /// 标准：有损，约 192kbps
    public static let standard = QualityTier(rawValue: 2)
    /// 高品质：有损，约 320kbps
    public static let high = QualityTier(rawValue: 3)
    /// 无损：CD 规格，16bit/44.1kHz（48kHz 及以下的 16bit 无损都算这一档）
    public static let lossless = QualityTier(rawValue: 4)
    /// 高解析：24bit，48kHz 及以下
    public static let hiRes = QualityTier(rawValue: 5)
    /// 高解析 96：24bit，88.2~96kHz
    public static let hiRes96 = QualityTier(rawValue: 6)
    /// 高解析 192：24bit，176.4kHz 及以上
    public static let hiRes192 = QualityTier(rawValue: 7)
    /// DSD
    public static let dsd = QualityTier(rawValue: 8)

    /// 已定义的全部档位，从低到高。
    public static let all: [QualityTier] = [.saver, .standard, .high, .lossless, .hiRes, .hiRes96, .hiRes192, .dsd]

    /// 中文显示名称（读屏直接读这个）。
    public var displayName: String {
        switch rawValue {
        case 1: "省流"
        case 2: "标准"
        case 3: "高品质"
        case 4: "无损"
        case 5: "高解析"
        case 6: "高解析 96"
        case 7: "高解析 192"
        case 8: "DSD"
        default: "档位 \(rawValue)"
        }
    }

    public var isLossless: Bool { rawValue >= QualityTier.lossless.rawValue }

    public var description: String { displayName }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    // MARK: 按实际格式归档

    /// 已知的无损编码名称（小写）。
    static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "wave", "aif", "aiff", "aifc", "caf", "pcm", "lpcm",
                                              "ape", "wv", "wavpack", "tak", "tta", "cd", "dsd", "dsf", "dff", "dst", "sacd"]

    /// 按文件实际的编码、采样率、位深、码率归档（客户端本机音乐与服务器音乐库共用）。
    /// - Parameters:
    ///   - codec: 编码或扩展名，不分大小写（如 flac、alac、wav、mp3、aac、dsd、dsf）
    ///   - sampleRateHz: 采样率；DSD 为 DSD 采样率（如 2822400）
    ///   - bitDepth: 位深；DSD 为 1；有损格式通常为 nil
    ///   - bitrateKbps: 码率（只对有损格式有意义）
    ///   - lossless: 是否无损；nil 时按编码名称判断
    /// - Returns: 信息不足以判断时为 nil（不猜测）。
    public static func classify(codec: String?, sampleRateHz: Int? = nil, bitDepth: Int? = nil,
                                bitrateKbps: Int? = nil, lossless: Bool? = nil) -> QualityTier? {
        let name = (codec ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("dsd") || ["dsf", "dff", "dst", "sacd"].contains(name) || bitDepth == 1 { return .dsd }
        let isLossless = lossless ?? (losslessCodecs.contains(name) ? true : (name.isEmpty ? nil : false))
        switch isLossless {
        case true?:
            let rate = sampleRateHz ?? 0
            let bits = bitDepth ?? 0
            if rate >= 176_400 { return .hiRes192 }
            if rate >= 88_200 { return .hiRes96 }
            if bits > 16 || rate > 48_000 { return .hiRes }
            return .lossless
        case false?:
            guard let kbps = bitrateKbps, kbps > 0 else { return nil }
            // 档位中点为界：160 以下省流，160~255 标准，256 及以上高品质（AAC 256k 与 MP3 320k 听感相近）
            if kbps >= 256 { return .high }
            if kbps >= 160 { return .standard }
            return .saver
        case nil:
            return nil
        }
    }

    /// 读屏用的完整说明：档位名称，再加上多声道、空间音频（只有确知时才加）。
    public static func spokenName(_ tier: QualityTier?, multichannel: Bool? = nil, spatial: Bool? = nil) -> String? {
        var parts: [String] = []
        if let tier { parts.append(tier.displayName) }
        if multichannel == true { parts.append("多声道") }
        if spatial == true { parts.append("空间音频") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }
}
