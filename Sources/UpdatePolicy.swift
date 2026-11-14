import Foundation

// Pure update-check logic: versions, parsing the GitHub response, and when to show what.
// Foundation only — so the test builds without the rest of the app.

/// A version like 1.10.0: compare numbers, not strings, so 1.10.0 > 1.9.0.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    /// Has a suffix like "-beta" — a prerelease, we don't offer it.
    let prerelease: Bool

    /// "v1.2.3", "1.2", "1.2.3-beta.1", "1.2.3+build". Anything else — nil.
    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre = false
        if let dash = s.firstIndex(of: "-") { pre = true; s = String(s[..<dash]) }
        let nums = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.count <= 4, nums.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        parts = nums.map { $0! }
        prerelease = pre
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    /// 1.2 == 1.2.0. A prerelease is lower than the release of the same version.
    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return a.prerelease && !b.prerelease
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A release on GitHub. The DMG and its sha256 are for auto-install.
struct ReleaseInfo: Codable, Equatable {
    var version: String        // without "v": 1.2.0
    var tag: String            // as on GitHub: v1.2.0
    var url: URL               // release page
    var dmgURL: URL?
    var dmgSHA256: String?
    var publishedAt: Date?
    /// DMG signature with the developer key (Lynx-Battery-<v>.dmg.sig). Without it there's no auto-install.
    var sigURL: URL? = nil
}

enum UpdatePolicy {
    static let owner = "Mansfera"
    static let repo = "lynx-battery"
    static var latestURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")! }
    /// How often to ask GitHub. Without a token the limit is 60 requests per hour per IP; we make ~3 a day.
    static let interval: TimeInterval = 8 * 3600
    /// Between launches, no more often than this when there is no cache yet. Every launch checks regardless.
    static let minInterval: TimeInterval = 3600

    /// Newer than the current one. Prereleases and unparseable versions — no.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = AppVersion(latest), !l.prerelease, let c = AppVersion(current) else { return false }
        return l > c
    }

    /// Banner in the popover: checking is on, the version is newer and it wasn't dismissed.
    static func showBanner(_ r: ReleaseInfo?, current: String, checkOn: Bool, dismissed: String?) -> Bool {
        guard checkOn, let r, isNewer(r.version, than: current) else { return false }
        return dismissed.map { AppVersion($0) != AppVersion(r.version) } ?? true
    }

    /// One alert per new version.
    static func shouldAlert(_ r: ReleaseInfo?, current: String, checkOn: Bool, alertsOn: Bool, alerted: String?) -> Bool {
        guard checkOn, alertsOn, let r, isNewer(r.version, than: current) else { return false }
        return alerted.map { AppVersion($0) != AppVersion(r.version) } ?? true
    }

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = UpdatePolicy.interval) -> Bool {
        guard let last = lastCheck, last <= now else { return true }   // the clock was set back — also time to check
        return now.timeIntervalSince(last) >= interval
    }

    /// The /releases/latest response. Drafts and prereleases are rejected, even though GitHub doesn't return them here.
    static func parse(_ data: Data) -> ReleaseInfo? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Release: Decodable {
            let tag_name: String; let html_url: URL; let draft: Bool?; let prerelease: Bool?
            let published_at: String?; let assets: [Asset]?
        }
        guard let r = try? JSONDecoder().decode(Release.self, from: data),
              r.draft != true, r.prerelease != true,
              let v = AppVersion(r.tag_name), !v.prerelease else { return nil }
        let dmg = r.assets?.first { $0.name.hasSuffix(".dmg") }
        let sha = dmg?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        let sig = dmg.flatMap { d in r.assets?.first { $0.name == d.name + ".sig" } }
        return ReleaseInfo(version: v.description, tag: r.tag_name, url: r.html_url,
                           dmgURL: dmg?.browser_download_url, dmgSHA256: sha,
                           publishedAt: r.published_at.flatMap { ISO8601DateFormatter().date(from: $0) },
                           sigURL: sig?.browser_download_url)
    }

    static func isSHA256(_ s: String) -> Bool { s.utf8.count == 64 && s.allSatisfy(\.isHexDigit) }

    static let caskrooms = ["/opt/homebrew/Caskroom/lynx-battery", "/usr/local/Caskroom/lynx-battery"]

    /// Installed via the cask: brew updates it, otherwise it won't know which version is installed.
    static func isHomebrewInstall(caskrooms: [String] = caskrooms, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        caskrooms.contains(where: exists)
    }

    /// Whether we can install this release ourselves at all: there's a key, a signature, a digest, and it's not a cask.
    static func canInstall(_ r: ReleaseInfo?, keyPresent: Bool, homebrew: Bool) -> Bool {
        guard let r, keyPresent, !homebrew else { return false }
        return r.dmgURL != nil && r.sigURL != nil && r.dmgSHA256.map(isSHA256) == true
    }

    /// Auto-install: one attempt per version per launch, then the banner and the alert.
    static func shouldAutoInstall(_ r: ReleaseInfo?, current: String, checkOn: Bool, autoOn: Bool,
                                  keyPresent: Bool, homebrew: Bool, attempted: Set<String>) -> Bool {
        guard checkOn, autoOn, let r, isNewer(r.version, than: current),
              canInstall(r, keyPresent: keyPresent, homebrew: homebrew) else { return false }
        return !attempted.contains(r.version)
    }
}
