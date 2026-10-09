import Foundation

/// 加密连接上使用的最小 HTTP/1.1。双方都由本项目实现，只支持需要的部分：
/// 请求带 Content-Length；响应带 Content-Length，或无长度、以关闭连接结束（事件流、音频转发）。
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]   // 键为小写
    public var body: Data

    public init(method: String, path: String, query: [String: String] = [:],
                headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    var target: String {
        guard !query.isEmpty else { return path }
        var c = URLComponents()
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return path + "?" + (c.percentEncodedQuery ?? "")
    }

    func serialized() -> Data {
        var head = "\(method) \(target) HTTP/1.1\r\n"
        var headers = self.headers
        headers["content-length"] = String(body.count)
        headers["connection"] = "close"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

public struct HTTPResponseHead: Sendable {
    public var status: Int
    public var headers: [String: String]   // 键为小写
    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    }
    public var contentLength: Int? { headers["content-length"].flatMap { Int($0) } }
}

enum HTTPParseError: Error { case malformed, tooLarge }

enum HTTPParser {
    static let headerTerminator = Data("\r\n\r\n".utf8)
    static let maxHeaderBytes = 64 * 1024

    /// 若缓冲区里已有完整头部，返回头部各行与头部之后的剩余数据。
    static func splitHead(_ buffer: Data) throws -> (lines: [String], rest: Data)? {
        guard let range = buffer.range(of: headerTerminator) else {
            if buffer.count > maxHeaderBytes { throw HTTPParseError.tooLarge }
            return nil
        }
        let headText = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        return (headText.components(separatedBy: "\r\n"), Data(buffer[range.upperBound...]))
    }

    static func headers(_ lines: ArraySlice<String>) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformed }
            result[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func request(lines: [String]) throws -> (method: String, path: String, query: [String: String], headers: [String: String]) {
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { throw HTTPParseError.malformed }
        let target = String(parts[1])
        guard let components = URLComponents(string: target), components.path.hasPrefix("/") else {
            throw HTTPParseError.malformed
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return (String(parts[0]), components.path, query, try headers(lines.dropFirst()))
    }

    static func responseHead(lines: [String]) throws -> HTTPResponseHead {
        let parts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw HTTPParseError.malformed
        }
        return HTTPResponseHead(status: status, headers: try headers(lines.dropFirst()))
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        default: "Status"
        }
    }
}
