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

    static func stream(_ request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let client = SSEClient(continuation: continuation)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 3600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            let session = URLSession(configuration: config, delegate: client, delegateQueue: queue)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
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
        defer { session.finishTasksAndInvalidate() }
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
        processLines()
        flushEvent()
        continuation.finish()
    }

    private func processLines() {
        while let nl = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line: line)
        }
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
