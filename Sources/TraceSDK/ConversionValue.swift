import Foundation
#if os(iOS)
import AdAttributionKit
import StoreKit
#endif

/// The coarse conversion value Apple's postbacks carry when a fine value would be too identifying to send.
public enum CoarseValue: String, Sendable {
    case low
    case medium
    case high
}

/// Updates the conversion value Apple holds for this install. A protocol so the tests can stand in for StoreKit;
/// the only conformer in the SDK on iOS is ``StoreKitRegistrar``.
protocol ConversionValueRegistrar: Sendable {
    /// Throws whatever StoreKit throws. ``ConversionValues`` is the only caller, and it catches.
    func update(fine: Int, coarse: CoarseValue) async throws
}

/// The SDK's use of Apple's conversion value: registering the install, and raising the value on a conversion.
///
/// **Registering the install is the most important thing this SDK does on iOS.** Apple sends no postback at all
/// unless the app updates its conversion value at least once, and Apple's own guidance is to do it when the user
/// first launches the app, to register the installation. Without it the campaign behind an install never reaches
/// Trace, because there is no install referrer on iOS and the postback is the only source.
///
/// **It does not need Trace consent, and it does not wait for it.** It sends nothing to Trace and no identity to
/// anyone. It tells Apple's own privacy preserving attribution system, on the device, that the app has launched;
/// Apple then decides on its own terms whether, when and how coarsely to report the campaign, with no identifier
/// for the person. No install id, no event and nothing from the consent gate is involved, and that is why it runs
/// whatever the person answered on the banner.
///
/// The flags are files beside the install id, excluded from backup like it, and only their existence is read, so
/// they work even before the phone's first unlock after a reboot, when a protected file's contents cannot be read.
/// A flag is set only after Apple took the update: a registration that failed is tried again on the next launch,
/// because a missed one means no postback ever.
///
/// **The flags are written whatever the consent state** (decided 6 October 2026). They are the one thing the SDK
/// stores before an answer, and they hold no identifier: each is an empty file saying what the SDK has told Apple.
/// They are on disk so that a later launch does not register again, which would reset the value to fine 0, coarse
/// `low` and could undo a value the host app set. Kept in memory, they were lost with the process, and a person who
/// never answered had their install registered again on every launch.
///
/// It is safe to call from anywhere; the order of calls is the caller's to keep.
struct ConversionValues: Sendable {

    /// The install has been registered with Apple.
    static let registeredFlag = "install_registered"
    /// The value has moved past the registration: raised by a conversion, or set by the host app, which from then
    /// on owns it.
    static let raisedFlag = "conversion_value_raised"

    /// SKAdNetwork 4 and AdAttributionKit take a fine value of six bits, and StoreKit throws on anything else.
    static let fineRange = 0...63

    private let directory: URL
    private let registrar: any ConversionValueRegistrar
    private let log: TraceLog

    init(directory: URL = Storage.defaultDirectory, registrar: any ConversionValueRegistrar, log: TraceLog = .silent) {
        self.directory = directory
        self.registrar = registrar
        self.log = log
    }

    /// On the first launch, a fine value of 0 and a coarse value of `low`. Never again once Apple has taken it.
    func registerInstall() async {
        guard !flagIsSet(Self.registeredFlag) else { return }
        if await update(fine: 0, coarse: .low, reason: "registering the install") {
            setFlag(Self.registeredFlag)
        }
    }

    /// The first conversion moves the coarse value to `medium`, so a postback can tell installs that converted from
    /// installs that did not. Later conversions, and any after the host app set its own value, change nothing.
    ///
    /// The per customer schema, how a customer maps their own events onto six bits, is its own slice. This is the
    /// basic one: it guarantees postbacks flow and says one thing about the install.
    func conversionRecorded() async {
        guard !flagIsSet(Self.raisedFlag) else { return }
        if await update(fine: 0, coarse: .medium, reason: "raising it for a conversion") {
            setFlag(Self.raisedFlag)
        }
    }

    /// The host app's own value, for its own schema. A fine value outside 0 to 63 is refused with a log line rather
    /// than passed to StoreKit to throw.
    func set(fine: Int, coarse: CoarseValue) async {
        guard Self.fineRange.contains(fine) else {
            log.log("a fine conversion value must be 0 to 63, and \(fine) is not, so it was not set")
            return
        }
        if await update(fine: fine, coarse: coarse, reason: "setting the app's own value") {
            setFlag(Self.raisedFlag)
        }
    }

    private func flagIsSet(_ flag: String) -> Bool {
        Storage.flagIsSet(flag, in: directory)
    }

    private func setFlag(_ flag: String) {
        Storage.setFlag(flag, in: directory, log: log)
    }

    // Never throws. A StoreKit error is the SDK's problem, not the host app's: it is logged and swallowed.
    private func update(fine: Int, coarse: CoarseValue, reason: String) async -> Bool {
        do {
            try await registrar.update(fine: fine, coarse: coarse)
            log.log("conversion value \(fine) \(coarse.rawValue) taken by Apple, \(reason)")
            return true
        } catch {
            let error = error as NSError
            log.log("Apple did not take conversion value \(fine) \(coarse.rawValue) when \(reason): \(error.domain) \(error.code)")
            return false
        }
    }
}

/// Does nothing. Where the SDK is built for anything but iOS, which is only ever to run the tests on a Mac.
struct NoRegistrar: ConversionValueRegistrar {
    func update(fine: Int, coarse: CoarseValue) async throws {}
}

#if os(iOS)
/// SKAdNetwork and AdAttributionKit, each where the device has it.
///
/// Signatures checked against the iOS 18.4 simulator SDK's own interfaces:
/// `SKAdNetwork.updatePostbackConversionValue(_:coarseValue:lockWindow:completionHandler:)`, iOS 16.1, and
/// `Postback.updateConversionValue(_:coarseConversionValue:lockPostback:) async throws`, iOS 17.4.
///
/// Neither window is locked: locking would end the measurement window at the first launch, before any conversion
/// could raise the value. On iOS 16.0 neither API with a coarse value exists, so nothing is registered there.
///
/// AdAttributionKit does not exist before iOS 17.4. Every use of it is behind `#available`, so the linker weak links
/// the framework and an app on iOS 16 still launches: checked with `otool -l` on a probe built for iOS 16, which
/// shows `LC_LOAD_WEAK_DYLIB` for it. A use outside `#available` would make that a strong link and crash iOS 16.
///
/// Both are tried even when the first fails, because they are separate systems and either may be the one an ad
/// network uses. The first error is the one thrown.
struct StoreKitRegistrar: ConversionValueRegistrar {

    func update(fine: Int, coarse: CoarseValue) async throws {
        var failure: (any Error)?
        if #available(iOS 16.1, *) {
            do {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                    SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: coarse.skAdNetwork, lockWindow: false) { error in
                        if let error { done.resume(throwing: error) } else { done.resume() }
                    }
                }
            } catch {
                failure = error
            }
        }
        if #available(iOS 17.4, *) {
            do {
                try await Postback.updateConversionValue(fine, coarseConversionValue: coarse.adAttributionKit, lockPostback: false)
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }
}

extension CoarseValue {
    @available(iOS 16.1, *)
    var skAdNetwork: SKAdNetwork.CoarseConversionValue {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    @available(iOS 17.4, *)
    var adAttributionKit: AdAttributionKit.CoarseConversionValue {
        switch self {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }
}
#endif
