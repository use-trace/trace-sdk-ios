/// What ``Trace/initialise(_:)`` needs: the site's api key, where to send to, and whether to say anything while it
/// works. There is nothing else to configure: every setting is a promise to keep it working, and a way for two
/// installs of the same app to report differently.
///
/// Its description leaves the api key out, so printing a config cannot put the key in a log or a crash report.
public struct TraceConfig: Sendable, CustomStringConvertible {

    /// The site's api key, sent as `x-trace-api-key`. In the Trace dashboard under the site's settings. It ships
    /// inside the app, so it names a site rather than proving anything, and it is still never logged.
    public var apiKey: String

    /// Where to send. The hosted API unless a self hosted deployment says otherwise. A trailing slash does no harm,
    /// and a url that is not http is reported in the log and then nothing is sent, rather than throwing.
    ///
    /// The hosted API is `/api-proxy` on the dashboard's host, as the tracking tag and the WordPress plugin use it.
    /// The bare host is the dashboard, which answers a `POST /v1/event` with a web page and a 200, so every event sent
    /// there looked delivered and was lost (`DefaultApiURLTests`).
    public var apiURL: String

    /// Whether the SDK writes what it is doing to the unified log, subsystem `io.usetrace.sdk`. Off by default. It
    /// never writes an install id or an event's contents whatever this says: those are stripped where the line is
    /// written.
    public var debugLogging: Bool

    public init(apiKey: String, apiURL: String = "https://app.usetrace.io/api-proxy", debugLogging: Bool = false) {
        self.apiKey = apiKey
        self.apiURL = apiURL
        self.debugLogging = debugLogging
    }

    public var description: String { "TraceConfig(apiURL: \(apiURL), debugLogging: \(debugLogging))" }
}
