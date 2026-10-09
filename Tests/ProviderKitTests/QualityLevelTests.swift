import Foundation
import Testing
@testable import ProviderKit

@Suite struct QualityLevelTests {
    let levels = [
        StreamQualityLevel(key: "a", label: "A", tier: .saver),
        StreamQualityLevel(key: "b", label: "B", tier: .standard),
        StreamQualityLevel(key: "c", label: "C", tier: .high),
        StreamQualityLevel(key: "d", label: "D", tier: .lossless),
        StreamQualityLevel(key: "e", label: "E", tier: .hiRes),
    ]

    @Test func picksHighestNotAboveCap() {
        #expect(StreamQualityLevel.best(in: levels, notAbove: .dsd)?.key == "e")
        #expect(StreamQualityLevel.best(in: levels, notAbove: .hiRes96)?.key == "e")
        #expect(StreamQualityLevel.best(in: levels, notAbove: .lossless)?.key == "d")
        #expect(StreamQualityLevel.best(in: levels, notAbove: .high)?.key == "c")
        #expect(StreamQualityLevel.best(in: levels, notAbove: .saver)?.key == "a")
    }

    @Test func sameTierTakesLaterAndAllAboveTakesLowest() {
        let two = [StreamQualityLevel(key: "m128", label: "", tier: .saver),
                   StreamQualityLevel(key: "a96", label: "", tier: .saver),
                   StreamQualityLevel(key: "flac", label: "", tier: .lossless)]
        #expect(StreamQualityLevel.best(in: two, notAbove: .high)?.key == "a96")
        let hi = [StreamQualityLevel(key: "x", label: "", tier: .hiRes), StreamQualityLevel(key: "y", label: "", tier: .lossless)]
        #expect(StreamQualityLevel.best(in: hi, notAbove: .saver)?.key == "y")
    }

    @Test func untaggedLevelsAndSpatialAreSkipped() {
        #expect(StreamQualityLevel.best(in: [StreamQualityLevel(key: "x", label: "X")], notAbove: .lossless) == nil)
        let withSpatial = levels + [StreamQualityLevel(key: "atmos", label: "全景声", tier: .lossless, multichannel: true, spatial: true)]
        #expect(StreamQualityLevel.best(in: withSpatial, notAbove: .lossless)?.key == "d")
    }

    @Test func oldAndNewDescriptorsDecode() throws {
        let old = #"{"key":"k","label":"标准"}"#
        let level = try JSONDecoder().decode(StreamQualityLevel.self, from: Data(old.utf8))
        #expect(level.tier == nil && level.multichannel == nil)
        let d = ProviderDescriptor(platform: PlatformID("3"), displayName: "来源", moduleVersion: "1",
                                   integration: .communityAPI, accountRequirement: .none, capabilities: [])
        var withRole = d
        withRole.role = .musicLibrary
        withRole.streamLevels = levels
        let back = try JSONDecoder().decode(ProviderDescriptor.self, from: JSONEncoder().encode(withRole))
        #expect(back.role == .musicLibrary)
        #expect(back.streamLevels.map(\.tier) == levels.map(\.tier))
        // 旧服务器：没有 role
        #expect(try JSONDecoder().decode(ProviderDescriptor.self, from: JSONEncoder().encode(d)).role == nil)
        // 不认识的用途也能解码
        let text = String(decoding: try JSONEncoder().encode(withRole), as: UTF8.self).replacingOccurrences(of: "musicLibrary", with: "somethingNew")
        #expect(try JSONDecoder().decode(ProviderDescriptor.self, from: Data(text.utf8)).role?.rawValue == "somethingNew")
    }
}
