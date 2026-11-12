import Foundation

// Перевірка оновлень: порівняння версій, розбір відповіді GitHub, коли показувати банер і сповіщення.
// Лише чиста логіка: без мережі, без Settings і без UserDefaults.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}

// Версії
check("1.10.0 is newer than 1.9.0", UpdatePolicy.isNewer("1.10.0", than: "1.9.0"), true)
check("1.9.0 isn't newer than 1.10.0", UpdatePolicy.isNewer("1.9.0", than: "1.10.0"), false)
check("v prefix is ignored", UpdatePolicy.isNewer("v1.1.6", than: "1.1.5"), true)
check("same version isn't newer", UpdatePolicy.isNewer("v1.1.5", than: "1.1.5"), false)
check("1.2 equals 1.2.0", UpdatePolicy.isNewer("1.2", than: "1.2.0"), false)
check("1.2.1 is newer than 1.2", UpdatePolicy.isNewer("1.2.1", than: "1.2"), true)
check("2.0.0 is newer than 1.99.99", UpdatePolicy.isNewer("2.0.0", than: "1.99.99"), true)
check("an older release isn't offered", UpdatePolicy.isNewer("1.1.4", than: "1.1.5"), false)
check("a prerelease isn't offered", UpdatePolicy.isNewer("1.2.0-beta.1", than: "1.1.5"), false)
check("build metadata is ignored", UpdatePolicy.isNewer("1.2.0+42", than: "1.1.5"), true)
check("garbage isn't newer", UpdatePolicy.isNewer("latest", than: "1.1.5"), false)
check("garbage current never alerts", UpdatePolicy.isNewer("9.9.9", than: ""), false)
check("prerelease sorts below its release", AppVersion("1.2.0-rc1")! < AppVersion("1.2.0")!, true)

// Розбір відповіді
func json(tag: String, draft: Bool = false, pre: Bool = false, assets: String = "[]") -> Data {
    """
    {"tag_name":"\(tag)","html_url":"https://github.com/Mansfera/lynx-battery/releases/tag/\(tag)",
     "draft":\(draft),"prerelease":\(pre),"published_at":"2026-11-02T22:11:26Z","assets":\(assets)}
    """.data(using: .utf8)!
}
let dmg = """
[{"name":"notes.txt","browser_download_url":"https://example.invalid/notes.txt"},
 {"name":"Lynx-Battery-1.2.0.dmg","browser_download_url":"https://github.com/Mansfera/lynx-battery/releases/download/v1.2.0/Lynx-Battery-1.2.0.dmg","digest":"sha256:abc123"}]
"""
let r = UpdatePolicy.parse(json(tag: "v1.2.0", assets: dmg))
check("parses the version without v", r?.version, "1.2.0")
check("keeps the tag", r?.tag, "v1.2.0")
check("release page URL", r?.url.absoluteString, "https://github.com/Mansfera/lynx-battery/releases/tag/v1.2.0")
check("finds the DMG", r?.dmgURL?.lastPathComponent, "Lynx-Battery-1.2.0.dmg")
check("reads the DMG digest", r?.dmgSHA256, "abc123")
check("reads the publish date", r?.publishedAt != nil, true)
check("a draft is skipped", UpdatePolicy.parse(json(tag: "v1.3.0", draft: true)) == nil, true)
check("a prerelease is skipped", UpdatePolicy.parse(json(tag: "v1.3.0", pre: true)) == nil, true)
check("a -beta tag is skipped", UpdatePolicy.parse(json(tag: "v1.3.0-beta")) == nil, true)
check("no assets is fine", UpdatePolicy.parse(json(tag: "1.3.0"))?.dmgURL == nil, true)
check("an error body isn't a release", UpdatePolicy.parse(#"{"message":"Not Found"}"#.data(using: .utf8)!) == nil, true)
check("junk isn't a release", UpdatePolicy.parse(Data("<html>".utf8)) == nil, true)

// Банер і сповіщення
let rel = r!
check("banner for a newer version", UpdatePolicy.showBanner(rel, current: "1.1.5", checkOn: true, dismissed: nil), true)
check("no banner with checks off", UpdatePolicy.showBanner(rel, current: "1.1.5", checkOn: false, dismissed: nil), false)
check("no banner once up to date", UpdatePolicy.showBanner(rel, current: "1.2.0", checkOn: true, dismissed: nil), false)
check("no banner for a dismissed version", UpdatePolicy.showBanner(rel, current: "1.1.5", checkOn: true, dismissed: "1.2.0"), false)
check("banner again for the next version", UpdatePolicy.showBanner(rel, current: "1.1.5", checkOn: true, dismissed: "1.1.9"), true)
check("no banner without a release", UpdatePolicy.showBanner(nil, current: "1.1.5", checkOn: true, dismissed: nil), false)

check("alert for a new version", UpdatePolicy.shouldAlert(rel, current: "1.1.5", checkOn: true, alertsOn: true, alerted: nil), true)
check("alert only once per version", UpdatePolicy.shouldAlert(rel, current: "1.1.5", checkOn: true, alertsOn: true, alerted: "1.2.0"), false)
check("v1.2 alerted counts as 1.2.0", UpdatePolicy.shouldAlert(rel, current: "1.1.5", checkOn: true, alertsOn: true, alerted: "v1.2"), false)
check("alert again for the next version", UpdatePolicy.shouldAlert(rel, current: "1.1.5", checkOn: true, alertsOn: true, alerted: "1.1.6"), true)
check("no alert with alerts off", UpdatePolicy.shouldAlert(rel, current: "1.1.5", checkOn: true, alertsOn: false, alerted: nil), false)
check("no alert with checks off", UpdatePolicy.shouldAlert(rel, current: "1.1.5", checkOn: false, alertsOn: true, alerted: nil), false)
check("no alert when up to date", UpdatePolicy.shouldAlert(rel, current: "1.2.0", checkOn: true, alertsOn: true, alerted: nil), false)
check("no alert when ahead (dev build)", UpdatePolicy.shouldAlert(rel, current: "1.3.0", checkOn: true, alertsOn: true, alerted: nil), false)

// Коли питати GitHub
let now = Date(timeIntervalSince1970: 1_800_000_000)
check("due on first run", UpdatePolicy.isDue(lastCheck: nil, now: now), true)
check("not due an hour later", UpdatePolicy.isDue(lastCheck: now - 3600, now: now), false)
check("due after 8 hours", UpdatePolicy.isDue(lastCheck: now - 8 * 3600, now: now), true)
check("due if the clock went back", UpdatePolicy.isDue(lastCheck: now + 3600, now: now), true)
check("an hour is the floor without a cache", UpdatePolicy.isDue(lastCheck: now - 1800, now: now, interval: UpdatePolicy.minInterval), false)

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
