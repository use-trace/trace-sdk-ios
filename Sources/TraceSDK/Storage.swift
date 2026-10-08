import Foundation

/// Where the SDK keeps the little it keeps on disk: the install id, a few flags and the conversion value record. The
/// install id and the first open flag are written only once the person has granted consent. The two Apple files,
/// the registration flag and the conversion value record, hold no identifier; on a consent gated site they wait for a
/// grant, on a site that is not gated they are written at first launch, and a refusal removes them (see
/// ``TraceClient``).
///
/// **Application Support, with every file marked excluded from backup.** Not the Keychain: Keychain items survive
/// the app being deleted on iOS, so anything kept there would outlive an uninstall. Not `UserDefaults` either: it is
/// deleted with the app, but it is backed up, and it cannot be excluded key by key. The app's container is deleted
/// with the app, and the resource value keeps these files out of iCloud and device backups, so a backup restored
/// onto a later install cannot bring an install id back.
enum Storage {

    /// The SDK's own directory inside Application Support. Created on the first write, not before.
    static let defaultDirectory: URL = URL.applicationSupportDirectory.appending(path: "io.usetrace.sdk", directoryHint: .isDirectory)

    /// Atomic, and protected until the first unlock after a boot. Chosen, not left to the default.
    ///
    /// `completeUntilFirstUserAuthentication`: encrypted at rest, and readable from the first unlock after a boot
    /// until the next shutdown, locked or not. `complete` would make the install id unreadable every time the phone
    /// locks, so a send finishing in the background on a locked phone would find no id. `none` would leave a visitor
    /// identity unencrypted on the disk. The price of this level is the window between a boot and the first unlock,
    /// when the file exists and cannot be read; ``InstallId/get(in:)`` sends and mints nothing in that window rather
    /// than treat the unreadable id as a missing one.
    static let writingOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    /// Writes `data` to `file` whole, creating the directory if it is missing, and marks the file excluded from
    /// backup. The mark is set after every write because an atomic write replaces the file, and a replaced file
    /// does not keep the old one's resource values.
    static func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: writingOptions)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var file = file
        try file.setResourceValues(values)
    }

    /// Whether the flag file exists. Only its existence is read, never its contents, and a file's existence can be
    /// seen even before the phone's first unlock after a reboot, when its contents cannot.
    static func flagIsSet(_ name: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path)
    }

    /// Removes the file if it is there. Never throws: a file that could not be removed is removed by the next call.
    static func remove(_ name: String, in directory: URL) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }

    /// Creates the flag file, empty and excluded from backup like everything else here. Never throws: a flag that
    /// could not be written means the work it records is done again later, which each caller is built to survive.
    static func setFlag(_ name: String, in directory: URL, log: TraceLog) {
        do {
            try write(Data(), to: directory.appending(path: name))
        } catch {
            log.log("could not record \(name), so it may be done again")
        }
    }
}
