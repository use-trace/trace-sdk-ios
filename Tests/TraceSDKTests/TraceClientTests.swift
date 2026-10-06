import Foundation
import Testing
@testable import TraceSDK

/// What ``Trace`` does, through ``TraceClient``, the instance behind it, so these can run in parallel. A new client
/// over the same directory stands in for a new launch of the app.
struct TraceClientTests {

    let directory = temporaryDirectory()
    let capture = LogCapture()

    private func client(_ sender: RecordingSender, _ registrar: FakeRegistrar = FakeRegistrar()) -> TraceClient {
        TraceClient(directory: directory, sender: sender, registrar: registrar, log: capture.log)
    }

    /// A client launched, with whatever the test then does, run to the end.
    private func launch(_ sender: RecordingSender, _ registrar: FakeRegistrar = FakeRegistrar(),
                        then work: (TraceClient) -> Void = { _ in }) async {
        let client = client(sender, registrar)
        client.launch()
        work(client)
        await client.idle()
    }

    @Test func theFirstOpenIsSentOnceEverAcrossLaunches() async {
        let first = RecordingSender()
        await launch(first) { $0.setConsent(analytics: true, marketing: false) }
        let second = RecordingSender()
        await launch(second) { $0.setConsent(analytics: true, marketing: false) }

        #expect(first.calls == ["consent analytics=true marketing=false", "event FIRST_OPEN"])
        #expect(second.calls == ["consent analytics=true marketing=false"])
    }

    @Test func theFirstOpenFlagIsExcludedFromBackup() async throws {
        await launch(RecordingSender()) { $0.setConsent(analytics: true, marketing: false) }

        #expect(try isExcludedFromBackup(directory.appending(path: TraceClient.firstOpenFlag)) == true)
    }

    // The trap: before the first unlock after a reboot the id file is there and cannot be read. Nothing may be
    // minted and nothing sent, and the calls made meanwhile run on the first call after the file can be read.
    @Test func whileTheIdFileCannotBeReadNothingIsMintedNothingSentAndItAllRunsLater() async throws {
        let id = try #require(InstallId.get(in: directory))
        let file = directory.appending(path: InstallId.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let sender = RecordingSender()
        let client = client(sender)

        client.launch()
        client.conversion("signup", value: nil, metadata: [:])
        client.setConsent(analytics: true, marketing: false)
        await client.idle()

        #expect(sender.calls.isEmpty, "nothing may be sent while the install id cannot be read")
        #expect(try written() == [InstallId.fileName],
                "no new id, no first open flag, no held queue and no conversion value flag may be written")

        // The phone is unlocked. The next call runs what waited, in the order it was called, under the first id.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try String(contentsOf: file, encoding: .utf8) == id, "no new id may be written over the first")
        client.conversion("purchase", value: 9.99, metadata: [:])
        await client.idle()

        #expect(sender.calls == [
            "consent analytics=true marketing=false",
            "event FIRST_OPEN",
            "event signup",
            "event purchase",
        ])
        #expect(sender.consentKeys == [id])
        #expect(sender.events.allSatisfy { $0.anonUserKey == id })
        #expect(sender.events.allSatisfy { $0.consentStatus == .granted })
    }

    // Registering with Apple sends nothing to Trace and no identity anywhere, so it does not wait for consent.
    @Test func theInstallIsRegisteredWithAppleWhateverTheConsentAnswer() async {
        let registrar = FakeRegistrar()
        let sender = RecordingSender()

        await launch(sender, registrar) { $0.setConsent(analytics: false, marketing: false) }

        #expect(registrar.updates == ["0 low"])
        #expect(sender.events.isEmpty)
    }

    @Test func aConversionRaisesTheValueAndAHostValueIsPassedOn() async {
        let registrar = FakeRegistrar()

        await launch(RecordingSender(), registrar) {
            $0.conversion("signup", value: nil, metadata: [:])
            $0.setConversionValue(fine: 12, coarse: .high)
        }

        #expect(registrar.updates == ["0 low", "0 medium", "12 high"])
    }

    @Test func aPurchaseIsSentAsThePurchaseTypeWithItsValueAndAnythingElseAsCustom() async {
        let sender = RecordingSender()

        await launch(sender) {
            $0.setConsent(analytics: true, marketing: false)
            $0.conversion("Purchase", value: 29.99, metadata: ["plan": "plus"])
            $0.conversion("signup", value: nil, metadata: [:])
        }

        let conversions = sender.events.filter { $0.type != .firstOpen }
        #expect(conversions.map(\.type) == [.purchase, .custom])
        #expect(conversions.map(\.eventName) == ["Purchase", "signup"])
        #expect(conversions.first?.value == 29.99)
        #expect(conversions.first?.metadata == ["plan": "plus"])
    }

    @Test func aConversionWithABlankNameSendsNothing() async {
        let sender = RecordingSender()
        let registrar = FakeRegistrar()

        await launch(sender, registrar) {
            $0.setConsent(analytics: true, marketing: false)
            $0.conversion("  ", value: 1, metadata: [:])
        }

        #expect(sender.calls == ["consent analytics=true marketing=false", "event FIRST_OPEN"])
        #expect(registrar.updates == ["0 low"])
    }

    // Decided 6 October 2026, before the first release: nothing is stored before consent. The first open waits in
    // memory only; the id and the install are written the moment the person accepts, and a refusal never writes an
    // identifier. These are that decision as tests, over the directory the SDK writes to.

    /// Every file the SDK has written to its directory.
    private func written() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    @Test func aFreshInstallThatNeverAnswersWritesNoFileAtAll() async throws {
        let sender = RecordingSender()
        let registrar = FakeRegistrar()

        await launch(sender, registrar) { $0.conversion("purchase", value: 9.99, metadata: [:]) }

        #expect(try written().isEmpty, "nothing may be written to the device before the person has answered")
        #expect(sender.calls.isEmpty)
        #expect(InstallId.peek(in: directory) == nil)
        // Apple is still told, because that needs no Trace consent; only the record of having told it waits.
        #expect(registrar.updates == ["0 low", "0 medium"])
    }

    @Test func aRefusalWritesNoIdentifierAndSendsNothing() async throws {
        let sender = RecordingSender()

        await launch(sender) {
            $0.conversion("purchase", value: 9.99, metadata: [:])
            $0.setConsent(analytics: false, marketing: true)
        }

        #expect(try written().isEmpty, "a refusal may write nothing at all")
        #expect(sender.calls.isEmpty)
    }

    @Test func acceptanceWritesTheIdSendsExactlyOneFirstOpenWithItThenTheHeldEventsInOrder() async throws {
        let sender = RecordingSender()

        await launch(sender) {
            $0.conversion("signup", value: nil, metadata: [:])
            $0.conversion("purchase", value: 9.99, metadata: [:])
            $0.setConsent(analytics: true, marketing: false)
        }

        let id = try #require(InstallId.peek(in: directory), "the grant should have written the install id")
        #expect(try written() == [TraceClient.firstOpenFlag, InstallId.fileName, ConversionValues.registeredFlag,
                                  ConversionValues.raisedFlag].sorted())
        #expect(sender.calls == [
            "consent analytics=true marketing=false",
            "event FIRST_OPEN",
            "event signup",
            "event purchase",
        ])
        #expect(sender.consentKeys == [id])
        #expect(sender.events.map(\.anonUserKey) == [id, id, id])
    }

    @Test func aConversionHeldBeforeAcceptanceIsSentAfterIt() async throws {
        let sender = RecordingSender()
        let client = client(sender)
        client.launch()
        client.conversion("purchase", value: 9.99, metadata: [:])
        await client.idle()
        #expect(sender.calls.isEmpty)

        client.setConsent(analytics: true, marketing: false)
        await client.idle()

        let purchase = try #require(sender.events.first { $0.type == .purchase })
        #expect(sender.calls.last == "event purchase")
        #expect(purchase.consentStatus == .granted)
        #expect(purchase.anonUserKey == InstallId.peek(in: directory))
        #expect(purchase.value == 9.99)
    }

    @Test func aRestartBeforeAnyAnswerIsAFirstOpenAgain() async throws {
        await launch(RecordingSender()) { $0.conversion("signup", value: nil, metadata: [:]) }

        // The app is killed with its banner still on screen. Nothing was written, so the next launch knows nothing
        // of this one: the held conversion is lost, which is the accepted cost, and the install is new.
        #expect(try written().isEmpty)

        let sender = RecordingSender()
        let registrar = FakeRegistrar()
        await launch(sender, registrar) { $0.setConsent(analytics: true, marketing: false) }

        #expect(sender.calls == ["consent analytics=true marketing=false", "event FIRST_OPEN"])
        #expect(sender.events.first?.anonUserKey == InstallId.peek(in: directory))
        #expect(registrar.updates == ["0 low"], "no record of registering was kept, so it registers again")
    }

    // The server keeps metadata keys of letters, digits and underscores and drops the rest without a word.
    @Test func metadataKeysTheServerWouldDropAreReported() async {
        await launch(RecordingSender()) { $0.conversion("signup", value: nil, metadata: ["ok_key": "1", "bad key": "2"]) }

        #expect(capture.lines.contains { $0.contains("bad key") && !$0.contains("ok_key") })
    }
}
