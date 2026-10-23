import Foundation

struct SSEEvent: Sendable {
    var event: String?
    var data: String
}

struct HTTPError: LocalizedError, Sendable {
    let status: Int
    let body: String
    var errorDescription: String? {
        let msg = JSON.parse(body).flatMap { j -> String? in
            j["error"]?["message"]?.string ?? j["error"]?.string ?? j["message"]?.string
                ?? j["error"]?[0]?["message"]?.string ?? j[0]?["error"]?["message"]?.string
        } ?? String(body.prefix(600))
        return "HTTP \(status): \(msg)"
    }
}

/// Server‑sent‑events client built on a data delegate so chunks are parsed as they arrive
/// (much cheaper than iterating `AsyncBytes` byte by byte).
final class SSEClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// MYAITEACHER_TRACE_SSE=1 prints every raw event to stderr (provider debugging).
    static let trace = ProcessInfo.processInfo.environment["MYAITEACHER_TRACE_SSE"] == "1"
    private var buffer = Data()
    private var errorBody = Data()
    private var status = 0
    private var eventName: String?
    private var dataLines: [String] = []
    private let continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation
    private var isJSONBody = false

    private init(continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    /// Parses chunks as if they had arrived from the network (tests, replaying captured streams).
    static func parse(_ chunks: [Data]) async -> [SSEEvent] {
        let (stream, cont) = AsyncThrowingStream<SSEEvent, Error>.makeStream()
        let c = SSEClient(continuation: cont)
        c.status = 200
        for d in chunks { c.buffer.append(d); c.processLines() }
        c.buffer.append(0x0A); c.processLines(final: true); c.flushEvent(); cont.finish()
        var out: [SSEEvent] = []
        do { for try await e in stream { out.append(e) } } catch {}
        return out
    }

    /// One session for every stream, so a lesson's steps (and parallel sub-agents) reuse the provider's warm HTTP/2
    /// connection instead of paying a new TCP + TLS handshake on each request. Each task carries its own `SSEClient` as
    /// its task delegate; the session has none.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120   // silence limit; providers send keep-alives while thinking
        config.timeoutIntervalForResource = 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 8
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1   // a task's callbacks arrive in order; parsing a chunk takes microseconds
        queue.qualityOfService = .userInitiated
        return URLSession(configuration: config, delegate: nil, delegateQueue: queue)
    }()

    static func stream(_ request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let client = SSEClient(continuation: continuation)
            let task = session.dataTask(with: request)
            task.delegate = client
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        status = http?.statusCode ?? 200
        let ct = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        isJSONBody = ct.contains("application/json") && !ct.contains("stream")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if status >= 400 || isJSONBody { errorBody.append(data); return }
        buffer.append(data)
        processLines()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { continuation.finish(); return }
            continuation.finish(throwing: error); return
        }
        if status >= 400 {
            continuation.finish(throwing: HTTPError(status: status, body: String(decoding: errorBody, as: UTF8.self)))
            return
        }
        if isJSONBody {
            // Non-streaming JSON reply (some proxies ignore stream=true, or return an error object).
            let body = String(decoding: errorBody, as: UTF8.self)
            if let j = JSON.parse(body), j["error"] != nil, j["choices"] == nil, j["content"] == nil {
                continuation.finish(throwing: HTTPError(status: status, body: body)); return
            }
            continuation.yield(SSEEvent(event: "__json__", data: body))
            continuation.finish(); return
        }
        buffer.append(0x0A)
        processLines(final: true)
        flushEvent()
        continuation.finish()
    }

    /// Bytes of the unfinished last line already searched for a line end (so a long line isn't rescanned per chunk).
    private var scanned = 0

    /// Splits complete lines (LF, CRLF or CR) out of the buffer. Linear: each byte is looked at once and the buffer is
    /// trimmed once per call, so one huge line or thousands of small events cost O(bytes).
    private func processLines(final: Bool = false) {
        var lines: [String] = []
        var consumed = 0, resume = 0
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let n = raw.count
            var lineStart = 0, i = scanned
            while i < n {
                let b = raw[i]
                if b == 0x0A || b == 0x0D {
                    if b == 0x0D && i + 1 == n && !final { break }   // a CRLF may be split across chunks
                    lines.append(String(decoding: UnsafeRawBufferPointer(rebasing: raw[lineStart..<i]), as: UTF8.self))
                    i += (b == 0x0D && i + 1 < n && raw[i + 1] == 0x0A) ? 2 : 1
                    lineStart = i
                } else {
                    i += 1
                }
            }
            consumed = lineStart; resume = i - lineStart
        }
        if consumed > 0 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + consumed)) }
        scanned = resume
        for l in lines { handle(line: l) }
    }

    private func handle(line: String) {
        if line.isEmpty { flushEvent(); return }
        if line.hasPrefix(":") { return }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line); value = ""
        }
        switch field {
        case "data": dataLines.append(String(value))
        case "event": eventName = String(value)
        default: break
        }
    }

    private func flushEvent() {
        guard !dataLines.isEmpty else { eventName = nil; return }
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        continuation.yield(SSEEvent(event: eventName, data: data))
        eventName = nil
    }
}
