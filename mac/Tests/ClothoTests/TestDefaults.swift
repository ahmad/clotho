import Foundation

/// Private UserDefaults suites for tests, kept out of ~/Library/Preferences. A suite named by an
/// absolute path is stored at that path (plus ".plist"), so each test's suite lives in this user's temp
/// folder. Removing a suite from ~/Library/Preferences doesn't work: cfprefsd writes an empty plist back
/// after the test deletes it, so every run used to leave one file per suite there.
enum TestDefaults {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clotho-test-defaults")

    /// A fresh suite name (an absolute path) for `UserDefaults(suiteName:)`.
    static func name(_ prefix: String) -> String {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("clotho-\(prefix)-test-\(UUID().uuidString)").path
    }

    static func remove(_ suite: String) {
        guard suite.hasPrefix(folder.path + "/") else { return }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }
}
