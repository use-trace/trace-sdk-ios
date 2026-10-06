import Foundation
import Testing
@testable import TraceSDK

struct EventTests {

    private func json(_ event: Event) throws -> [String: Any] {
        let data = try #require(event.json())
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func anEventSaysItIsAnIOSAppFromTheAppStore() throws {
        let body = try json(Event(type: .firstOpen, anonUserKey: placeholderKey, consentStatus: .granted))
        #expect(body["event_type"] as? String == "FIRST_OPEN")
        #expect(body["source_type"] as? String == "app")
        #expect(body["platform"] as? String == "ios")
        #expect(body["store"] as? String == "app_store")
        #expect(body["anon_user_key"] as? String == placeholderKey)
        #expect(body["consent_status"] as? String == "GRANTED")
    }

    @Test func aFieldWithNothingInItIsLeftOutRatherThanSentAsNull() throws {
        let body = try json(Event(type: .firstOpen, anonUserKey: placeholderKey, consentStatus: .granted))
        for absent in ["app_version", "event_name", "value", "conversion_type_id", "conversion_value", "metadata"] {
            #expect(body[absent] == nil, "\(absent) should be absent")
        }
    }

    @Test func theTimestampIsTheShapeTheServerAccepts() {
        let event = Event(type: .custom, anonUserKey: placeholderKey, consentStatus: .unknown)
        #expect(event.timestamp.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/) != nil)
    }

    @Test func aValueWithNoJSONFormIsLeftOutRatherThanFailingTheEvent() throws {
        let body = try json(Event(type: .purchase, anonUserKey: placeholderKey, consentStatus: .granted,
                                  value: .nan, conversionValue: .infinity))
        #expect(body["value"] == nil)
        #expect(body["conversion_value"] == nil)
        #expect(body["event_type"] as? String == "PURCHASE")
    }

    @Test func anEventCannotPrintItsOwnIdentity() {
        let event = Event(type: .custom, anonUserKey: placeholderKey, consentStatus: .unknown, eventName: "x")
        var dumped = ""
        dump(event, to: &dumped)
        for printed in ["\(event)", String(reflecting: event), "\([event])", dumped] {
            #expect(!printed.contains(placeholderKey), "printed: \(printed)")
        }
    }
}
