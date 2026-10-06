import Foundation

/// What the consent gate sends through. A protocol so a test can stand in for the network; the only conformer in
/// the SDK is ``Transport``.
protocol EventSender: Sendable {
    /// Sends one event, returning whether the server took it. Never throws.
    func send(_ event: Event) async -> Bool

    /// Sends the consent answers under `key`, returning whether the server took them. Never throws.
    ///
    /// `key` is not optional. On a consent gated site the server buffers an event it received without consent and
    /// replays it once consent arrives, taking the anonymous key from this call. Without one the server mints a key
    /// of its own and records it as though it were this app's install id.
    func sendConsent(key: String, analytics: Bool, marketing: Bool) async -> Bool
}

/// The only thing in this SDK that touches the network, through `URLSession` and nothing else.
///
/// **Neither method throws.** A refused connection, a host that does not resolve, a server that never answers, a
/// typo in the configured api url: each is a `false` and a log line. This runs inside somebody else's app, where an
/// error thrown is a crash the customer did not write.
///
/// It does not know about consent and it does not queue. It sends what it is given and says whether the server took
/// it. Success is any 2xx: `/v1/event` answers 202 and `/v1/consent` 201. A 4xx is never retried, because a payload
/// the server rejected it will reject again. A 5xx or a request that did not complete is tried three times in all.
struct Transport: EventSender {

    static let attempts = 3

    /// `TraceSdkIOS/<sdk version> (iOS <os version>)`. Never empty: an empty user agent is read as a bot, and the
    /// server then ignores the event behind a success, the one failure this side cannot see. Built from numbers that
    /// always exist, so it cannot be empty.
    static let userAgent: String = {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "TraceSdkIOS/\(TraceSDKVersion.current) (iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }()

    /// Ephemeral, so nothing the SDK sends leaves a cookie or a cache entry behind. Ten seconds to answer.
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    private let apiKey: String
    private let baseURL: String
    private let session: URLSession
    private let log: TraceLog
    private let backoff: Duration

    /// `backoff` is multiplied by the attempt number between tries. Short, because the caller may hold the only
    /// copy of an install, and a long wait outlives the launch it belongs to. The tests pass zero.
    init(apiKey: String, apiURL: String, session: URLSession = Transport.defaultSession, log: TraceLog = .silent,
         backoff: Duration = .milliseconds(250)) {
        self.apiKey = apiKey
        var base = apiURL
        while base.hasSuffix("/") { base.removeLast() }
        baseURL = base
        self.session = session
        self.log = log
        self.backoff = backoff
    }

    func send(_ event: Event) async -> Bool {
        guard let body = event.json() else {
            log.log("\(event.type.rawValue) could not be written as JSON, not sent")
            return false
        }
        let accepted = await post("/v1/event", body)
        log.log("\(event.type.rawValue) \(accepted ? "accepted" : "not accepted")")
        return accepted
    }

    func sendConsent(key: String, analytics: Bool, marketing: Bool) async -> Bool {
        let fields: [String: Any] = [
            "consent_analytics": analytics,
            "consent_marketing": marketing,
            "anon_user_key": key,
            "timestamp": Event.now(),
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { return false }
        let accepted = await post("/v1/consent", body)
        log.log("consent \(accepted ? "accepted" : "not accepted")")
        return accepted
    }

    private func post(_ path: String, _ body: Data) async -> Bool {
        // Checked once, outside the retry loop: a url that is not http will not become http on a second attempt.
        guard let url = URL(string: baseURL + path), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host?.isEmpty == false else {
            log.log("cannot send \(path): the configured api url is not an http url")
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-trace-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        for attempt in 1...Self.attempts {
            let outcome = await self.attempt(request)
            if outcome.accepted { return true }
            guard outcome.worthRetrying, attempt < Self.attempts else {
                log.log("\(path) failed on attempt \(attempt) of \(Self.attempts), \(outcome.reason), giving up")
                return false
            }
            log.log("\(path) attempt \(attempt) of \(Self.attempts) failed, \(outcome.reason), trying again")
            // A cancelled wait means whatever is sending is shutting down, so stop.
            do { try await Task.sleep(for: backoff * attempt) } catch { return false }
        }
        return false
    }

    private func attempt(_ request: URLRequest) async -> (accepted: Bool, worthRetrying: Bool, reason: String) {
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200...299: return (true, false, "accepted")
            case 400...499: return (false, false, "refused with \(status)")
            default: return (false, true, "server answered \(status)")
            }
        } catch {
            // No connection, no answer, or an answer too late. The next attempt may find a network.
            return (false, true, "the request did not complete")
        }
    }
}
