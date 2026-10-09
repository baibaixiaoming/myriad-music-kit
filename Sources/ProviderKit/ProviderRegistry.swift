import Foundation

/// 受控模块注册表（MOD-03）。上层按能力协议查询模块，不按平台写分支（§18、TEST-18）。
public final class ProviderRegistry: Sendable {
    public let providers: [any MusicProvider]
    private let disabled: Set<PlatformID>

    public init(providers: [any MusicProvider], disabled: Set<PlatformID> = []) {
        var seen = Set<PlatformID>()
        for p in providers {
            precondition(seen.insert(p.descriptor.platform).inserted,
                         "重复注册的平台标识：\(p.descriptor.platform)")
        }
        self.providers = providers
        self.disabled = disabled
    }

    public var descriptors: [ProviderDescriptor] { providers.map(\.descriptor) }

    public func provider(for platform: PlatformID) -> (any MusicProvider)? {
        providers.first { $0.descriptor.platform == platform }
    }

    public func isEnabled(_ platform: PlatformID) -> Bool { !disabled.contains(platform) }

    /// 返回已启用、遵循能力协议、且描述信息中该能力已达到“已实现”的模块。
    public func enabled<P>(_: P.Type, gatedBy capability: Capability? = nil) -> [P] {
        providers.compactMap { provider in
            guard isEnabled(provider.descriptor.platform) else { return nil }
            if let capability, !provider.descriptor.mayExpose(capability) { return nil }
            return provider as? P
        }
    }

    public var searchers: [any CatalogSearching] {
        enabled((any CatalogSearching).self).filter { searcher in
            searcher.supportedSearchKinds.contains { searcher.descriptor.mayExpose(.search($0)) }
        }
    }

    public var lyricsProviders: [any LyricsProviding] { enabled((any LyricsProviding).self) }
    public var downloadSources: [any DownloadSourcing] {
        enabled((any DownloadSourcing).self, gatedBy: .exportAudioFile)
    }
}
