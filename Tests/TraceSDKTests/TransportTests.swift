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
    @Test(arguments: [200, 201, 202])
    func anyTwoHundredWithTheApisAnswerIsASuccess(status: Int) async {
        let server = StubServer { _, _ in .status(status) }
        #expect(await transport(server).send(firstOpen()))
        #expect(await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false))
        #expect(server.requests.count == 2, "a success must not be retried")
    }

    // 7 October 2026: the default address reached the dashboard, which answers a POST with a web page and a 200, and
    // every event was counted as delivered and lost. A 2xx that is not the API's answer is a wrong address: not
    // delivered, not retried, and said in the log.
    @Test func aTwoHundredWebPageIsNotDeliveredIsNotRetriedAndIsLogged() async {
        let server = StubServer { _, _ in .body(200, "<!DOCTYPE html><html><body>Trace</body></html>") }
        #expect(await transport(server).send(firstOpen()) == false)
        #expect(await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false) == false)
        #expect(server.requests.count == 2, "a wrong address stays wrong, so it is not retried")
        #expect(capture.lines.filter { $0.contains("check the configured api url") }.count == 2)
    }

    @Test(arguments: [
        #"{"accepted":true}"#,
        #"{"accepted":true,"buffered":true,"request_id":"req_placeholder"}"#,
        #"{"accepted":true,"ignored":true,"reason":"ip_excluded"}"#,
    ])
    func aTwoHundredAndTwoWithAcceptedTrueIsDelivered(body: String) async {
        let server = StubServer { _, _ in .body(202, body) }
        #expect(await transport(server).send(firstOpen()))
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [
        #"{"anon_user_key":null,"cookie_set":false,"journey_ref":null}"#,
        #"{"anon_user_key":null,"cookie_set":false,"ignored":true,"reason":"ip_excluded"}"#,
    ])
    func aTwoHundredAndOneWithTheConsentAnswerIsDelivered(body: String) async {
        let server = StubServer { _, _ in .body(201, body) }
        #expect(await transport(server).sendConsent(key: placeholderKey, analytics: false, marketing: false))
        #expect(server.requests.count == 1)
    }

    // Each route is held to its own answer, so the event's answer does not pass for the consent call's.
    @Test(arguments: ["", "{}", "[]", "null", #"{"ok":true}"#, #"{"accepted":false}"#, #"{"accepted":"true"}"#,
                      #"{"cookie_set":true}"#])
    func aTwoHundredWithOtherJSONIsNotDeliveredOnTheEventRoute(body: String) async {
        let server = StubServer { _, _ in .body(202, body) }
        #expect(await transport(server).send(firstOpen()) == false)
        #expect(server.requests.count == 1)
    }

    @Test(arguments: ["", "{}", "[]", #"{"ok":true}"#, #"{"accepted":true}"#, #"{"cookie_set":"true"}"#])
    func aTwoHundredWithOtherJSONIsNotDeliveredOnTheConsentRoute(body: String) async {
        let server = StubServer { _, _ in .body(201, body) }
        #expect(await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false) == false)
        #expect(server.requests.count == 1)
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

    // The store declarations (README.md, "What to declare to the stores", and Sources/TraceSDK/PrivacyInfo.xcprivacy)
    // say what leaves the device. This is that list, read off the wire with every field filled in. A field added to
    // an event or to the consent call fails here until the declarations say what it is and this list names it.
    @Test func everyFieldThatLeavesTheDeviceIsOneTheStoreDeclarationsName() async {
        let declared: Set<String> = [
            // The install id, and what kind of client sent it.
            "anon_user_key", "source_type", "platform", "store",
            // The event: what happened, when, under which consent answer, and on which version of the app.
            "event_type", "timestamp", "consent_status", "app_version",
            // A conversion: the app's name for it, its value and its metadata. The SDK never fills in the two
            // conversion_ fields today; they are named so that starting to send them is still a change seen here.
            "event_name", "value", "metadata", "conversion_type_id", "conversion_value",
            // The consent call: the two answers.
            "consent_analytics", "consent_marketing",
        ]
        let server = StubServer()
        _ = await transport(server).send(Event(type: .purchase, anonUserKey: placeholderKey, consentStatus: .granted,
                                               appVersion: "1.0", eventName: "purchase", value: 1,
                                               conversionTypeId: "ct", conversionValue: 1, metadata: ["plan": "plus"]))
        _ = await transport(server).sendConsent(key: placeholderKey, analytics: true, marketing: false)
        #expect(server.requests.count == 2)
        #expect(Set(server.requests.flatMap { $0.json.keys }) == declared)
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
