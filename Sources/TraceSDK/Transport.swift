import Foundation
import os

/// What became of one event.
enum Delivery: Sendable {
    /// The Trace API said it took it.
    case delivered
    /// Refused, unreachable, or a server error that outlasted the retries. The server may have taken it.
    case failed
    /// The configuration is wrong: the api url is not the Trace API (not an http url, or a 2xx without the API's
    /// answer), or the API refused the api key with a 401 or 403. The event certainly did not reach Trace, so the
    /// consent gate does not mark a first open sent.
    case wrongConfiguration
}

/// What the consent gate sends through. A protocol so a test can stand in for the network; the only conformer in
/// the SDK is ``Transport``.
protocol EventSender: Sendable {
    /// Sends one event, saying what became of it. Never throws.
    func send(_ event: Event) async -> Delivery

    /// Sends the consent answers under `key`, returning whether the server took them. Never throws.
    ///
    /// `key` is not optional. On a consent gated site the server buffers an event it received without consent and
    /// replays it once consent arrives, taking the anonymous key from this call. Without one the server mints a key
    /// of its own and records it as though it were this app's install id.
    func sendConsent(key: String, analytics: Bool, marketing: Bool, firstAnswer: Bool) async -> Bool

    /// Reports a refusal from an install that has no id, once, so the server can count the answer. It carries no
    /// identifier of any kind: `consent_analytics` false, the marketing answer, the time, the platform, and
    /// `first_answer` true. Returns whether the server took it. Never throws.
    func sendFirstRefusal(marketing: Bool) async -> Bool

    /// Whether the site is consent gated (UK and EU, or no region set), from the site's config, or nil when there is
    /// no answer. Decides whether Apple may hear anything before consent. Never throws.
    func consentGated() async -> Bool?
}

/// The only thing in this SDK that touches the network, through `URLSession` and nothing else.
///
/// **Neither method throws.** A refused connection, a host that does not resolve, a server that never answers, a
/// typo in the configured api url: each is a `false` and a log line. This runs inside somebody else's app, where an
/// error thrown is a crash the customer did not write.
///
/// It does not know about consent and it does not queue. It sends what it is given and says whether the server took
/// it. A 4xx is never retried, because a payload the server rejected it will reject again. A 5xx or a request that
/// did not complete is tried three times in all.
///
/// **Delivered means a 2xx with the Trace API's own answer, not any 2xx.** `/v1/event` answers 202 with
/// `"accepted": true`, and `/v1/consent` answers 201 with a boolean `cookie_set`. Until 7 October 2026 any 2xx counted,
/// and the default address reached the dashboard, which answers a POST with a web page and a 200: every event was
/// lost and nothing said so. A 2xx without that answer (a page, an empty body, some other JSON) is an address that is
/// not the Trace API. It is not delivered and it is not retried, because a wrong address stays wrong. It is logged
/// once per transport, whether or not the host app turned logging on, because a developer who never turned it on is
/// the one who needs to hear it, and without the body, which could hold anything.
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
    /// Whether the configuration error has been logged, shared by every copy of this transport.
    private let warned = OSAllocatedUnfairLock(initialState: false)

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

    func send(_ event: Event) async -> Delivery {
        guard let body = event.json() else {
            log.log("\(event.type.rawValue) could not be written as JSON, not sent")
            return .failed
        }
        let delivery = await post("/v1/event", body)
        log.log("\(event.type.rawValue) \(delivery == .delivered ? "accepted" : "not accepted")")
        return delivery
    }

    func sendConsent(key: String, analytics: Bool, marketing: Bool, firstAnswer: Bool) async -> Bool {
        await postConsent(["consent_analytics": analytics, "consent_marketing": marketing, "anon_user_key": key,
                           "first_answer": firstAnswer])
    }

    func sendFirstRefusal(marketing: Bool) async -> Bool {
        await postConsent(["consent_analytics": false, "consent_marketing": marketing, "first_answer": true])
    }

    /// `GET /v1/snippet-config?key=`, which tells the website tag the same thing. Asked once and never retried: no
    /// answer reads as gated, which only makes Apple wait for consent. The key is the site's public tracking key, as
    /// in the tag's own request, and names a site rather than anybody.
    func consentGated() async -> Bool? {
        var parts = URLComponents(string: baseURL + "/v1/snippet-config")
        parts?.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = parts?.url, ["http", "https"].contains(url.scheme?.lowercased()), url.host?.isEmpty == false else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let gated = answer["consent_gated"] as? Bool
        else {
            log.log("the site's consent rule could not be read, so it is treated as consent gated")
            return nil
        }
        return gated
    }

    // The share of people who said yes is worked out per platform, counting each install's answer once by
    // `first_answer` (decision 3 of APP_MODELLED_INSTALLS.md in use-trace/trace).
    private func postConsent(_ answer: [String: Any]) async -> Bool {
        let fields = answer.merging(["timestamp": Event.now(), "platform": "ios"]) { mine, _ in mine }
        guard let body = try? JSONSerialization.data(withJSONObject: fields) else { return false }
        let accepted = await post("/v1/consent", body) == .delivered
        log.log("consent \(accepted ? "accepted" : "not accepted")")
        return accepted
    }

    private func post(_ path: String, _ body: Data) async -> Delivery {
        // Checked once, outside the retry loop: a url that is not http will not become http on a second attempt.
        guard let url = URL(string: baseURL + path), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host?.isEmpty == false else {
            log.log("cannot send \(path): the configured api url is not an http url")
            return .wrongConfiguration
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-trace-api-key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        for attempt in 1...Self.attempts {
            let outcome = await self.attempt(request, path)
            if outcome.delivery == .delivered { return .delivered }
            guard outcome.worthRetrying, attempt < Self.attempts else {
                log.log("\(path) failed on attempt \(attempt) of \(Self.attempts), \(outcome.reason), giving up")
                return outcome.delivery
            }
            log.log("\(path) attempt \(attempt) of \(Self.attempts) failed, \(outcome.reason), trying again")
            // A cancelled wait means whatever is sending is shutting down, so stop.
            do { try await Task.sleep(for: backoff * attempt) } catch { return .failed }
        }
        return .failed
    }

    private func attempt(_ request: URLRequest, _ path: String) async
        -> (delivery: Delivery, worthRetrying: Bool, reason: String) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200...299 where Self.isTraceAnswer(data, to: path): return (.delivered, false, "accepted")
            case 200...299:
                warnOnce("\(path) answered \(status) but not as the Trace API does, so nothing is being delivered: "
                    + "check the configured api url")
                return (.wrongConfiguration, false, "answered \(status) without the Trace API's answer")
            case 401, 403:
                warnOnce("\(path) was refused with \(status), so nothing is being delivered: check the configured api key")
                return (.wrongConfiguration, false, "refused with \(status)")
            case 400...499: return (.failed, false, "refused with \(status)")
            default: return (.failed, true, "server answered \(status)")
            }
        } catch {
            // No connection, no answer, or an answer too late. The next attempt may find a network.
            return (.failed, true, "the request did not complete")
        }
    }

    /// Writes `line` whether or not the host app turned logging on, once per transport.
    private func warnOnce(_ line: String) {
        guard !warned.withLock({ warned in defer { warned = true }; return warned }) else { return }
        TraceLog(enabled: true, sink: log.sink).log(line)
    }

    /// Whether `data` is what the Trace API answers `path` with when it has taken the request.
    private static func isTraceAnswer(_ data: Data, to path: String) -> Bool {
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return path == "/v1/consent" ? answer["cookie_set"] is Bool : answer["accepted"] as? Bool == true
    }
}
