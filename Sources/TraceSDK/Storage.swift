import Foundation

/// Where the SDK keeps the little it keeps on disk: the install id, and the events held until consent is known.
///
/// **Application Support, with every file marked excluded from backup.** Not the Keychain: Keychain items survive
/// the app being deleted on iOS, so anything kept there would outlive an uninstall. Not `UserDefaults` either: it is
/// deleted with the app, but it is backed up, and it cannot be excluded key by key. The app's container is deleted
/// with the app, and the resource value keeps these files out of iCloud and device backups, so a backup restored
/// onto a later install cannot bring an install id back.
enum Storage {

    /// The SDK's own directory inside Application Support. Created on the first write, not before.
    static let defaultDirectory: URL = URL.applicationSupportDirectory.appending(path: "io.usetrace.sdk", directoryHint: .isDirectory)

    /// Writes `data` to `file` whole, creating the directory if it is missing, and marks the file excluded from
    /// backup. The mark is set after every write because an atomic write replaces the file, and a replaced file
    /// does not keep the old one's resource values.
    static func write(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
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
