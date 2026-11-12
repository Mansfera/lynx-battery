import Foundation

// Чиста логіка перевірки оновлень: версії, розбір відповіді GitHub і коли що показувати.
// Лише Foundation — щоб тест збирався без решти апки.

/// Версія на кшталт 1.10.0: порівнюємо числа, а не рядки, тож 1.10.0 > 1.9.0.
struct AppVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    /// Є суфікс «-beta» тощо — пререліз, його не пропонуємо.
    let prerelease: Bool

    /// «v1.2.3», «1.2», «1.2.3-beta.1», «1.2.3+build». Решта — nil.
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

    /// 1.2 == 1.2.0. Пререліз нижчий за реліз тієї ж версії.
    static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return a.prerelease && !b.prerelease
    }

    static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }
}

/// Реліз на GitHub. DMG і його sha256 — для автовстановлення (LYN-13).
struct ReleaseInfo: Codable, Equatable {
    var version: String        // без «v»: 1.2.0
    var tag: String            // як на GitHub: v1.2.0
    var url: URL               // сторінка релізу
    var dmgURL: URL?
    var dmgSHA256: String?
    var publishedAt: Date?
    /// Підпис DMG ключем розробника (Lynx-Battery-<v>.dmg.sig). Без нього автовстановлення немає.
    var sigURL: URL? = nil
}

enum UpdatePolicy {
    static let owner = "Mansfera"
    static let repo = "lynx-battery"
    static var latestURL: URL { URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")! }
    /// Як часто питати GitHub. Без токена ліміт — 60 запитів на годину з IP, ми робимо ~3 на добу.
    static let interval: TimeInterval = 8 * 3600
    /// Не частіше за це навіть після перезапуску апки.
    static let minInterval: TimeInterval = 3600

    /// Новіша за поточну. Пререліз і нерозбірні версії — ні.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = AppVersion(latest), !l.prerelease, let c = AppVersion(current) else { return false }
        return l > c
    }

    /// Банер у поповері: перевірка ввімкнена, версія новіша й її не закрили.
    static func showBanner(_ r: ReleaseInfo?, current: String, checkOn: Bool, dismissed: String?) -> Bool {
        guard checkOn, let r, isNewer(r.version, than: current) else { return false }
        return dismissed.map { AppVersion($0) != AppVersion(r.version) } ?? true
    }

    /// Сповіщення — одне на кожну нову версію.
    static func shouldAlert(_ r: ReleaseInfo?, current: String, checkOn: Bool, alertsOn: Bool, alerted: String?) -> Bool {
        guard checkOn, alertsOn, let r, isNewer(r.version, than: current) else { return false }
        return alerted.map { AppVersion($0) != AppVersion(r.version) } ?? true
    }

    static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = UpdatePolicy.interval) -> Bool {
        guard let last = lastCheck, last <= now else { return true }   // годинник перевели назад — теж час
        return now.timeIntervalSince(last) >= interval
    }

    /// Відповідь /releases/latest. Чернетки й пререлізи відкидаємо, хоч GitHub їх тут і не віддає.
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

    /// Встановлено через cask: оновлює brew, інакше він не знатиме, яка версія стоїть.
    static func isHomebrewInstall(caskrooms: [String] = caskrooms, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        caskrooms.contains(where: exists)
    }

    /// Чи можна взагалі встановити цей реліз самим: є ключ, підпис, дайджест, і це не cask.
    static func canInstall(_ r: ReleaseInfo?, keyPresent: Bool, homebrew: Bool) -> Bool {
        guard let r, keyPresent, !homebrew else { return false }
        return r.dmgURL != nil && r.sigURL != nil && r.dmgSHA256.map(isSHA256) == true
    }

    /// Автовстановлення: одна спроба на версію за запуск, далі — банер і сповіщення.
    static func shouldAutoInstall(_ r: ReleaseInfo?, current: String, checkOn: Bool, autoOn: Bool,
                                  keyPresent: Bool, homebrew: Bool, attempted: Set<String>) -> Bool {
        guard checkOn, autoOn, let r, isNewer(r.version, than: current),
              canInstall(r, keyPresent: keyPresent, homebrew: homebrew) else { return false }
        return !attempted.contains(r.version)
    }
}
