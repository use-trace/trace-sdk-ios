import Foundation

/// The three event types this SDK sends. The server knows more; the SDK's boundary is these.
enum EventType: String, Codable, Sendable {
    /// The install. Sent once, ever.
    case firstOpen = "FIRST_OPEN"
    /// A purchase conversion.
    case purchase = "PURCHASE"
    /// Any other conversion the host app names.
    case custom = "CUSTOM"
}

/// What the host app has said about consent. The raw values are the wire values the server's `consent_status`
/// accepts. `unknown` is not an opinion, it is "nobody has answered the banner yet", and an event recorded in that
/// state is held rather than sent.
enum ConsentState: String, Codable, Sendable {
    case unknown = "UNKNOWN"
    case granted = "GRANTED"
    case denied = "DENIED"
}

/// One event, in the shape `POST /v1/event` takes.
///
/// `source_type`, `platform` and `store` are on every event: this SDK is an iOS app from the App Store and says so
/// rather than relying on the server to infer it. The timestamp is taken when the event is made, not when it is
/// sent, because an event held behind a consent banner may be sent long after it happened.
///
/// **It cannot print its own identity.** `description`, `debugDescription` and its mirror say the type and the time
/// and nothing else, so interpolating an event into a string, an array of them into a log, or `dump`ing one cannot
/// put the install id in a line. ``TraceLog`` would strip it; this stops the accident a step earlier.
struct Event: Codable, Sendable, Equatable {

    var type: EventType
    /// The install id. Required on every event sent: the server refuses an install without one. Empty while the event
    /// is held, because before a grant there is no id, and the consent gate fills it in as it sends.
    var anonUserKey: String
    var consentStatus: ConsentState
    var timestamp: String = Event.now()
    var appVersion: String? = nil
    var eventName: String? = nil
    var value: Double? = nil
    var conversionTypeId: String? = nil
    var conversionValue: Double? = nil
    var metadata: [String: String]? = nil
    var sourceType = "app"
    var platform = "ios"
    var store = "app_store"

    enum CodingKeys: String, CodingKey {
        case type = "event_type"
        case anonUserKey = "anon_user_key"
        case consentStatus = "consent_status"
        case timestamp
        case appVersion = "app_version"
        case eventName = "event_name"
        case value
        case conversionTypeId = "conversion_type_id"
        case conversionValue = "conversion_value"
        case metadata
        case sourceType = "source_type"
        case platform
        case store
    }

    /// The request body for `POST /v1/event`, on one line. Empty fields are left out rather than sent as null.
    ///
    /// A value with no JSON form, NaN or an infinity, is left out too: the server treats the field as absent,
    /// where a value it cannot parse would fail the whole event. Nil only if encoding fails all the same.
    func json() -> Data? {
        var sendable = self
        sendable.value = value.flatMap { $0.isFinite ? $0 : nil }
        sendable.conversionValue = conversionValue.flatMap { $0.isFinite ? $0 : nil }
        return try? JSONEncoder().encode(sendable)
    }

    /// Now, in the format the server's `IsDateString` accepts: UTC, with milliseconds.
    static func now() -> String {
        Date.now.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

extension Event: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "Event(\(type.rawValue) at \(timestamp))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
