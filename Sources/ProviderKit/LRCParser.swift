import Foundation

/// 通用 LRC 逐行歌词解析（LYR-06）。处理：
/// - 一行多个时间标签 `[00:01.00][00:30.00]歌词`
/// - 毫秒位数为 2 或 3 位，或没有小数部分
/// - 元信息标签 `[ar:…]`、`[ti:…]`，以及 `[offset:±毫秒]`
/// - 没有时间标签的行：若整份歌词都没有时间标签，按普通文本处理
public enum LRCParser {
    public struct Result: Equatable, Sendable {
        public var lines: [LyricsLine]
        public var metadata: [String: String]
        public var isSynced: Bool
    }

    public static func parse(_ text: String) -> Result {
        var timed: [(Duration, String)] = []
        var plain: [String] = []
        var metadata: [String: String] = [:]
        var offsetMS = 0

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            var stamps: [Duration] = []
            var handledAsMetadata = false
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = parseTimestamp(tag) {
                    stamps.append(time)
                } else if let colon = tag.firstIndex(of: ":") {
                    let key = tag[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = tag[tag.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if key == "offset" { offsetMS = Int(value) ?? 0 } else { metadata[key] = value }
                    handledAsMetadata = true
                } else {
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            let content = rest.trimmingCharacters(in: .whitespaces)
            if !stamps.isEmpty {
                for s in stamps { timed.append((s, content)) }
            } else if !handledAsMetadata {
                plain.append(content)
            }
        }

        if timed.isEmpty {
            // 去掉首尾空行
            let trimmed = plain.drop { $0.isEmpty }.reversed().drop { $0.isEmpty }.reversed()
            return Result(lines: trimmed.map { LyricsLine(text: $0, start: nil, words: nil) },
                          metadata: metadata, isSynced: false)
        }
        // 上游 LRC 规范：offset 为正表示歌词提前显示
        let shift = Duration.milliseconds(-offsetMS)
        let lines = timed
            .map { (max($0.0 + shift, .zero), $0.1) }
            .enumerated()
            .sorted { $0.element.0 == $1.element.0 ? $0.offset < $1.offset : $0.element.0 < $1.element.0 }
            .map { LyricsLine(text: $0.element.1, start: $0.element.0, words: nil) }
        return Result(lines: lines, metadata: metadata, isSynced: true)
    }

    /// `mm:ss`、`mm:ss.xx`、`mm:ss.xxx`、`mm:ss:xx`
    static func parseTimestamp(_ tag: Substring) -> Duration? {
        let parts = tag.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        var secondsPart = parts[1]
        var fraction: Substring = ""
        if let dot = secondsPart.firstIndex(where: { $0 == "." || $0 == ":" }) {
            fraction = secondsPart[secondsPart.index(after: dot)...]
            secondsPart = secondsPart[..<dot]
        }
        guard let seconds = Int(secondsPart), seconds >= 0, seconds < 60 || minutes == 0 else { return nil }
        var ms = 0
        if !fraction.isEmpty {
            guard fraction.allSatisfy(\.isNumber), fraction.count <= 3, let f = Int(fraction) else { return nil }
            ms = fraction.count == 1 ? f * 100 : fraction.count == 2 ? f * 10 : f
        }
        return .milliseconds(minutes * 60_000 + seconds * 1000 + ms)
    }
}
