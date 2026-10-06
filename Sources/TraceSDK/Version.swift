/// The SDK's own version. It goes into the user agent, `TraceSdkIOS/<version> (iOS <version>)`, which must never be
/// empty or the server treats the event as a bot.
enum TraceSDKVersion {
    static let current = "0.1.0"
}

// DELIBERATE VIOLATION, reverted in the next commit: a public symbol with no api/ update, and a log call
// outside TraceLog.
public enum TraceVersion {
    public static func show() { print(TraceSDKVersion.current) }
}
