import AVFoundation
import Foundation
import Testing
import ProviderKit
@testable import LocalMusic

/// 用程序生成各种格式的光盘镜像（每轨是不同频率的正弦波），检查分轨、文字、字节顺序与播放数据。
@Suite struct CDImageTests {
    static let sector = 2352

    /// 一轨原始音频：`seconds` 秒、频率 `freq` 的正弦波，44.1kHz 16 位双声道。
    static func tone(_ freq: Double, seconds: Int, bigEndian: Bool = false) -> Data {
        var d = Data(capacity: seconds * 176_400)
        for i in 0..<(seconds * 44100) {
            let v = Int16(8000 * sin(2 * .pi * freq * Double(i) / 44100))
            let u = UInt16(bitPattern: v)
            let bytes: [UInt8] = bigEndian ? [UInt8(u >> 8), UInt8(u & 0xFF)] : [UInt8(u & 0xFF), UInt8(u >> 8)]
            d.append(contentsOf: bytes); d.append(contentsOf: bytes)
        }
        return d
    }

    /// 数据轨：每扇区开头是同步码。
    static func dataTrack(sectors: Int) -> Data {
        var d = Data()
        for _ in 0..<sectors { d.append(Data([0] + Array(repeating: 0xFF, count: 10) + [0])); d.append(Data(count: sector - 12)) }
        return d
    }

    static func tempDir() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "am-cd-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// 估计一段 16 位低字节在前 PCM 左声道的频率（过零次数）。
    static func frequency(_ pcm: Data) -> Double {
        var crossings = 0, prev: Int16 = 0, n = 0
        var i = pcm.startIndex
        while i + 3 < pcm.endIndex {
            let v = Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8)
            if (prev < 0) != (v < 0) { crossings += 1 }
            prev = v; n += 1; i += 4
        }
        return Double(crossings) / 2 / (Double(n) / 44100)
    }

    /// 经“虚拟文件”读取器取出一轨，跳过 44 字节 WAV 头，检验内容。
    static func play(_ t: CDImage.Track) throws -> Data {
        let url = SliceAssetLoader.url(path: t.file.path(percentEncoded: false), offset: t.offset, length: t.length, wav: true,
                                       bigEndian: t.bigEndian, stride: t.sectorStride)
        let loader = try #require(SliceAssetLoader(url: url))
        let all = try loader.bytes(from: 0, count: Int(loader.totalLength))
        #expect(all.prefix(4) == Data("RIFF".utf8))
        return all.dropFirst(44)
    }

    @Test func cueWithDataTrackAndPregap() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bin = Self.dataTrack(sectors: 150)
        bin += Self.tone(440, seconds: 3) + Self.tone(1000, seconds: 3)
        try bin.write(to: dir.appending(path: "碟.bin"))
        // 第 1 轨数据（0 秒），第 2 轨音乐从 2 秒开始，第 3 轨预间隙 4 秒、正式 5 秒
        try """
        TITLE "测试专辑"
        PERFORMER "测试歌手"
        FILE "碟.bin" BINARY
          TRACK 01 MODE1/2352
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "第二首"
            INDEX 01 00:02:00
          TRACK 03 AUDIO
            TITLE "第三首"
            INDEX 00 00:04:00
            INDEX 01 00:05:00
        """.write(to: dir.appending(path: "碟.cue"), atomically: true, encoding: .utf8)
        let image = try #require(CDImage.load(dir.appending(path: "碟.cue")))
        #expect(image.title == "测试专辑")
        #expect(image.tracks.map(\.number) == [2, 3])                       // 数据轨跳过
        #expect(image.tracks[0].title == "第二首")
        #expect(abs(image.tracks[0].seconds - 2) < 0.02)                    // 2 秒到第 3 轨的 INDEX 00（4 秒）
        #expect(abs(Self.frequency(try Self.play(image.tracks[0])) - 440) < 10)
        #expect(abs(Self.frequency(try Self.play(image.tracks[1])) - 1000) < 15)
    }

    @Test func detectsBigEndianAudio() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.tone(440, seconds: 4, bigEndian: true).write(to: dir.appending(path: "反序.bin"))
        try "FILE \"反序.bin\" BINARY\n  TRACK 01 AUDIO\n    INDEX 01 00:00:00\n".write(to: dir.appending(path: "反序.cue"), atomically: true, encoding: .utf8)
        let image = try #require(CDImage.load(dir.appending(path: "反序.cue")))
        #expect(image.tracks[0].bigEndian)
        #expect(abs(Self.frequency(try Self.play(image.tracks[0])) - 440) < 10)
    }

    @Test func cloneCDWithCDText() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try (Self.tone(440, seconds: 2) + Self.tone(1000, seconds: 3)).write(to: dir.appending(path: "克隆.img"))
        // CD-Text：标题包（类型 0x80）依次为 专辑、第 1 轨、第 2 轨
        func packs(_ type: UInt8, _ text: [String]) -> [String] {
            let bytes = Array(text.map { Array($0.utf8) + [0] }.joined())
            var out: [String] = [], seq = 0, track = 0
            for start in stride(from: 0, to: bytes.count, by: 12) {
                var chunk = Array(bytes[start..<min(bytes.count, start + 12)])
                chunk += Array(repeating: 0, count: 12 - chunk.count)
                let p = [type, UInt8(track), UInt8(seq), 0] + chunk + [0, 0]
                out.append(p.map { String(format: "%02x", $0) }.joined(separator: " "))
                seq += 1
                track += chunk.filter { $0 == 0 }.count
            }
            return out
        }
        let text = packs(0x80, ["Album", "Song One", "Song Two"]) + packs(0x81, ["Singer"])
        var ccd = "[CloneCD]\nVersion=3\n[Disc]\nTocEntries=5\n"
        ccd += "[CDText]\nEntries=\(text.count)\n" + text.enumerated().map { "Entry \($0.offset)=\($0.element)" }.joined(separator: "\n") + "\n"
        ccd += "[Entry 0]\nSession=1\nPoint=0x01\nControl=0x00\nPLBA=0\n"
        ccd += "[Entry 1]\nSession=1\nPoint=0x02\nControl=0x00\nPLBA=150\n"
        ccd += "[Entry 2]\nSession=1\nPoint=0xa2\nControl=0x00\nPLBA=375\n"
        try ccd.write(to: dir.appending(path: "克隆.ccd"), atomically: true, encoding: .utf8)
        let image = try #require(CDImage.load(dir.appending(path: "克隆.ccd")))
        #expect(image.tracks.map(\.number) == [1, 2])
        #expect(image.title == "Album")
        #expect(image.tracks.map(\.title) == ["Song One", "Song Two"])
        #expect(image.performer == "Singer")
        #expect(abs(image.tracks[1].seconds - 3) < 0.02)
        #expect(abs(Self.frequency(try Self.play(image.tracks[1])) - 1000) < 15)
    }

    @Test func neroImage() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Self.tone(440, seconds: 2), b = Self.tone(1000, seconds: 2)
        var file = a + b
        let chunkStart = UInt64(file.count)
        func be(_ v: UInt64, _ n: Int) -> Data { Data((0..<n).reversed().map { UInt8((v >> (UInt64($0) * 8)) & 0xFF) }) }
        var dao = Data(count: 22)
        dao[20] = 1; dao[21] = 2
        for (start, end) in [(UInt64(0), UInt64(a.count)), (UInt64(a.count), UInt64(a.count + b.count))] {
            var e = Data(count: 12)                                        // ISRC
            e += be(2352, 2) + Data([7, 0]) + Data(count: 2) + be(start, 8) + be(start, 8) + be(end, 8)
            dao += e
        }
        file += Data("DAOX".utf8) + be(UInt64(dao.count), 4) + dao
        file += Data("END!".utf8) + be(0, 4)
        file += Data("NER5".utf8) + be(chunkStart, 8)
        try file.write(to: dir.appending(path: "尼禄.nrg"))
        let image = try #require(CDImage.load(dir.appending(path: "尼禄.nrg")))
        #expect(image.tracks.map(\.number) == [1, 2])
        #expect(abs(Self.frequency(try Self.play(image.tracks[1])) - 1000) < 15)
    }

    @Test func alcoholVersion1() throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Self.tone(440, seconds: 2), b = Self.tone(1000, seconds: 3)
        try (a + b).write(to: dir.appending(path: "酒精.mdf"))
        func le(_ v: UInt64, _ n: Int) -> Data { Data((0..<n).map { UInt8((v >> (UInt64($0) * 8)) & 0xFF) }) }
        var mds = Data("MEDIA DESCRIPTOR".utf8) + Data([1, 3]) + Data(count: 0x50 - 18)
        let session = 0x58, tracksAt = session + 24, extras = tracksAt + 2 * 80
        mds += le(UInt64(session), 4) + Data(count: 4)                      // 0x50：区段信息位置
        var s = Data(count: 24); s[10] = 2
        s.replaceSubrange(20..<24, with: le(UInt64(tracksAt), 4))
        mds += s
        for (i, (offset, sectors)) in [(UInt64(0), a.count / 2352), (UInt64(a.count), b.count / 2352)].enumerated() {
            var t = Data(count: 80)
            t[0] = 0xA9; t[4] = UInt8(i + 1)
            t.replaceSubrange(12..<16, with: le(UInt64(extras + i * 8), 4))
            t.replaceSubrange(16..<18, with: le(2352, 2))
            t.replaceSubrange(40..<48, with: le(offset, 8))
            mds += t
            _ = sectors
        }
        mds += le(0, 4) + le(UInt64(a.count / 2352), 4) + le(0, 4) + le(UInt64(b.count / 2352), 4)
        try mds.write(to: dir.appending(path: "酒精.mds"))
        let image = try #require(CDImage.load(dir.appending(path: "酒精.mds")))
        #expect(image.tracks.map(\.number) == [1, 2])
        #expect(abs(image.tracks[1].seconds - 3) < 0.02)
        #expect(abs(Self.frequency(try Self.play(image.tracks[0])) - 440) < 10)
    }

    /// 数据光盘：用系统工具做一个带中文文件名的 ISO（含 Joliet），列出文件并读出时长。
    @Test func dataDiscWithChineseNames() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let content = dir.appending(path: "内容/专辑", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        do {   // 文件对象释放时才写完，必须在打包前结束
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
            let file = try AVAudioFile(forWriting: content.appending(path: "晴天.m4a"), settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2])
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100 * 3)!
            buf.frameLength = 44100 * 3
            try file.write(from: buf)
        }
        let iso = dir.appending(path: "数据.iso")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["makehybrid", "-iso", "-joliet", "-o", iso.path, dir.appending(path: "内容").path]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(CDImage.load(iso) == nil)                                    // 不是音乐 CD
        let disc = try #require(ISO9660(url: iso))
        #expect(disc.files.map(\.path) == ["专辑/晴天.m4a"])
        let tracks = await LocalMusicLibrary.indexDataDisc(iso, folderID: "测试")
        #expect(tracks.count == 1)
        #expect(tracks.first?.title == "晴天")
        #expect(tracks.first.map { ($0.durationMS ?? 0) > 2500 } == true)
        #expect(tracks.first?.id.hasSuffix("#iso=专辑/晴天.m4a") == true)
    }

    /// 光盘编号按公开算法计算（公开文档里的示例光盘）。
    @Test func discIDMatchesPublishedExample() {
        let toc = DiscTOC(firstTrack: 1, lastTrack: 6, leadOut: 95462, offsets: [150, 15363, 32314, 46592, 63414, 80489])
        #expect(toc.discID == "49HHV7Eb8UKF3aQiNmu1GR8vKTY-")
        #expect(toc.tocQuery == "1+6+95462+150+15363+32314+46592+63414+80489")
    }

    /// 没有歌名的整张 CD 镜像：按光盘目录查到歌名后补上，结果缓存，再次扫描不重复查询。
    @Test func fillsTitlesFromDiscLookup() async throws {
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let music = dir.appending(path: "音乐", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try (Self.tone(440, seconds: 2) + Self.tone(1000, seconds: 3)).write(to: music.appending(path: "无名.bin"))
        try """
        FILE "无名.bin" BINARY
          TRACK 01 AUDIO
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            INDEX 01 00:02:00
        """.write(to: music.appending(path: "无名.cue"), atomically: true, encoding: .utf8)
        let image = try #require(CDImage.load(music.appending(path: "无名.cue")))
        #expect(image.toc == DiscTOC(firstTrack: 1, lastTrack: 2, leadOut: 375 + 150, offsets: [150, 300]))

        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let library = LocalMusicLibrary(paths: AppPaths(root: dir.appending(path: "data", directoryHint: .isDirectory)))
        // 还不能查询时（例如没连服务器）先用“第几轨”；之后能查了，再扫描时补上
        try await library.addFolder(music)
        #expect(try await library.rescan() == 2)
        #expect(await library.allTracks().map(\.title).sorted() == ["第 1 轨", "第 2 轨"])
        await library.setDiscLookup { toc in
            counter.n += 1
            return toc.offsets.count == 2 ? DiscInfo(album: "查到的专辑", artist: "查到的歌手",
                                                    tracks: [.init(number: 1, title: "甲", artist: nil), .init(number: 2, title: "乙", artist: "客串")]) : nil
        }
        #expect(try await library.rescan() == 2)
        #expect(try await library.rescan() == 2)
        #expect(counter.n == 1)
        let tracks = await library.allTracks().sorted { ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0) }
        #expect(tracks.map(\.title) == ["甲", "乙"])
        #expect(tracks.map(\.album) == ["查到的专辑", "查到的专辑"])
        #expect(tracks.map(\.artists) == [["查到的歌手"], ["客串"]])
    }
}

extension CDImage: Equatable {
    public static func == (a: CDImage, b: CDImage) -> Bool { a.tracks == b.tracks && a.title == b.title }
}

@Suite struct RealDiscTests {
    /// 真实文件（只在设置了环境变量时运行）：数据光盘列出文件；普通 WAV 加 CUE 不当作光盘镜像。
    @Test func realFiles() {
        if let iso = ProcessInfo.processInfo.environment["AM_DATA_ISO"] {
            let disc = ISO9660(url: URL(fileURLWithPath: iso))
            print("数据光盘：卷名“\(disc?.volumeName ?? "")”，\(disc?.files.count ?? 0) 个文件，前几个：\(disc?.files.prefix(4).map(\.path) ?? [])")
            #expect((disc?.files.count ?? 0) > 0)
        }
        if let cue = ProcessInfo.processInfo.environment["AM_WAV_CUE"] {
            #expect(CDImage.load(URL(fileURLWithPath: cue)) == nil)
            print("普通整轨 CUE：不当作光盘镜像，按原方式分轨")
        }
    }
}
