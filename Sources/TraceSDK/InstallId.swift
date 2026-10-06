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

    /// What is on disk: no id yet, an id, or a file that exists and cannot be read.
    enum Stored: Equatable {
        case absent
        case present(String)
        /// The file is there and its contents cannot be read. On iOS this is the phone before its first unlock
        /// after a reboot, with the app launched in the background by a push or a background refresh.
        case unreadable
    }

    /// This install's id, minted and persisted on the first call, or nil when there is an id that cannot be read.
    ///
    /// **Only an absent file mints an id.** A file that exists and cannot be read already holds this install's id,
    /// and replacing it would make one install two: double counted, with its journey split across them, which is
    /// worse than sending nothing. So nil, and the caller holds everything and tries again on its next call.
    ///
    /// Nil too when a new id cannot be stored, because an id that is not on disk is a different id on the next
    /// launch, which is the same double count by another route. Safe from any thread.
    static func get(in directory: URL = Storage.defaultDirectory) -> String? {
        minting.withLock {
            switch read(in: directory) {
            case .present(let id):
                return id
            case .unreadable:
                return nil
            case .absent:
                let id = "auk_app_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                do {
                    try Storage.write(Data(id.utf8), to: directory.appending(path: fileName))
                } catch {
                    return nil
                }
                return id
            }
        }
    }

    /// This install's id, or nil when there is not one yet or it cannot be read. Reading never creates one.
    ///
    /// This is what reporting a refusal uses, so that saying no to tracking never mints the identifier just declined.
    static func peek(in directory: URL = Storage.defaultDirectory) -> String? {
        if case .present(let id) = read(in: directory) { return id }
        return nil
    }

    /// Whether the file is absent is decided by its existence, which can be seen on a locked phone, and only then
    /// is it read. An empty file, which an atomic write never leaves, reads as absent.
    static func read(in directory: URL = Storage.defaultDirectory) -> Stored {
        let file = directory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        guard let data = try? Data(contentsOf: file) else { return .unreadable }
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? .absent : .present(id)
    }
}
