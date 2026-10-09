import Foundation

/// 每次模块调用的上下文（§4.4）。取消依赖 Swift Task 取消。
public struct RequestContext: Sendable {
    public let platform: PlatformID
    public let account: AccountID?
    public let region: RegionContext
    public let requestID: UUID
    public let timeout: Duration

    public init(platform: PlatformID, account: AccountID?, region: RegionContext = .unknown,
                requestID: UUID = UUID(), timeout: Duration = .seconds(15)) {
        self.platform = platform
        self.account = account
        self.region = region
        self.requestID = requestID
        self.timeout = timeout
    }
}

/// 不透明分页游标。
public struct PageCursor: Hashable, Sendable, Codable {
    public let opaque: String
    public init(_ opaque: String) { self.opaque = opaque }
}

/// 分页结果：本页 + 后续游标。`nextCursor == nil` 才表示已读完，不得只返回第一页却宣称完整。
public struct Page<Item: Sendable>: Sendable {
    public let items: [Item]
    public let nextCursor: PageCursor?
    /// 平台报告的总数；未知时为 nil。
    public let reportedTotal: Int?

    public init(items: [Item], nextCursor: PageCursor?, reportedTotal: Int? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.reportedTotal = reportedTotal
    }

    public var isLastPage: Bool { nextCursor == nil }
}
