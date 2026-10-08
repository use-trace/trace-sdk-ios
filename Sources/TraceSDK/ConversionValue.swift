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

/// Trace's conversion value schema, version 1: what the SDK tells Apple about an install, and what the server reads
/// back out of Apple's postbacks. Decided 7 October 2026 (decision 8 of `docs/plans/APP_MODELLED_INSTALLS.md` in
/// `use-trace/trace`): one schema Trace defines, the same for every app, versioned.
///
/// **The server implements the same schema** (`apps/api/src/app-reports/conversion-value-schema.ts`), and both pass
/// `conversion-value-vectors.json`, copied into both repositories. A postback does not say which schema produced it,
/// so a change here is a new ``version``, released with a date the server knows, never an edit to version 1.
///
/// - Windows are Apple's: hours 0 to 48 after the first launch, 48 to 168, and 168 to 840. After 840 nothing is set.
/// - Window 1 carries a fine value. 0: opened, nothing else. 1: at least one conversion and no revenue. 2: revenue
///   below the first edge. 3 to 63: revenue at or above each edge in ``fineBandLowerEdges`` in turn, so 63 holds
///   everything from 1000 up.
/// - Every window carries a coarse value from its own conversions: `low` none, `high` revenue at or above
///   ``highRevenue``, `medium` otherwise. Windows 2 and 3 carry the coarse value only.
/// - A conversion is a `Trace.conversion` call and its `value` is revenue, in the site's currency. A value that is
///   missing, zero, negative or not a number is a conversion with no revenue: refunds are not subtracted.
enum ConversionValueSchema {

    static let version = 1

    /// When each window ends, in seconds after the first launch.
    static let windowEnds: [TimeInterval] = [48, 168, 840].map { $0 * 3600 }

    /// The R20 preferred numbers (ISO 3) from 1 to 1000: about 12 per cent apart, round, and with the usual prices
    /// (0.99, 4.99, 9.99) just below an edge rather than on one. The site's currency, whichever it is.
    static let fineBandLowerEdges: [Double] = [
        1.00, 1.12, 1.25, 1.40, 1.60, 1.80, 2.00, 2.24, 2.50, 2.80, 3.15, 3.55, 4.00, 4.50, 5.00, 5.60, 6.30, 7.10, 8.00, 9.00,
        10.0, 11.2, 12.5, 14.0, 16.0, 18.0, 20.0, 22.4, 25.0, 28.0, 31.5, 35.5, 40.0, 45.0, 50.0, 56.0, 63.0, 71.0, 80.0, 90.0,
        100, 112, 125, 140, 160, 180, 200, 224, 250, 280, 315, 355, 400, 450, 500, 560, 630, 710, 800, 900,
        1000,
    ]

    /// Revenue in a window at or above this is coarse `high`. An R20 edge, so a 4.99 purchase is high and 2.99 is not.
    static let highRevenue = 4.50

    /// Which window `elapsed` seconds after the first launch fall in, 0 to 2, or nil once the last has closed.
    static func window(after elapsed: TimeInterval) -> Int? {
        windowEnds.firstIndex { elapsed < $0 }
    }

    static func fine(converted: Bool, revenue: Double) -> Int {
        guard converted else { return 0 }
        guard revenue > 0 else { return 1 }
        return 2 + fineBandLowerEdges.filter { $0 <= revenue }.count
    }

    static func coarse(converted: Bool, revenue: Double) -> CoarseValue {
        guard converted else { return .low }
        return revenue >= highRevenue ? .high : .medium
    }
}

/// The SDK's use of Apple's conversion value: registering the install, then setting the value from conversions by
/// ``ConversionValueSchema``.
///
/// **Registering the install is the most important thing this SDK does on iOS.** Apple sends no postback at all
/// unless the app updates its conversion value at least once, and Apple's own guidance is to do it when the user
/// first launches the app, to register the installation. Without it the campaign behind an install never reaches
/// Trace, because there is no install referrer on iOS and the postback is the only source.
///
/// **Whether it runs at all is ``TraceClient``'s decision.** The legal adviser's answer, decided by Dom on 8 October
/// 2026: registering and the two files are storage on the device, so on a consent gated site they wait for a grant,
/// and a conversion value is set only for someone who said yes. On a US or Other site they run from first launch
/// unless the person refused. A refusal removes both files (``forget()``). Nothing about consent reaches this type.
///
/// **Two files, neither an identifier.** `install_registered` is an empty file,
/// and only its existence is read, so it works even before the phone's first unlock after a reboot, when a
/// protected file's contents cannot be read; it stops a later launch registering again and resetting the value.
/// `conversion_value` is the schema's record: when the install first launched, the window it is in, whether that
/// window has a conversion, its revenue, and whether the host app has taken the value over. Revenue is summed
/// across launches, so it has to be on disk. It is never sent anywhere. Both are excluded from backup.
///
/// The flag and a new record are written only after Apple took the registration, because a missed registration
/// means no postback ever and has to be tried again. After that the record is written before each update, so an
/// update Apple did not take is made good by the next conversion.
///
/// It is safe to call from anywhere; the order of calls is the caller's to keep.
struct ConversionValues: Sendable {

    /// The install has been registered with Apple.
    static let registeredFlag = "install_registered"
    /// The schema's record, ``Record``. 0.1.0 wrote an empty `conversion_value_raised` flag instead, now ignored.
    static let stateFile = "conversion_value"

    /// SKAdNetwork 4 and AdAttributionKit take a fine value of six bits, and StoreKit throws on anything else.
    static let fineRange = 0...63

    struct Record: Codable, Equatable {
        var schema = ConversionValueSchema.version
        /// Seconds since 1970, when Apple took the registration.
        var firstLaunch: Double
        var window = 0
        var converted = false
        var revenue = 0.0
        /// The host app called `setConversionValue`, and from then on the value is the app's.
        var setByApp = false
        /// 0.2.0 only: the server had taken this install's first consent answer. 0.3.0 keeps that in
        /// ``ConsentGate/answerReportedFlag`` and only reads this, so an install that answered under 0.2.0 is not
        /// counted twice.
        var answerReported = false
    }

    /// What a 0.2.0 record says about the first answer. False with no record, nil when the record cannot be read,
    /// which is the phone before its first unlock after a reboot.
    static func answerReported(in directory: URL) -> Bool? {
        guard FileManager.default.fileExists(atPath: directory.appending(path: stateFile).path) else { return false }
        return read(in: directory, log: .silent)?.answerReported
    }

    private let directory: URL
    private let registrar: any ConversionValueRegistrar
    private let log: TraceLog
    private let now: @Sendable () -> Date

    init(directory: URL = Storage.defaultDirectory, registrar: any ConversionValueRegistrar, log: TraceLog = .silent,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.directory = directory
        self.registrar = registrar
        self.log = log
        self.now = now
    }

    /// Every launch. On the first, registers the install, a fine value of 0 and a coarse value of `low`, and starts
    /// the record. On a later one in a new window, starts that window at `low`, once.
    func launched() async {
        if !Storage.flagIsSet(Self.registeredFlag, in: directory) {
            if await update(fine: 0, coarse: .low, reason: "registering the install") {
                Storage.setFlag(Self.registeredFlag, in: directory, log: log)
                keepTheReportedAnswer()
                save(Record(firstLaunch: now().timeIntervalSince1970))
            }
            return
        }
        guard let (record, newWindow) = current(), newWindow else { return }
        save(record)
        await update(fine: 0, coarse: .low, reason: "starting window \(record.window + 1)")
    }

    /// Adds the conversion to its window and sets the value the schema gives the window. Only ever raises it within
    /// a window, because revenue only grows. Nothing once the host app has set its own value.
    func conversionRecorded(value: Double?) async {
        guard var (record, _) = current() else { return }
        record.converted = true
        if let value, value.isFinite, value > 0 { record.revenue += value }
        save(record)
        let fine = record.window == 0 ? ConversionValueSchema.fine(converted: true, revenue: record.revenue) : 0
        await update(fine: fine, coarse: ConversionValueSchema.coarse(converted: true, revenue: record.revenue),
                     reason: "a conversion in window \(record.window + 1)")
    }

    /// After a refusal or a withdrawal: removes the registration flag and the record, so nothing more is set, and a
    /// later grant registers the install again. A 0.2.0 record's reported answer moves to its flag first.
    func forget() {
        keepTheReportedAnswer()
        Storage.remove(Self.registeredFlag, in: directory)
        Storage.remove(Self.stateFile, in: directory)
    }

    // Before a 0.2.0 record is replaced or removed, its reported answer moves to the flag 0.3.0 keeps it in.
    private func keepTheReportedAnswer() {
        if Self.answerReported(in: directory) == true {
            Storage.setFlag(ConsentGate.answerReportedFlag, in: directory, log: log)
        }
    }

    /// The host app's own value, for its own schema. A fine value outside 0 to 63 is refused with a log line rather
    /// than passed to StoreKit to throw. From then on the SDK leaves the value alone, in every later launch too.
    func set(fine: Int, coarse: CoarseValue) async {
        guard Self.fineRange.contains(fine) else {
            log.log("a fine conversion value must be 0 to 63, and \(fine) is not, so it was not set")
            return
        }
        if await update(fine: fine, coarse: coarse, reason: "setting the app's own value"), var record = read() {
            record.setByApp = true
            save(record)
        }
    }

    /// The record, moved on to the window `now` falls in, and whether that is a new window. Nil when there is
    /// nothing to set: no record (an install 0.1.0 registered, whose first launch is unknown), one that cannot be
    /// read yet, a value the host app owns, or the last window closed.
    private func current() -> (Record, Bool)? {
        guard var record = read(), !record.setByApp,
              let window = ConversionValueSchema.window(after: now().timeIntervalSince1970 - record.firstLaunch)
        else { return nil }
        // A clock set back does not reopen a closed window.
        guard window > record.window else { return (record, false) }
        record = Record(firstLaunch: record.firstLaunch, window: window, answerReported: record.answerReported)
        return (record, true)
    }

    private func read() -> Record? { Self.read(in: directory, log: log) }

    private func save(_ record: Record) { Self.save(record, in: directory, log: log) }

    private static func read(in directory: URL, log: TraceLog) -> Record? {
        let file = directory.appending(path: stateFile)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        // ponytail: before the first unlock after a reboot this cannot be read, and a conversion then is left out of
        // the value. Only a background launch hits it; keep the conversion in memory for the next call if it matters.
        guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(Record.self, from: data) else {
            log.log("the conversion value record cannot be read yet, so the value was left as it was")
            return nil
        }
        return record
    }

    private static func save(_ record: Record, in directory: URL, log: TraceLog) {
        do {
            try Storage.write(JSONEncoder().encode(record), to: directory.appending(path: stateFile))
        } catch {
            log.log("could not record the conversion value, so the next update may not include this one")
        }
    }

    // Never throws. A StoreKit error is the SDK's problem, not the host app's: it is logged and swallowed.
    @discardableResult
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
/// `Postback.updateConversionValue(_:coarseConversionValue:lockPostback:) async throws`, iOS 17.4, and
/// `Postback.updateConversionValue(_: PostbackUpdate) async throws`, iOS 18.0.
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
                if #available(iOS 18.0, *) {
                    try await Postback.updateConversionValue(Self.installUpdate(fine: fine, coarse: coarse))
                } else {
                    try await Postback.updateConversionValue(fine, coarseConversionValue: coarse.adAttributionKit, lockPostback: false)
                }
            } catch {
                failure = failure ?? error
            }
        }
        if let failure { throw failure }
    }

    /// For the install's postbacks only. iOS 18 added re-engagement postbacks, and an update that names no conversion
    /// type goes to those as well; the schema sets no value for a re-engagement in version 1. Before iOS 18 there
    /// are none, so the older call is the same thing.
    @available(iOS 18.0, *)
    static func installUpdate(fine: Int, coarse: CoarseValue) -> PostbackUpdate {
        PostbackUpdate(fineConversionValue: fine, lockPostback: false, coarseConversionValue: coarse.adAttributionKit,
                       conversionTypes: [.install])
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
