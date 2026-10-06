import Foundation

/// A fresh directory for one test, so no test reads or writes the real Application Support and no two tests share
/// a file. Left for the system to clear: it holds only synthetic ids.
func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "trace-sdk-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Reads the backup exclusion back from disk through a URL that has never cached it, so the answer is what the file
/// says, not what a setter remembered.
func isExcludedFromBackup(_ file: URL) throws -> Bool? {
    var fresh = URL(filePath: file.path)
    fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
}
