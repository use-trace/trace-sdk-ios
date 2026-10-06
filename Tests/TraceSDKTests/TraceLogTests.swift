import Testing
@testable import TraceSDK

/// The log is the one place an identity could reach somebody else's crash reporter, and "never log the install id"
/// is a rule a later change forgets. So the sink strips anything identity shaped, whatever the call site wrote.
struct TraceLogTests {

    private func logged(_ message: String) -> String {
        let capture = LogCapture(failOnRedaction: false)
        capture.log.log(message)
        return capture.lines.joined(separator: "\n")
    }

    @Test func nothingIsWrittenUnlessLoggingWasTurnedOn() {
        let capture = LogCapture()
        TraceLog(enabled: false, sink: capture.log.sink).log("FIRST_OPEN accepted")
        #expect(capture.lines.isEmpty)
    }

    @Test func anOrdinaryOutcomeLineSurvivesIntact() {
        #expect(logged("/v1/event failed on attempt 3 of 3, server answered 500, giving up")
            == "/v1/event failed on attempt 3 of 3, server answered 500, giving up")
    }

    @Test(arguments: [
        "sent FIRST_OPEN for \(placeholderKey)",
        "key 0123456789abcdef0123456789abcdef refused",
        "vendor id 01234567-89AB-CDEF-0123-456789ABCDEF read",
    ])
    func anInstallIdCannotBeLoggedHoweverItIsPassedIn(line: String) {
        let out = logged(line)
        #expect(out.contains(TraceLog.redacted))
        #expect(!out.contains("0123456789abcdef"))
        #expect(!out.lowercased().contains("89ab-cdef"))
    }

    @Test func anEmailCannotBeLogged() {
        let out = logged("a value was refused: someone@example.com")
        #expect(out.contains(TraceLog.redacted))
        #expect(!out.contains("someone@example.com"))
    }

    @Test func aCampaignLinkCannotBeLogged() {
        let out = logged("opened with utm_source=newsletter&gclid=not-real-click-id")
        #expect(out.contains(TraceLog.redacted))
        #expect(!out.contains("newsletter"))
        #expect(!out.contains("gclid"))
    }
}
