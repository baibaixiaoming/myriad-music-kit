import Foundation
import ProviderKit

/// 整张音乐 CD 的镜像（像虚拟光驱加载真碟一样分轨播放）。支持：
/// - CUE + BIN / IMG / ISO 等原始数据文件（CUE 里文件类型为 BINARY 或 MOTOROLA）
/// - CloneCD：CCD + IMG（目录与 CD-Text 在 CCD 里）
/// - Nero：NRG（目录在文件末尾）
/// - Alcohol：MDS + MDF（第 1 版目录；第 2 版目录是加密的，暂不支持）
/// - 没有目录的原始镜像：大小为整数个 2352 字节扇区时当作一整轨
/// 只放音乐轨，数据轨跳过。音乐轨的原始数据是 44.1kHz、16 位、双声道 PCM；字节顺序自动检测。
public struct CDImage: Sendable {
    public struct Track: Sendable, Equatable {
        public let number: Int
        public var title: String?
        public var performer: String?
        /// 数据所在文件、起点（字节）、长度（字节，只算音频部分）。
        public let file: URL
        public let offset: UInt64
        public let length: UInt64
        /// 文件里每个扇区占的字节数（含子码时为 2448），音频部分为前 2352 字节。
        public let sectorStride: Int
        public var bigEndian: Bool
        /// 在原光盘上的起点（扇区，不含开头 150 扇区）；不知道时为 nil。
        public var startLBA: Int? = nil
        public var seconds: Double { Double(length) / 176_400 }
    }

    public var title: String?
    public var performer: String?
    public var tracks: [Track]
    /// 光盘结尾位置（扇区）；目录里有记载时才有。
    public var leadOutLBA: Int? = nil

    /// 光盘目录（联网查歌名用）。各轨位置不全时为 nil。
    public var toc: DiscTOC? {
        let audio = tracks.filter { $0.number >= 1 }.sorted { $0.number < $1.number }
        guard let first = audio.first, let last = audio.last, audio.allSatisfy({ $0.startLBA != nil }) else { return nil }
        let end = leadOutLBA ?? (last.startLBA! + Int(last.length / UInt64(Self.sector)))
        return DiscTOC(firstTrack: first.number, lastTrack: last.number, leadOut: end + 150,
                       offsets: audio.map { $0.startLBA! + 150 })
    }

    static let sector = 2352

    /// 从目录文件（.cue / .ccd / .nrg / .mds）或原始镜像（.iso / .bin / .img）读出音乐轨。不是音乐 CD 时返回 nil。
    public static func load(_ url: URL) -> CDImage? {
        var image: CDImage?
        switch url.pathExtension.lowercased() {
        case "cue": image = fromCue(url)
        case "ccd": image = fromCCD(url)
        case "nrg": image = fromNRG(url)
        case "mds": image = fromMDS(url)
        case "iso", "bin", "img", "raw": image = fromRaw(url)
        default: return nil
        }
        guard var image, !image.tracks.isEmpty else { return nil }
        // 字节顺序：每轨从中间取一段，两种顺序比较“平滑度”
        for i in image.tracks.indices where !image.tracks[i].bigEndian {
            image.tracks[i].bigEndian = detectBigEndian(image.tracks[i])
        }
        return image
    }

    // MARK: CUE

    static func fromCue(_ url: URL) -> CDImage? {
        guard let sheet = CueSheet.load(url) else { return nil }
        let dir = url.deletingLastPathComponent()
        var tracks: [Track] = []
        let byFile = Dictionary(grouping: sheet.tracks, by: \.file)
        var base = 0                                            // 前面各文件的总扇区数（多文件 CUE）
        for (name, list) in byFile.sorted(by: { ($0.value.first?.number ?? 0) < ($1.value.first?.number ?? 0) }) {
            guard let first = list.first, first.fileType == "BINARY" || first.fileType == "MOTOROLA" else { continue }
            let file = dir.appending(path: name)
            guard let size = fileSize(file) else { continue }
            defer { base += Int(size / UInt64(sector)) }
            let sorted = list.sorted { $0.number < $1.number }
            for (i, t) in sorted.enumerated() where t.isAudio {
                // 本轨从 INDEX 01 开始，到下一轨的 INDEX 00（没有则 INDEX 01）为止
                let start = UInt64(t.startSector) * UInt64(sector)
                let end = i + 1 < sorted.count ? UInt64(sorted[i + 1].pregapSector ?? sorted[i + 1].startSector) * UInt64(sector) : size
                guard end > start else { continue }
                tracks.append(Track(number: t.number, title: t.title, performer: t.performer ?? sheet.performer, file: file,
                                    offset: start, length: end - start, sectorStride: sector, bigEndian: first.fileType == "MOTOROLA",
                                    startLBA: base + t.startSector))
            }
            // 隐藏音轨：第 1 轨的 INDEX 01 之前有 4 秒以上内容
            if let t1 = sorted.first, t1.number == 1, t1.isAudio, (t1.pregapSector ?? 0) == 0, t1.startSector > 75 * 4 {
                tracks.insert(Track(number: 0, title: "隐藏音轨", performer: sheet.performer, file: file, offset: 0,
                                    length: UInt64(t1.startSector) * UInt64(sector), sectorStride: sector,
                                    bigEndian: first.fileType == "MOTOROLA"), at: 0)
            }
        }
        return CDImage(title: sheet.title, performer: sheet.performer, tracks: tracks)
    }

    // MARK: CloneCD

    static func fromCCD(_ url: URL) -> CDImage? {
        guard let raw = FileAccess.data(url), let text = String(data: raw, encoding: .isoLatin1) else { return nil }
        let img = url.deletingPathExtension().appendingPathExtension("img")
        guard let size = fileSize(img) else { return nil }
        // 解析 [Entry n] 段：Point 1~99 为各轨起点（PLBA），0xA2 为结尾；Control 第 3 位为 1 表示数据轨
        var entries: [[String: String]] = []
        var cdText: [String] = []
        var current: [String: String]?
        var inCDText = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if let c = current { entries.append(c) }
                current = line.hasPrefix("[Entry") ? [:] : nil
                inCDText = line == "[CDText]"
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if inCDText, key.hasPrefix("entry") { cdText.append(value) }
            current?[key] = value
        }
        if let c = current { entries.append(c) }
        func int(_ s: String?) -> Int? {
            guard let s else { return nil }
            return s.lowercased().hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
        }
        var starts: [(point: Int, lba: Int, data: Bool)] = []
        var leadOut: Int?
        for e in entries {
            guard let point = int(e["point"]), let lba = int(e["plba"]) else { continue }
            let control = int(e["control"]) ?? 0
            if (1...99).contains(point) { starts.append((point, lba, control & 0x04 != 0)) }
            if point == 0xA2 { leadOut = lba }
        }
        starts.sort { $0.point < $1.point }
        let end = leadOut ?? Int(size / UInt64(sector))
        let info = CDText.parse(cdText.map { $0.split(separator: " ").compactMap { UInt8($0, radix: 16) } }.flatMap { $0 })
        var tracks: [Track] = []
        for (i, s) in starts.enumerated() where !s.data {
            let next = i + 1 < starts.count ? starts[i + 1].lba : end
            guard next > s.lba else { continue }
            tracks.append(Track(number: s.point, title: info.titles[s.point], performer: info.performers[s.point] ?? info.performers[0],
                                file: img, offset: UInt64(s.lba) * UInt64(sector), length: UInt64(next - s.lba) * UInt64(sector),
                                sectorStride: sector, bigEndian: false, startLBA: s.lba))
        }
        return CDImage(title: info.titles[0], performer: info.performers[0], tracks: tracks, leadOutLBA: leadOut)
    }

    // MARK: Nero

    static func fromNRG(_ url: URL) -> CDImage? {
        guard let h = try? FileReader(forReadingFrom: url), let size = fileSize(url), size > 12 else { return nil }
        defer { try? h.close() }
        // 新版：文件末尾 12 字节为 “NER5” + 8 字节目录起点；旧版：末尾 8 字节为 “NERO” + 4 字节起点
        guard (try? h.seek(toOffset: size - 12)) != nil, let tail = try? h.read(upToCount: 12) else { return nil }
        var chunkStart: UInt64
        if tail.subdata(in: 0..<4) == Data("NER5".utf8) { chunkStart = tail.be64(4) }
        else if tail.subdata(in: 4..<8) == Data("NERO".utf8) { chunkStart = UInt64(tail.be32(8)) }
        else { return nil }
        guard (try? h.seek(toOffset: chunkStart)) != nil, let chunks = try? h.read(upToCount: Int(size - chunkStart)) else { return nil }
        var pos = 0
        var tracks: [Track] = []
        var text = CDText()
        while pos + 8 <= chunks.count {
            let id = String(data: chunks.subdata(in: pos ..< pos + 4), encoding: .ascii) ?? ""
            let len = Int(chunks.be32(pos + 4))
            let body = chunks.subdata(in: min(chunks.count, pos + 8) ..< min(chunks.count, pos + 8 + len))
            pos += 8 + len
            switch id {
            case "DAOX", "DAOI":
                // 头 22 字节（大小、UPC、目录类型、首轨、末轨），之后每轨 42 字节（DAOX）或 30 字节（DAOI）
                let entry = id == "DAOX" ? 42 : 30
                let first = body.count > 20 ? Int(body[body.startIndex + 20]) : 1
                var p = 22, n = first
                while p + entry <= body.count {
                    let sectorSize = Int(body.be16(p + 12))
                    let mode = Int(body[body.startIndex + p + 14])
                    let index1 = id == "DAOX" ? body.be64(p + 26) : UInt64(body.be32(p + 22))
                    let endOff = id == "DAOX" ? body.be64(p + 34) : UInt64(body.be32(p + 26))
                    // 音乐轨：扇区 2352（无子码）或 2448（含子码）；模式 7 为音乐
                    if mode == 7 || sectorSize == 2352 || sectorSize == 2448, endOff > index1 {
                        let sectors = (endOff - index1) / UInt64(max(sectorSize, 1))
                        tracks.append(Track(number: n, title: nil, performer: nil, file: url, offset: index1,
                                            length: sectors * UInt64(sector), sectorStride: sectorSize, bigEndian: false,
                                            startLBA: Int(index1 / UInt64(max(sectorSize, 1))) - 150))
                    }
                    p += entry; n += 1
                }
            case "CDTX":
                text = CDText.parse([UInt8](body))
            case "END!": pos = chunks.count
            default: break
            }
        }
        for i in tracks.indices {
            tracks[i].title = text.titles[tracks[i].number]
            tracks[i].performer = text.performers[tracks[i].number] ?? text.performers[0]
        }
        return CDImage(title: text.titles[0], performer: text.performers[0], tracks: tracks)
    }

    // MARK: Alcohol

    static func fromMDS(_ url: URL) -> CDImage? {
        guard let d = FileAccess.data(url), d.count > 0x58, d.prefix(16) == Data("MEDIA DESCRIPTOR".utf8),
              d[d.startIndex + 16] == 1 else { return nil }      // 只支持第 1 版（第 2 版目录加密）
        let mdf = url.deletingPathExtension().appendingPathExtension("mdf")
        guard fileSize(mdf) != nil else { return nil }
        let sessionOffset = Int(d.le32(0x50))
        guard sessionOffset + 24 <= d.count else { return nil }
        let blocks = Int(d[d.startIndex + sessionOffset + 10])
        let trackOffset = Int(d.le32(sessionOffset + 20))
        var tracks: [Track] = []
        for b in 0..<blocks {
            let p = trackOffset + b * 80
            guard p + 80 <= d.count else { break }
            let mode = d[d.startIndex + p]
            let point = Int(d[d.startIndex + p + 4])
            guard (1...99).contains(point), mode == 0xA9 else { continue }      // 0xA9 为音乐轨
            let extraOffset = Int(d.le32(p + 12))
            let sectorSize = Int(d.le16(p + 16))
            let startOffset = d.le64(p + 40)
            let length = extraOffset + 8 <= d.count ? UInt64(d.le32(extraOffset + 4)) : 0
            guard length > 0 else { continue }
            tracks.append(Track(number: point, title: nil, performer: nil, file: mdf, offset: startOffset,
                                length: length * UInt64(sector), sectorStride: max(sectorSize, sector), bigEndian: false,
                                startLBA: Int(d.le32(p + 36))))
        }
        return CDImage(title: nil, performer: nil, tracks: tracks)
    }

    // MARK: 没有目录的原始镜像

    static func fromRaw(_ url: URL) -> CDImage? {
        guard let size = fileSize(url), size > UInt64(sector) * 75, size % UInt64(sector) == 0 else { return nil }
        // 数据光盘（第 16 扇区有文件系统标记）不当作音乐
        if let h = try? FileReader(forReadingFrom: url) {
            defer { try? h.close() }
            for off in [UInt64(16 * 2048 + 1), UInt64(16 * 2352 + 16 + 1), UInt64(16 * 2352 + 24 + 1)] {
                try? h.seek(toOffset: off)
                if (try? h.read(upToCount: 5)) == Data("CD001".utf8) { return nil }
            }
            // 原始数据扇区以 12 字节同步码开头：00 FF×10 00
            try? h.seek(toOffset: 0)
            if let head = try? h.read(upToCount: 12), head == Data([0] + Array(repeating: 0xFF, count: 10) + [0]) { return nil }
        }
        return CDImage(title: nil, performer: nil, tracks: [Track(number: 1, title: nil, performer: nil, file: url, offset: 0,
                                                                   length: size, sectorStride: sector, bigEndian: false, startLBA: 0)])
    }

    // MARK: 工具

    static func fileSize(_ url: URL) -> UInt64? { FileAccess.size(url) }

    /// 字节顺序检测：音乐的相邻采样变化平滑，字节顺序弄反后像噪声。取轨中间一段，比较两种顺序下相邻采样差值的大小。
    static func detectBigEndian(_ t: Track) -> Bool {
        guard let h = try? FileReader(forReadingFrom: t.file) else { return false }
        defer { try? h.close() }
        let sectors = t.length / UInt64(sector)
        let mid = sectors / 2
        var samples = Data()
        for s in 0..<min(28, sectors) {
            try? h.seek(toOffset: t.offset + (mid + s) * UInt64(t.sectorStride))
            samples.append((try? h.read(upToCount: sector)) ?? Data())
        }
        guard samples.count > 1000 else { return false }
        func roughness(swap: Bool) -> Double {
            var prev: Int32 = 0, sum = 0.0, amp = 0.0
            var i = samples.startIndex
            while i + 3 < samples.endIndex {
                let a = samples[i], b = samples[i + 1]
                let v = Int32(Int16(bitPattern: swap ? UInt16(a) << 8 | UInt16(b) : UInt16(b) << 8 | UInt16(a)))
                sum += Double(abs(v - prev)); amp += Double(abs(v))
                prev = v
                i += 4                                         // 只看左声道
            }
            return amp > 0 ? sum / amp : 0
        }
        let le = roughness(swap: false), be = roughness(swap: true)
        return be < le * 0.7
    }
}

/// CD-Text：每包 18 字节（类型、轨号、序号、字符位置、12 字节文字、2 字节校验）。类型 0x80 为标题，0x81 为演唱者。
/// 同一类型的文字按轨号依次排列，以 0 分隔（0 轨为专辑）。
struct CDText {
    var titles: [Int: String] = [:]
    var performers: [Int: String] = [:]

    static func parse(_ bytes: [UInt8]) -> CDText {
        var result = CDText()
        var byType: [UInt8: (track: Int, bytes: [UInt8])] = [:]
        var collected: [UInt8: [(Int, [UInt8])]] = [:]
        var p = 0
        while p + 18 <= bytes.count {
            let type = bytes[p], track = Int(bytes[p + 1] & 0x7F)
            guard type == 0x80 || type == 0x81, bytes[p + 3] & 0x80 == 0 else { p += 18; continue }   // 只处理单字节编码块
            var state = byType[type] ?? (track, [])
            if state.bytes.isEmpty { state.track = track }
            for b in bytes[(p + 4)..<(p + 16)] {
                if b == 0 {
                    collected[type, default: []].append((state.track, state.bytes))
                    state = (state.track + 1, [])
                } else {
                    state.bytes.append(b)
                }
            }
            byType[type] = state
            p += 18
        }
        for (type, list) in collected {
            for (track, data) in list where !data.isEmpty {
                let s = String(data: Data(data), encoding: .isoLatin1)
                if type == 0x80 { result.titles[track] = s } else { result.performers[track] = s }
            }
        }
        return result
    }
}

extension Data {
    func le16(_ i: Int) -> UInt16 { self[startIndex + i ..< startIndex + i + 2].reversed().reduce(0) { $0 << 8 | UInt16($1) } }
    func le32(_ i: Int) -> UInt32 { self[startIndex + i ..< startIndex + i + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
    func le64(_ i: Int) -> UInt64 { self[startIndex + i ..< startIndex + i + 8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
    func be16(_ i: Int) -> UInt16 { self[startIndex + i ..< startIndex + i + 2].reduce(0) { $0 << 8 | UInt16($1) } }
    func be32(_ i: Int) -> UInt32 { self[startIndex + i ..< startIndex + i + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func be64(_ i: Int) -> UInt64 { self[startIndex + i ..< startIndex + i + 8].reduce(0) { $0 << 8 | UInt64($1) } }
}
