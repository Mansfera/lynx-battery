import Foundation

/// Where the app keeps its data, and migration from the old name (Etherlynx Battery, xyz.etherlynx.battery).
enum AppData {
    static let bundleID = "com.mansfera.lynxbattery"
    static let legacyBundleID = "xyz.etherlynx.battery"

    private static var support: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var dir: URL { support.appendingPathComponent(bundleID, isDirectory: true) }
    private static var legacyDir: URL { support.appendingPathComponent("Etherlynx Battery", isDirectory: true) }

    /// Before the first access to Settings and the history files. Limit settings are migrated by the helper install: their folder belongs to root.
    static func migrate() {
        migratePreferences(from: legacyBundleID, to: bundleID)
        migrateFolder(from: legacyDir, to: dir)
    }

    static func migratePreferences(from old: String, to new: String) {
        let d = UserDefaults.standard
        guard d.persistentDomain(forName: new)?.isEmpty != false,
              let values = d.persistentDomain(forName: old), !values.isEmpty else { return }
        d.setPersistentDomain(values, forName: new)
    }

    static func migrateFolder(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do { try fm.moveItem(at: old, to: new) }
        catch { NSLog("Lynx Battery: couldn't move \(old.path): \(error.localizedDescription)") }
    }
}
