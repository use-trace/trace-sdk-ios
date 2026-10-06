import Foundation
import os

/// The install scoped anonymous key this SDK sends as `anon_user_key`.
///
/// A random `UUID` with the hyphens removed and lowercased, behind `auk_`, the prefix the server uses for its own
/// anonymous keys, and `app_` to say where it came from. It is derived from nothing about the device: no advertising
/// identifier, no vendor identifier, no fingerprint, so two installs on the same phone are two different people as
/// far as Trace is concerned, which is the correct answer.
///
/// **It does not survive an uninstall.** It lives in one file in Application Support, excluded from backup (see
/// ``Storage``). An install id that came back after a reinstall would count the reinstall as the same install, and
/// would quietly join a person back to history they may consider finished when they removed the app. A reinstall
/// mints a fresh id and counts as a new install.
///
/// The id is a visitor identity, so it is never logged, and nothing here logs.
enum InstallId {

    static let fileName = "install_id"

    private static let minting = OSAllocatedUnfairLock()

    /// This install's id, minted and persisted on the first call.
    ///
    /// Safe from any thread. If the write fails it still returns an id, because an event with an id the SDK could
    /// not keep is better than a crash in someone else's app; the next launch mints a fresh one.
    static func get(in directory: URL = Storage.defaultDirectory) -> String {
        minting.withLock {
            if let existing = peek(in: directory) { return existing }
            let id = "auk_app_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            try? Storage.write(Data(id.utf8), to: directory.appending(path: fileName))
            return id
        }
    }

    /// This install's id, or nil when there is not one yet. Reading never creates one.
    ///
    /// This is what reporting a refusal uses, so that saying no to tracking never mints the identifier just declined.
    /// A half written or unreadable file reads as no id.
    static func peek(in directory: URL = Storage.defaultDirectory) -> String? {
        guard let data = try? Data(contentsOf: directory.appending(path: fileName)) else { return nil }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
