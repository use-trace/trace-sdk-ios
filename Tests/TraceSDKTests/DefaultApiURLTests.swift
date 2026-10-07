import Testing
@testable import TraceSDK

/// The default address is the hosted API, not the dashboard in front of it.
///
/// Until 7 October 2026 it was `https://app.usetrace.io`, where `POST /v1/event` and `POST /v1/consent` reach the
/// dashboard, which answers with a web page and a 200. ``Transport`` then counted any 2xx as delivered, so an app built
/// from the install instructions (which pass no address) sent everything into a page and lost it, with nothing in the
/// log. It now requires the API's own answer, so a wrong address fails and says so.
/// The nightly run across every Trace repository (`e2e-all.yml` in the monorepo) now sends through this default
/// against production and reads the install back; this pins the value it relies on.
struct DefaultApiURLTests {

    @Test func theDefaultAddressIsTheHostedApiNotTheDashboard() {
        #expect(TraceConfig(apiKey: "trace_placeholder_key").apiURL == "https://app.usetrace.io/api-proxy")
    }
}
