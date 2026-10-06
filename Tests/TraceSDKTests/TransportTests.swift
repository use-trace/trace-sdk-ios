import Foundation
import Testing
@testable import TraceSDK

/// The transport against a stub server inside the `URLSession`, asserting what goes on the wire. Every log line goes
/// through a ``LogCapture``, so a test also fails if anything the transport logs had to be redacted.
struct TransportTests {

    let capture = LogCapture()

    private func transport(_ server: StubServer, apiURL: String? = nil) -> Transport {
        Transport(apiKey: "tk_placeholder", apiURL: apiURL ?? server.url.absoluteString, session: server.session,
                  log: capture.log, backoff: .zero)
    }

    private func firstOpen() -> Event {
        Event(type: .firstOpen, anonUserKey: placeholderKey, consentStatus: .granted)
    }

    // The lessons table, row 1: /v1/event answers 202 and /v1/consent 201, so a 200 only check fails every send.
    @Test(arguments: [200, 201, 202, 204])
    func anyTwoHundredIsASuccess(status: Int) async {
        let server = StubServer { _, _ in .status(status) }
        #expect(await transport(server).send(firstOpen()))
        #expect(await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false))
        #expect(server.requests.count == 2, "a success must not be retried")
    }

    // Row 2: a payload the server rejected it will reject again.
    @Test(arguments: [400, 401, 403, 413, 422])
    func aFourHundredIsAFailureAndIsNeverRetried(status: Int) async {
        let server = StubServer { _, _ in .status(status) }
        #expect(await transport(server).send(firstOpen()) == false)
        #expect(server.requests.count == 1)
    }

    @Test func aFiveHundredIsRetriedThreeAttemptsInTotal() async {
        let server = StubServer { _, _ in .status(500) }
        #expect(await transport(server).send(firstOpen()) == false)
        #expect(server.requests.count == 3)
    }

    @Test func aFiveHundredThatClearsIsASuccessWithoutADuplicate() async {
        let server = StubServer { _, attempt in attempt == 1 ? .status(503) : .status(202) }
        #expect(await transport(server).send(firstOpen()))
        #expect(server.requests.count == 2)
    }

    @Test func aNetworkFailureIsRetriedThreeAttemptsInTotalAndReturnsFalse() async {
        let server = StubServer { _, _ in .networkFailure }
        #expect(await transport(server).send(firstOpen()) == false)
        #expect(server.requests.count == 3)
    }

    @Test(arguments: ["not a url", "ftp://example.test", ""])
    func anApiURLThatIsNotHTTPReturnsFalseAndSendsNothing(apiURL: String) async {
        let server = StubServer()
        #expect(await transport(server, apiURL: apiURL).send(firstOpen()) == false)
        #expect(server.requests.isEmpty)
    }

    // Row 6: an empty user agent is read as a bot, and the server ignores the event behind a success.
    @Test func theUserAgentSaysWhichSDKAndIsNeverEmpty() async throws {
        let server = StubServer()
        _ = await transport(server).send(firstOpen())
        _ = await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false)
        for request in server.requests {
            let agent = try #require(request.header("User-Agent"))
            #expect(agent.wholeMatch(of: /TraceSdkIOS\/\d+\.\d+\.\d+ \(iOS \d+\.\d+\.\d+\)/) != nil, "user agent was [\(agent)]")
            #expect(agent.hasPrefix("TraceSdkIOS/\(TraceSDKVersion.current) "))
        }
    }

    @Test func theApiKeyAndContentTypeTravelOnTheEventAndOnTheConsentCall() async {
        let server = StubServer()
        _ = await transport(server).send(firstOpen())
        _ = await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false)
        #expect(server.requests.map(\.path) == ["/v1/event", "/v1/consent"])
        for request in server.requests {
            #expect(request.request.httpMethod == "POST")
            #expect(request.header("x-trace-api-key") == "tk_placeholder")
            #expect(request.header("Content-Type") == "application/json")
        }
    }

    @Test func everyEventSaysItIsAnIOSAppFromTheAppStore() async {
        let server = StubServer()
        _ = await transport(server).send(firstOpen())
        _ = await transport(server).send(Event(type: .purchase, anonUserKey: placeholderKey, consentStatus: .granted))
        #expect(server.requests.count == 2)
        for body in server.requests.map(\.json) {
            #expect(body["source_type"] as? String == "app")
            #expect(body["platform"] as? String == "ios")
            #expect(body["store"] as? String == "app_store")
        }
    }

    // Row 3: the server takes the key for a replayed event from the consent call, so the consent call carries it.
    @Test func theInstallIdIsOnEveryEventAndOnTheConsentCall() async {
        let server = StubServer()
        _ = await transport(server).send(firstOpen())
        _ = await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false)
        #expect(server.requests.map { $0.json["anon_user_key"] as? String } == [placeholderKey, placeholderKey])
    }

    @Test func aConsentCallSendsBothAnswersAsBooleansAndATimestamp() async throws {
        let server = StubServer()
        _ = await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false)
        let body = try #require(server.requests.first).json
        #expect(body["consent_analytics"] as? Bool == true)
        #expect(body["consent_marketing"] as? Bool == false)
        #expect((body["timestamp"] as? String)?.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/) != nil)
    }

    // Real campaign names carry quotes, tabs, control characters and emoji. A writer that produces invalid JSON on
    // any of them loses the event.
    @Test func anAwkwardNameArrivesAsJSONTheServerCanParse() async throws {
        let awkward = "a \"quote\", a \\ backslash, a\nnewline, a\ttab, a \u{01} control, an emoji \u{1F389} done"
        let server = StubServer()
        _ = await transport(server).send(Event(type: .custom, anonUserKey: placeholderKey, consentStatus: .granted,
                                               eventName: awkward, metadata: [awkward: awkward]))
        let arrived = try #require(server.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: arrived.body) as? [String: Any])
        #expect(body["event_name"] as? String == awkward)
        #expect(body["metadata"] as? [String: String] == [awkward: awkward])
    }

    // Row 7: the transport handles every install id, so it is where an identity would most easily reach a log.
    @Test func everyOutcomeIsLoggedAndNoLineCarriesAnIdentity() async {
        let accepted = StubServer()
        _ = await transport(accepted).send(firstOpen())
        _ = await transport(accepted).sendConsent(key: placeholderKey, analytics: true, marketing: false)
        _ = await transport(StubServer { _, _ in .status(400) }).send(firstOpen())
        _ = await transport(StubServer { _, _ in .status(500) }).send(firstOpen())
        _ = await transport(StubServer { _, _ in .networkFailure }).send(firstOpen())
        _ = await transport(accepted, apiURL: "not a url").send(firstOpen())

        #expect(capture.lines.count >= 6, "the transport should say what happened, or this proves nothing")
        #expect(capture.lines.allSatisfy { !$0.contains("0123456789abcdef") })
    }
}
