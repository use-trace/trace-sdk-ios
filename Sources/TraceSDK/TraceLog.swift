import os

/// The SDK's own log, silent unless the host app asks for it, and unable to carry an identity.
///
/// **A value shaped like an identity does not get out, whatever the call site wrote.** Every line is redacted at
/// the sink, so an install id, a vendor or advertising identifier, a campaign link and an email address are
/// replaced by ``redacted`` where the line is written, not where it is called. "Never log the install id" is a rule
/// a later change forgets; a sink that strips one is a property of the code. The tests then fail on any redaction
/// at all during normal running, because a redaction means something tried, even though nothing leaked.
///
/// Redaction is a net, not a parser. The first line of defence is that ``Event`` does not print its own key.
///
/// It is a value handed to what logs, not a global, so a test can capture one component's output without another
/// test running in parallel writing into it.
struct TraceLog: Sendable {

    /// What replaces anything identity shaped. A line containing this is a bug, not an outcome.
    static let redacted = "<redacted>"

    static let silent = TraceLog(enabled: false)

    /// The unified logging system, at debug level. The line is marked public because it has already been redacted:
    /// a private line would show as `<private>` in Console and be no use to the developer who turned logging on.
    static let system: @Sendable (String) -> Void = { line in
        Logger(subsystem: "io.usetrace.sdk", category: "Trace").debug("\(line, privacy: .public)")
    }

    let enabled: Bool
    let sink: @Sendable (String) -> Void

    init(enabled: Bool, sink: @escaping @Sendable (String) -> Void = TraceLog.system) {
        self.enabled = enabled
        self.sink = sink
    }

    /// Writes one line, if logging is on, with anything identity shaped removed first. Never throws.
    func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        sink(Self.redact(message()))
    }

    // The shapes of every identity Trace holds or refuses:
    //  - auk_..., the anonymous key family, which is what an install id is
    //  - a UUID with its hyphens, which is what a vendor or advertising identifier looks like
    //  - a long run of hex, which is a bare install id without its prefix, or a hashed identifier
    //  - a token carrying a tracking parameter, which is what a campaign link or a referrer is
    //  - a token shaped like an email address
    // The SDK's own lines are an event type, an outcome, a status code and a count, so none of them matches.
    // Computed, because `Regex` is not `Sendable`; the literal is checked when the SDK compiles, and logging is off
    // unless the host app asked for it.
    private static var identityShaped: Regex<Substring> { #/auk_[A-Za-z0-9_\-]+|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|[0-9a-f]{32,}|\S*(?:utm_[a-z]+|gclid|gbraid|wbraid|fbclid|msclkid|ttclid|twclid|referrer)=\S*|\S+@\S+\.\S+/#.ignoresCase() }

    static func redact(_ message: String) -> String {
        message.replacing(identityShaped, with: redacted)
    }
}
