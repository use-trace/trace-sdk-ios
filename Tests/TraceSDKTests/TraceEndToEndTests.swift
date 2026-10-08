import Foundation
import Testing
@testable import TraceSDK

/// The real ``Trace``, through its public calls, against a stub server and a fake registrar. Serialised, because
/// ``Trace`` is one per process, and this is the only suite that touches it.
@Suite(.serialized)
struct TraceEndToEndTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()

    // The order is the assertion. The consent call carries the install id and goes first, or the server replays the
    // held first open under a key it minted itself; every event is GRANTED, or the server quarantines it.
    @Test func aLaunchHeldUntilAGrantSendsConsentThenTheFirstOpenThenTheConversionAndNothingElse() async throws {
        let server = StubServer { path, _ in .status(path == "/v1/consent" ? 201 : 202) }
        let registrar = FakeRegistrar()

        Trace.initialise(TraceConfig(apiKey: "tk_placeholder", apiURL: server.url.absoluteString),
                         directory: directory, session: server.session, registrar: registrar, log: capture.log)
        Trace.conversion("purchase", value: 29.99, metadata: ["plan": "plus"])
        Trace.setConsent(analytics: true, marketing: false)
        await Trace.idleForTest()
        let id = try #require(Trace.installId)
        await Trace.resetForTest()

        let requests = server.requests
        #expect(requests.map(\.path) == ["/v1/snippet-config", "/v1/consent", "/v1/event", "/v1/event"])
        let config = try #require(requests.first)
        #expect(config.request.httpMethod == "GET")
        #expect(config.request.url?.query == "key=tk_placeholder")
        let consent = requests[1]
        #expect(consent.json["anon_user_key"] as? String == id)
        #expect(consent.json["consent_analytics"] as? Bool == true)
        let events = requests.dropFirst(2).map(\.json)
        #expect(events.map { $0["event_type"] as? String } == ["FIRST_OPEN", "PURCHASE"])
        #expect(events.map { $0["consent_status"] as? String } == ["GRANTED", "GRANTED"])
        #expect(events.allSatisfy { $0["anon_user_key"] as? String == id })
        #expect(events.last?["value"] as? Double == 29.99)
        #expect(requests.dropFirst().allSatisfy { $0.header("x-trace-api-key") == "tk_placeholder" })

        // The stub has no site rule to give, which reads as gated, so Apple heard nothing until the grant. Registered
        // then, exactly once; the second update is the purchase made before it, 29.99 in band 32, coarse high.
        #expect(registrar.updates == ["0 low", "32 high"])
    }

    @Test func callsBeforeInitialiseDoNothingAndDoNotThrow() async {
        await Trace.resetForTest()

        Trace.conversion("purchase", value: 1, metadata: [:])
        Trace.setConsent(analytics: true, marketing: true)
        Trace.setConversionValue(fine: 1, coarse: .low)

        #expect(Trace.installId == nil)
    }

    @Test func aBlankApiKeyStartsNothing() async {
        await Trace.resetForTest()
        let server = StubServer()

        Trace.initialise(TraceConfig(apiKey: " "), directory: directory, session: server.session,
                         registrar: FakeRegistrar(), log: capture.log)
        Trace.setConsent(analytics: true, marketing: false)
        await Trace.resetForTest()

        #expect(server.requests.isEmpty)
        #expect(capture.lines.contains { $0.contains("blank api key") })
    }
}
