#if os(iOS)
import AdAttributionKit
import Testing
@testable import TraceSDK

/// What the SDK hands AdAttributionKit. Only on iOS: `swift test` on the Mac does not build this, the `test ios` job
/// runs it on a simulator.
struct StoreKitRegistrarTests {

    // Rule 9 of the schema (APP_MODELLED_INSTALLS.md): no value is set for an AdAttributionKit re-engagement in
    // version 1. Without a conversion type, iOS 18 applies an update to re-engagement postbacks as well, and the
    // server would read a re-engagement's value as an install's.
    @Test func anUpdateIsForTheInstallOnlyAndNeverLocksTheWindow() throws {
        guard #available(iOS 18.0, *) else { return }

        let update = StoreKitRegistrar.installUpdate(fine: 16, coarse: .high)

        #expect(update.conversionTypes == [.install])
        #expect(update.fineConversionValue == 16)
        #expect(update.coarseConversionValue == .high)
        #expect(update.lockPostback == false)
    }
}
#endif
