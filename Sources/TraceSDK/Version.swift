/// The SDK's own version. It goes into the user agent, `TraceSdkIOS/<version> (iOS <version>)`, which must never be
/// empty or the server treats the event as a bot.
enum TraceSDKVersion {
    static let current = "0.3.0"
}
