import Foundation

/// 统一错误类别（NFR-01）。模块必须把上游错误转换为这些类别，不把原始响应透传给界面。
public enum MusicErrorCategory: String, Sendable, Codable {
    case notLoggedIn
    case credentialExpired
    case insufficientEntitlement
    case regionOrCopyrightRestricted
    case previewOnly
    case resourceRemoved
    case rateLimited
    case network
    case upstreamChanged
    case parseFailure
    case disk
    case cancelled
    case moduleUnavailable   // 模块被禁用或辅助进程不可用
    case timeout
}

public struct MusicError: Error, Sendable, Hashable {
    public let category: MusicErrorCategory
    public let platform: PlatformID?
    /// 面向用户的说明，必须脱敏。
    public let userMessage: String
    /// 诊断信息，必须脱敏；不得包含 Cookie、票据或临时地址。
    public let diagnostic: String?

    public init(_ category: MusicErrorCategory, platform: PlatformID? = nil,
                userMessage: String, diagnostic: String? = nil) {
        self.category = category
        self.platform = platform
        self.userMessage = userMessage
        self.diagnostic = diagnostic
    }

    /// 是否允许自动重试（NFR-02）：登录失败、权限不足、明确不存在不重试。
    public var isAutomaticallyRetryable: Bool {
        switch category {
        case .network, .rateLimited, .timeout, .moduleUnavailable: true
        default: false
        }
    }
}
