import Foundation
import Testing
@testable import MusicCore

@Suite struct QualityTierTests {
    @Test func namesAndOrder() {
        #expect(QualityTier.all.map(\.displayName) == ["省流", "标准", "高品质", "无损", "高解析", "高解析 96", "高解析 192", "DSD"])
        #expect(QualityTier.all.map(\.rawValue) == Array(1...8))
        #expect(QualityTier.saver < .dsd)
        #expect(QualityTier(rawValue: 9).displayName == "档位 9")
    }

    @Test func classifiesLosslessBySampleRateAndDepth() {
        #expect(QualityTier.classify(codec: "flac", sampleRateHz: 44100, bitDepth: 16) == .lossless)
        #expect(QualityTier.classify(codec: "FLAC", sampleRateHz: 48000, bitDepth: 16) == .lossless)
        #expect(QualityTier.classify(codec: "alac", sampleRateHz: 48000, bitDepth: 24) == .hiRes)
        #expect(QualityTier.classify(codec: "wav", sampleRateHz: 44100, bitDepth: 24) == .hiRes)
        #expect(QualityTier.classify(codec: "flac", sampleRateHz: 88200, bitDepth: 24) == .hiRes96)
        #expect(QualityTier.classify(codec: "flac", sampleRateHz: 96000, bitDepth: 24) == .hiRes96)
        #expect(QualityTier.classify(codec: "aiff", sampleRateHz: 176400, bitDepth: 24) == .hiRes192)
        #expect(QualityTier.classify(codec: "wav", sampleRateHz: 384000, bitDepth: 32) == .hiRes192)
        #expect(QualityTier.classify(codec: "ape", sampleRateHz: 44100, bitDepth: 16) == .lossless)
        #expect(QualityTier.classify(codec: "cd", sampleRateHz: 44100, bitDepth: 16) == .lossless)
        // 只知道是无损、不知道采样率：按 CD 规格算
        #expect(QualityTier.classify(codec: "flac") == .lossless)
        #expect(QualityTier.classify(codec: "m4a", lossless: true) == .lossless)
    }

    @Test func classifiesDSD() {
        #expect(QualityTier.classify(codec: "dsd", sampleRateHz: 2_822_400, bitDepth: 1) == .dsd)
        #expect(QualityTier.classify(codec: "dsf") == .dsd)
        #expect(QualityTier.classify(codec: "DSD128") == .dsd)
        #expect(QualityTier.classify(codec: "dff", sampleRateHz: 5_644_800) == .dsd)
    }

    @Test func classifiesLossyByBitrate() {
        #expect(QualityTier.classify(codec: "mp3", bitrateKbps: 128) == .saver)
        #expect(QualityTier.classify(codec: "aac", bitrateKbps: 96) == .saver)
        #expect(QualityTier.classify(codec: "mp3", bitrateKbps: 192) == .standard)
        #expect(QualityTier.classify(codec: "aac", bitrateKbps: 256) == .high)
        #expect(QualityTier.classify(codec: "mp3", bitrateKbps: 320) == .high)
        // 码率不明的有损文件、什么都不知道：不猜
        #expect(QualityTier.classify(codec: "mp3") == nil)
        #expect(QualityTier.classify(codec: nil) == nil)
    }

    @Test func spokenNameAddsChannelsOnlyWhenKnown() {
        #expect(QualityTier.spokenName(.lossless) == "无损")
        #expect(QualityTier.spokenName(.dsd, multichannel: true) == "DSD，多声道")
        #expect(QualityTier.spokenName(.high, multichannel: false, spatial: true) == "高品质，空间音频")
        #expect(QualityTier.spokenName(nil) == nil)
    }

    @Test func audioQualityTierIsOptionalAndTolerant() throws {
        // 旧服务器不发档位
        let old = #"{"platformLabel":"无损","platformQualityKey":"lossless","codec":"flac"}"#
        let q = try JSONDecoder().decode(AudioQuality.self, from: Data(old.utf8))
        #expect(q.tier == nil)
        #expect(q.fillingTier().tier == .lossless)
        #expect(q.fillingTier(.hiRes).tier == .hiRes)
        // 新服务器发了将来才有的档位：照样能解码
        let future = #"{"platformLabel":"x","platformQualityKey":"x","tier":12,"multichannel":true}"#
        let f = try JSONDecoder().decode(AudioQuality.self, from: Data(future.utf8))
        #expect(f.tier?.rawValue == 12)
        #expect(f.multichannel == true)
        // 编码为整数
        let encoded = String(decoding: try JSONEncoder().encode(AudioQuality(platformLabel: "a", platformQualityKey: "b", tier: .hiRes96)), as: UTF8.self)
        #expect(encoded.contains("\"tier\":6"))
    }
}

@Suite struct PlatformIDTranslationTests {
    struct Box: Codable, Equatable {
        let ref: PlatformResourceRef
        let list: [PlatformID]
    }

    @Test func translatesAtTheBoundaryOnly() throws {
        let t = PlatformIDTranslation(internalToWire: ["alpha": "1", "beta": "2"])
        let box = Box(ref: PlatformResourceRef(platform: PlatformID("alpha"), kind: .track, platformID: "42"),
                      list: [PlatformID("beta"), PlatformID("local")])
        // 没有转换表：原样
        let plain = String(decoding: try JSONEncoder().encode(box), as: UTF8.self)
        #expect(plain.contains("\"alpha\"") && plain.contains("\"beta\""))

        let encoder = JSONEncoder()
        encoder.userInfo[.platformIDTranslation] = t
        let wire = try encoder.encode(box)
        let text = String(decoding: wire, as: UTF8.self)
        #expect(!text.contains("alpha") && !text.contains("beta"))
        #expect(text.contains("\"1\"") && text.contains("\"2\"") && text.contains("\"local\""))

        // 客户端（没有转换表）看到的就是槽位号
        let seen = try JSONDecoder().decode(Box.self, from: wire)
        #expect(seen.ref.platform.rawValue == "1")

        // 服务器收到槽位号 → 内部名；收到旧客户端发的内部名 → 原样
        let decoder = JSONDecoder()
        decoder.userInfo[.platformIDTranslation] = t
        #expect(try decoder.decode(Box.self, from: wire) == box)
        #expect(try decoder.decode(Box.self, from: JSONEncoder().encode(box)) == box)
        #expect(t.toInternal("2") == "beta")
        #expect(t.toWire("unknown") == "unknown")
    }
}
