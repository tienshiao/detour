import Foundation

/// The slice of HTTP/1.1 the automation endpoint speaks (TASK-228.1): enough
/// for MCP's Streamable HTTP transport from Node, Python and curl clients.
/// Pure, so the parsing rules are unit-tested without a socket.
///
/// Requests: a request line, headers, and a body framed by `Content-Length`
/// or `Transfer-Encoding: chunked`. Several requests can follow one another on
/// a connection (keep-alive). Responses always carry `Content-Length`.
nonisolated enum AutomationHTTP {

    /// The largest request the endpoint reads: head plus body. MCP requests
    /// are small; this only bounds what a misbehaving client can make it hold.
    static let maximumRequestSize = 4 * 1024 * 1024

    /// The largest request head (request line and headers).
    static let maximumHeadSize = 64 * 1024

    struct Request: Sendable, Equatable {
        var method: String
        /// The request target without its query string.
        var path: String
        /// Header names lowercased; a repeated header keeps its last value.
        var headers: [String: String]
        var body: Data

        func header(_ name: String) -> String? { headers[name.lowercased()] }

        /// Whether the client asked to close the connection after this response.
        var closesConnection: Bool {
            header("connection")?.lowercased().contains("close") ?? false
        }
    }

    enum ParseError: Error, Equatable, Sendable {
        /// The request line or a header is not HTTP/1.x.
        case malformed(String)
        /// The head or the body exceeds the limits above.
        case tooLarge
        /// A transfer coding other than chunked.
        case unsupportedTransferEncoding
    }

    enum ParseResult: Equatable, Sendable {
        /// Not a whole request yet: read more bytes.
        case incomplete
        /// One request, and how many bytes of the buffer it used.
        case request(Request, consumed: Int)
    }

    private static let headTerminator = Data("\r\n\r\n".utf8)

    /// The head of the first request in `buffer` (its body left empty) and
    /// where the body starts, or nil while the head is incomplete. Lets the
    /// endpoint refuse an unauthorised request before reading its body.
    static func parseHead(_ buffer: Data) throws(ParseError) -> (request: Request, bodyStart: Data.Index)? {
        guard let headEnd = buffer.range(of: headTerminator) else {
            if buffer.count > maximumHeadSize { throw .tooLarge }
            return nil
        }
        if headEnd.lowerBound - buffer.startIndex > maximumHeadSize { throw .tooLarge }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            throw .malformed("request head is not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            throw .malformed("bad request line")
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed("bad header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { throw .malformed("bad header name") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (Request(method: method, path: path, headers: headers, body: Data()), headEnd.upperBound)
    }

    /// Parses the first request in `buffer`.
    static func parse(_ buffer: Data) throws(ParseError) -> ParseResult {
        guard let (head, bodyStart) = try parseHead(buffer) else { return .incomplete }
        var request = head

        if let encoding = request.headers["transfer-encoding"] {
            guard encoding.lowercased() == "chunked" else { throw .unsupportedTransferEncoding }
            guard let (body, end) = try decodeChunked(buffer, from: bodyStart) else {
                if buffer.count > maximumRequestSize { throw .tooLarge }
                return .incomplete
            }
            request.body = body
            return .request(request, consumed: end - buffer.startIndex)
        }

        let length: Int
        if let value = request.headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { throw .malformed("bad Content-Length") }
            length = parsed
        } else {
            length = 0
        }
        // Subtracted, not added: a Content-Length near Int.max must be
        // refused, not overflow (which traps, before any authorisation).
        if length > maximumRequestSize - (bodyStart - buffer.startIndex) { throw .tooLarge }
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        request.body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .request(request, consumed: bodyStart + length - buffer.startIndex)
    }

    /// The decoded body and the index just past its last chunk (and trailers),
    /// or nil while the chunked body is incomplete.
    private static func decodeChunked(_ buffer: Data, from start: Data.Index) throws(ParseError) -> (Data, Data.Index)? {
        let lineEnd = Data("\r\n".utf8)
        var body = Data()
        var index = start
        while true {
            guard let sizeEnd = buffer.range(of: lineEnd, in: index..<buffer.endIndex) else { return nil }
            guard let sizeLine = String(data: buffer[index..<sizeEnd.lowerBound], encoding: .ascii) else {
                throw .malformed("bad chunk size")
            }
            let sizeField = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                throw .malformed("bad chunk size")
            }
            index = sizeEnd.upperBound
            if size == 0 {
                // Trailers, if any, then the blank line that ends the body.
                while true {
                    guard let trailerEnd = buffer.range(of: lineEnd, in: index..<buffer.endIndex) else { return nil }
                    let isBlank = trailerEnd.lowerBound == index
                    index = trailerEnd.upperBound
                    if isBlank { return (body, index) }
                }
            }
            // Subtracted, not added: a chunk size near Int.max must not overflow.
            if size > maximumRequestSize - body.count { throw .tooLarge }
            guard buffer.endIndex - index >= size + 2 else { return nil }
            body.append(buffer[index..<(index + size)])
            index += size
            guard buffer[index..<(index + 2)] == lineEnd else { throw .malformed("chunk not terminated") }
            index += 2
        }
    }

    // MARK: Responses

    struct Response: Sendable, Equatable {
        var status: Int
        var headers: [(String, String)]
        var body: Data

        init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        static func == (lhs: Response, rhs: Response) -> Bool {
            lhs.status == rhs.status && lhs.body == rhs.body
                && lhs.headers.map { "\($0.0): \($0.1)" } == rhs.headers.map { "\($0.0): \($0.1)" }
        }

        func header(_ name: String) -> String? {
            headers.last { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        /// A JSON body with `Content-Type: application/json`.
        static func json(_ value: JSONValue, status: Int = 200, headers: [(String, String)] = []) -> Response {
            Response(status: status, headers: [("Content-Type", "application/json")] + headers,
                     body: value.serialized())
        }

        /// A short plain-text body, for refusals a person may read in a log.
        static func text(_ message: String, status: Int, headers: [(String, String)] = []) -> Response {
            Response(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers,
                     body: Data((message + "\n").utf8))
        }
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    /// The bytes of `response`, with `Content-Length` and, when asked, a
    /// `Connection: close`.
    static func serialize(_ response: Response, closing: Bool) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reasonPhrase(response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        if closing { head += "Connection: close\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }
}
