import Foundation
import os
import Testing
@testable import TraceSDK

/// A fresh directory for one test, so no test reads or writes the real Application Support and no two tests share
/// a file. Left for the system to clear: it holds only synthetic ids.
func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "trace-sdk-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Reads the backup exclusion back from disk through a URL that has never cached it, so the answer is what the file
/// says, not what a setter remembered.
func isExcludedFromBackup(_ file: URL) throws -> Bool? {
    var fresh = URL(filePath: file.path)
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
}

/// What the SDK logged during one test.
///
/// **A redacted line is a failed test.** The log strips anything identity shaped at the sink, so a line that comes
/// out redacted means a call site tried to log an identity. Nothing leaked, and that is exactly why it has to fail
/// here: the leak was stopped by the net, and the next one might be a shape the net does not know. Every transport
/// and consent gate test logs through this, so normal running proves it logs no identity at all.
struct LogCapture: Sendable {

    private let captured = OSAllocatedUnfairLock(initialState: [String]())
    private let failOnRedaction: Bool

    init(failOnRedaction: Bool = true) {
        self.failOnRedaction = failOnRedaction
    }

    var lines: [String] { captured.withLock { $0 } }

    var log: TraceLog {
        TraceLog(enabled: true) { [captured, failOnRedaction] line in
            captured.withLock { $0.append(line) }
            if failOnRedaction && line.contains(TraceLog.redacted) {
                Issue.record("a log line had to be redacted, so something tried to log an identity: \(line)")
            }
        }
    }
}

/// A synthetic install id. A placeholder, never a real visitor's.
let placeholderKey = "auk_app_0123456789abcdef0123456789abcdef"

/// What a stub server answers one request with.
enum Reply: Sendable {
    /// The status, with what the Trace API answers that route with when the status is a 2xx.
    case status(Int)
    /// The status with this body instead: an address that is not the Trace API, or an answer it does not give.
    case body(Int, String)
    case networkFailure
}

/// What the Trace API answers each route with when it has taken the request (`apps/api/src/tim/tim.controller.ts`
/// and `apps/api/src/consent/consent.controller.ts` in the monorepo).
func apiAnswer(to path: String) -> String {
    path == "/v1/consent"
        ? #"{"anon_user_key":"\#(placeholderKey)","cookie_set":true,"journey_ref":null}"#
        : #"{"accepted":true}"#
}

/// One request as it arrived on the wire.
struct ArrivedRequest: Sendable {
    let request: URLRequest
    let body: Data

    var path: String { request.url?.path ?? "" }
    func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
}

/// A server that exists only inside a `URLSession` configuration, through ``StubProtocol``. No test makes a real
/// network call. Each stub has a host of its own, so tests running in parallel never see each other's requests.
final class StubServer: Sendable {

    let url: URL
    let session: URLSession
    private let replies: @Sendable (_ path: String, _ attempt: Int) -> Reply
    private let arrived = OSAllocatedUnfairLock(initialState: [ArrivedRequest]())

    /// `replies` is asked for each request with its path and which attempt at that path it is, counting from 1.
    init(_ replies: @escaping @Sendable (_ path: String, _ attempt: Int) -> Reply = { _, _ in .status(202) }) {
        self.replies = replies
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        url = URL(string: "https://\(host)")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
        StubProtocol.servers.withLock { $0[host] = self }
    }

    var requests: [ArrivedRequest] { arrived.withLock { $0 } }

    fileprivate func answer(_ request: URLRequest, body: Data) -> Reply {
        let path = request.url?.path ?? ""
        let attempt = arrived.withLock { list in
            list.append(ArrivedRequest(request: request, body: body))
            return list.filter { $0.path == path }.count
        }
        return replies(path, attempt)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {

    static let servers = OSAllocatedUnfairLock(initialState: [String: StubServer]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let server = Self.servers.withLock({ $0[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch server.answer(request, body: Self.body(of: request)) {
        case .networkFailure:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let status):
            reply(url, status, (200...299).contains(status) ? apiAnswer(to: url.path) : "")
        case .body(let status, let body):
            reply(url, status, body)
        }
    }

    private func reply(_ url: URL, _ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    // URLSession hands a protocol the body as a stream, not as httpBody.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
