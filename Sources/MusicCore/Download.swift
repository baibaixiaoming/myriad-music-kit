import Foundation

/// 音质以平台实际返回为准；未知参数保持 nil（DL-07、PLAY-09）。
public struct AudioQuality: Hashable, Sendable, Codable {
    /// 平台给出的名称原文，如“SQ 无损”。
    public let platformLabel: String
    /// 平台内部的音质标识，用于固定下载任务（DL-12）。
    public let platformQualityKey: String
    public let codec: String?
    public let bitrateKbps: Int?
    public let sampleRateHz: Int?
    public let bitDepth: Int?
    public let isLosslessClaimedByPlatform: Bool?
    public let estimatedSizeBytes: Int64?
    /// 通用音质档位（可选；旧服务器不发）。见 `QualityTier`。
    public var tier: QualityTier?
    /// 多声道（true）或双声道（false）；未知为 nil。
    public var multichannel: Bool?
    /// 是否空间音频（如杜比全景声）；未知为 nil。
    public var spatial: Bool?

    public init(platformLabel: String, platformQualityKey: String, codec: String? = nil,
                bitrateKbps: Int? = nil, sampleRateHz: Int? = nil, bitDepth: Int? = nil,
                isLosslessClaimedByPlatform: Bool? = nil, estimatedSizeBytes: Int64? = nil,
                tier: QualityTier? = nil, multichannel: Bool? = nil, spatial: Bool? = nil) {
        self.tier = tier
        self.multichannel = multichannel
        self.spatial = spatial
        self.platformLabel = platformLabel
        self.platformQualityKey = platformQualityKey
        self.codec = codec
        self.bitrateKbps = bitrateKbps
        self.sampleRateHz = sampleRateHz
        self.bitDepth = bitDepth
        self.isLosslessClaimedByPlatform = isLosslessClaimedByPlatform
        self.estimatedSizeBytes = estimatedSizeBytes
    }
}

extension AudioQuality {
    /// 按本身的编码、采样率、位深、码率归出的档位（不看 `tier` 字段）。
    public var classifiedTier: QualityTier? {
        QualityTier.classify(codec: codec, sampleRateHz: sampleRateHz, bitDepth: bitDepth, bitrateKbps: bitrateKbps,
                             lossless: isLosslessClaimedByPlatform == true ? true : nil)
    }

    /// 补上档位：已有就保留；否则用给定的（例如所用级别标注的档位）；再没有就按格式归档。
    public func fillingTier(_ fallback: QualityTier? = nil) -> AudioQuality {
        var q = self
        if q.tier == nil { q.tier = fallback ?? classifiedTier }
        return q
    }
}

/// 一个已确认可下载的候选来源（DL-05）。
public struct DownloadCandidate: Hashable, Sendable {
    public let unifiedTrack: UnifiedTrackID
    public let source: PlatformResourceRef
    public let account: AccountID?
    public let assessment: CapabilityAssessment
}

/// 下载任务状态（DL-13）。
public enum DownloadTaskState: Hashable, Sendable, Codable {
    case waiting
    case preparing
    case downloading(received: Int64, total: Int64?)   // total 未知时不编造百分比
    case processing
    case completed(fileURL: URL)
    case cancelled
    case failed(MusicErrorCategory, message: String)
}

/// 用户确认后才创建的持久化任务。固定版本、平台、账号、音质与保存位置（DL-12）。
public struct DownloadTaskRecord: Hashable, Sendable, Codable {
    public let id: UUID
    public let unifiedTrack: UnifiedTrackID
    public let source: PlatformResourceRef
    public let account: AccountID?
    public let quality: AudioQuality
    public let destinationDirectory: URL
    public let createdAt: Date
    public var state: DownloadTaskState
}
