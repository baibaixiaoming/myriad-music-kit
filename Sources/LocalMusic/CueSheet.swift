import Foundation
import ProviderKit

/// CUE 分轨表：一个整轨音频文件（FLAC、WAV、APE 等）里各首歌的起点与信息。
/// 支持常见写法：PERFORMER、TITLE、REM DATE、FILE、TRACK、INDEX 01（分:秒:帧，每秒 75 帧）。
/// 文件编码依次尝试 UTF-8、GB18030（简体中文常见）、Big5、Shift_JIS。
struct CueSheet: Equatable {
    struct Track: Equatable {
        var number: Int
        var title: String?
        var performer: String?
        /// 起点（毫秒），取 INDEX 01。
        var startMS: Int
        /// 所在的音频文件名（CUE 中 FILE 的原文）。
        var file: String
        /// FILE 行的类型（WAVE、BINARY、MOTOROLA 等）。
        var fileType: String = ""
        /// TRACK 行的类型（AUDIO、MODE1/2352 等）。
        var type: String = "AUDIO"
        /// INDEX 00（预间隙起点），以扇区计（每秒 75 个）。
        var pregapSector: Int?
        /// INDEX 01，以扇区计。
        var startSector: Int = 0
        var isAudio: Bool { type.uppercased() == "AUDIO" }
    }

    var title: String?
    var performer: String?
    var date: String?
    /// 抓轨软件写的“REM DISCNUMBER”“REM TOTALDISCS”。
    var discNumber: Int?
    var discTotal: Int?
    var tracks: [Track] = []

    static func load(_ url: URL) -> CueSheet? {
        guard let data = FileAccess.data(url) else { return nil }
        let encodings: [String.Encoding] = [
            .utf8,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            .shiftJIS,
        ]
        for e in encodings {
            if let text = String(data: data, encoding: e) { return parse(text) }
        }
        return nil
    }

    static func parse(_ text: String) -> CueSheet? {
        var sheet = CueSheet()
        var file: String?
        var fileType = ""
        var current: Track?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            guard !line.isEmpty else { continue }
            let (keyword, rest) = split(line)
            switch keyword.uppercased() {
            case "FILE":
                file = unquote(fileName(rest))
                fileType = rest.split(separator: " ").last.map { String($0).uppercased() } ?? ""
            case "TRACK":
                if let t = current { sheet.tracks.append(t) }
                let parts = rest.split(separator: " ")
                let number = Int(parts.first ?? "") ?? sheet.tracks.count + 1
                current = Track(number: number, startMS: -1, file: file ?? "", fileType: fileType,
                                type: parts.count > 1 ? String(parts[1]) : "AUDIO")
            case "TITLE":
                if current != nil { current?.title = unquote(rest) } else { sheet.title = unquote(rest) }
            case "PERFORMER":
                if current != nil { current?.performer = unquote(rest) } else { sheet.performer = unquote(rest) }
            case "REM":
                let (sub, value) = split(rest)
                switch sub.uppercased() {
                case "DATE": sheet.date = unquote(value)
                case "DISCNUMBER": sheet.discNumber = Int(unquote(value).split(separator: "/").first ?? "")
                case "TOTALDISCS", "DISCTOTAL": sheet.discTotal = Int(unquote(value))
                default: break
                }
            case "INDEX":
                let parts = rest.split(separator: " ")
                if parts.count == 2, parts[0] == "01", let ms = timeMS(String(parts[1])) {
                    current?.startMS = ms
                    current?.startSector = sectors(String(parts[1])) ?? 0
                }
                if parts.count == 2, parts[0] == "00" { current?.pregapSector = sectors(String(parts[1])) }
            default: break
            }
        }
        if let t = current { sheet.tracks.append(t) }
        sheet.tracks.removeAll { $0.startMS < 0 }
        return sheet.tracks.isEmpty ? nil : sheet
    }

    /// FILE 行：去掉末尾的类型（WAVE、MP3 等）。
    static func fileName(_ rest: String) -> String {
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\""), let end = trimmed.dropFirst().firstIndex(of: "\"") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
        }
        return trimmed.split(separator: " ").dropLast().joined(separator: " ")
    }

    static func split(_ line: String) -> (String, String) {
        guard let space = line.firstIndex(of: " ") else { return (line, "") }
        return (String(line[..<space]), String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces))
    }

    static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return t
    }

    /// 分:秒:帧 → 扇区数（每秒 75 个）。
    static func sectors(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0] * 60 + p[1]) * 75 + p[2]
    }

    /// 分:秒:帧（每秒 75 帧）→ 毫秒。
    static func timeMS(_ s: String) -> Int? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return (p[0] * 60 + p[1]) * 1000 + p[2] * 1000 / 75
    }
}
