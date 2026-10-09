import Foundation

/// HTTP Range 请求头的解析（只取第一段）：bytes=起-止、bytes=起-（开放结尾）、bytes=-末尾长度。
enum ByteRange: Equatable {
    /// 没有 Range 或写法不认识：回整个文件（200）。
    case whole
    /// 闭区间 [start, end]（206）。
    case partial(start: Int64, end: Int64)
    /// 范围在文件之外（416）。
    case unsatisfiable

    static func parse(_ header: String?, length: Int64) -> ByteRange {
        guard let header else { return .whole }
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes=") else { return .whole }
        let first = text.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = first.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return .whole }
        if parts[0].isEmpty {
            // bytes=-N：最后 N 个字节
            guard let n = Int64(parts[1]), n >= 0 else { return .whole }
            guard n > 0, length > 0 else { return .unsatisfiable }
            return .partial(start: max(0, length - n), end: length - 1)
        }
        guard let start = Int64(parts[0]), start >= 0 else { return .whole }
        var end = length - 1
        if !parts[1].isEmpty {
            guard let e = Int64(parts[1]), e >= start else { return .whole }
            end = min(end, e)
        }
        guard start < length else { return .unsatisfiable }
        return .partial(start: start, end: end)
    }
}
