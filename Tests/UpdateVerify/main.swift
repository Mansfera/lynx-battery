import Foundation
import CryptoKit

// Перевірка оновлень перед установкою: підпис (тестовим ключем, не справжнім), шляхи запиту, Homebrew, коли ставити самим.
// Без мережі, без root; файли — лише в тимчасовій теці.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}
func throwsError(_ f: () throws -> Void) -> Bool { do { try f(); return false } catch { return true } }

// Підпис
let key = Curve25519.Signing.PrivateKey()
let pub = key.publicKey.rawRepresentation.base64EncodedString()
let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
let sha = UpdateSignature.sha256(Data("a DMG".utf8))
let sig = UpdateSignature.sign(sha256: sha, version: "1.2.0", with: key)!
check("a signature verifies", UpdateSignature.verify(signature: sig, sha256: sha, version: "1.2.0", publicKey: pub), true)
check("v prefix signs the same version", UpdateSignature.verify(signature: sig, sha256: sha, version: "v1.2.0", publicKey: pub), true)
check("uppercase sha256 is the same", UpdateSignature.verify(signature: sig, sha256: sha.uppercased(), version: "1.2.0", publicKey: pub), true)
check("another key is rejected", UpdateSignature.verify(signature: sig, sha256: sha, version: "1.2.0", publicKey: other), false)
check("another DMG is rejected", UpdateSignature.verify(signature: sig, sha256: UpdateSignature.sha256(Data("a DMG!".utf8)), version: "1.2.0", publicKey: pub), false)
check("another version is rejected", UpdateSignature.verify(signature: sig, sha256: sha, version: "1.2.1", publicKey: pub), false)
check("another bundle id is rejected", UpdateSignature.verify(signature: sig, sha256: sha, version: "1.2.0", bundleID: "com.example.app", publicKey: pub), false)
var flipped = sig; flipped[5] ^= 1
check("a flipped signature byte is rejected", UpdateSignature.verify(signature: flipped, sha256: sha, version: "1.2.0", publicKey: pub), false)
check("a short signature is rejected", UpdateSignature.verify(signature: sig.prefix(63), sha256: sha, version: "1.2.0", publicKey: pub), false)
check("an empty public key verifies nothing", UpdateSignature.verify(signature: sig, sha256: sha, version: "1.2.0", publicKey: ""), false)
check("the compiled key is empty or valid", UpdateKey.publicKey.isEmpty || UpdateSignature.publicKey(UpdateKey.publicKey) != nil, true)
check("a prerelease can't be signed", UpdateSignature.sign(sha256: sha, version: "1.3.0-beta", with: key) == nil, true)
check("junk sha256 can't be signed", UpdateSignature.sign(sha256: "abc", version: "1.3.0", with: key) == nil, true)
check("the .sig file parses", UpdateSignature.parseSignatureFile(Data((sig.base64EncodedString() + "\n").utf8)), sig)
check("a junk .sig is rejected", UpdateSignature.parseSignatureFile(Data("hello".utf8)) == nil, true)
check("a short .sig is rejected", UpdateSignature.parseSignatureFile(Data(sig.prefix(32).base64EncodedString().utf8)) == nil, true)
check("private key round trip", UpdateSignature.privateKey(key.rawRepresentation.base64EncodedString())?.publicKey.rawRepresentation, key.publicKey.rawRepresentation)

// Імена й теки
check("DMG name", UpdateInstall.isValidDMGName("Lynx-Battery-1.2.0.dmg"), true)
for bad in ["../Lynx-Battery-1.2.0.dmg", "Lynx-Battery-1.2.0.dmg/x", "Lynx-Battery-1.2.0-beta.dmg", "Lynx-Battery-.dmg",
            "x.dmg", "Lynx-Battery-1.2.0.dmg.sig", "Lynx-Battery-1..2.dmg", "Lynx-Battery-1/2.dmg"] {
    check("DMG name \(bad) is rejected", UpdateInstall.isValidDMGName(bad), false)
}
check("/Applications is allowed", UpdateInstall.helperAllowedParent("/Applications"), true)
check("~/Applications is allowed", UpdateInstall.helperAllowedParent("/Users/someone/Applications"), true)
for bad in ["/Users/../Applications", "/Users//Applications", "/Users/someone/Desktop", "/Applications/Utilities",
            "/tmp", "/Users/a/b/Applications", "Applications", "/Applications/", "/System/Applications"] {
    check("\(bad) isn't allowed", UpdateInstall.helperAllowedParent(bad), false)
}

// Посилання всередині бандла
check("link down inside", UpdateInstall.symlinkStaysInside(rel: "Contents/Frameworks/A.framework/A", dest: "Versions/Current/A"), true)
check("link up within the bundle", UpdateInstall.symlinkStaysInside(rel: "Contents/Resources/x", dest: "../Info.plist"), true)
check("link out of the bundle", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "../../etc"), false)
check("absolute link", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "/etc/passwd"), false)
check("up after down", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "MacOS/.."), false)
check("dot link", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "."), false)

// Файли
let fm = FileManager.default
var tmpl = Array((NSTemporaryDirectory() + "update-verify.XXXXXX").utf8CString)
let root = String(cString: realpath(mkdtemp(&tmpl)!, nil)!)
defer { try? fm.removeItem(atPath: root) }

func makeApp(_ path: String, id: String = UpdateSignature.bundleID, version: String = "1.0.0") {
    try! fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
    let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleShortVersionString": version],
                                                    format: .xml, options: 0)
    fm.createFile(atPath: path + "/Contents/Info.plist", contents: plist)
}
let apps = root + "/Applications"
let app = apps + "/Lynx Battery.app"
makeApp(app)
let allowed: (String) -> Bool = { $0 == apps }
check("a good target passes", throwsError { try UpdateInstall.validateTarget(app, allowedParent: allowed) }, false)
check("a relative target is rejected", throwsError { try UpdateInstall.validateTarget("Applications/Lynx Battery.app", allowedParent: { _ in true }) }, true)
check("a target with .. is rejected", throwsError { try UpdateInstall.validateTarget(apps + "/../Applications/Lynx Battery.app", allowedParent: { _ in true }) }, true)
check("a target with // is rejected", throwsError { try UpdateInstall.validateTarget(root + "//Applications/Lynx Battery.app", allowedParent: { _ in true }) }, true)
check("a target outside the allowed folder is rejected", throwsError { try UpdateInstall.validateTarget(app, allowedParent: { _ in false }) }, true)
check("a missing target is rejected", throwsError { try UpdateInstall.validateTarget(apps + "/Nope.app", allowedParent: allowed) }, true)
try! fm.createSymbolicLink(atPath: root + "/Link", withDestinationPath: apps)
check("a target through a symlinked folder is rejected", throwsError { try UpdateInstall.validateTarget(root + "/Link/Lynx Battery.app", allowedParent: { _ in true }) }, true)
try! fm.createSymbolicLink(atPath: apps + "/Alias.app", withDestinationPath: app)
check("a symlinked app is rejected", throwsError { try UpdateInstall.validateTarget(apps + "/Alias.app", allowedParent: allowed) }, true)
makeApp(apps + "/Other.app", id: "com.example.other")
check("another app is rejected", throwsError { try UpdateInstall.validateTarget(apps + "/Other.app", allowedParent: allowed) }, true)
try! fm.createDirectory(atPath: apps + "/Folder", withIntermediateDirectories: true)
check("a target without .app is rejected", throwsError { try UpdateInstall.validateTarget(apps + "/Folder", allowedParent: allowed) }, true)

let tree = root + "/Tree.app"
makeApp(tree)
check("a clean bundle passes", throwsError { try UpdateInstall.checkBundleTree(tree) }, false)
try! fm.createSymbolicLink(atPath: tree + "/Contents/inside", withDestinationPath: "MacOS")
check("an inside link passes", throwsError { try UpdateInstall.checkBundleTree(tree) }, false)
try! fm.createSymbolicLink(atPath: tree + "/Contents/MacOS/escape", withDestinationPath: "../../../Applications")
check("an escaping link is rejected", throwsError { try UpdateInstall.checkBundleTree(tree) }, true)
try! fm.removeItem(atPath: tree + "/Contents/MacOS/escape")
mkfifo(tree + "/Contents/fifo", 0o644)
check("a FIFO is rejected", throwsError { try UpdateInstall.checkBundleTree(tree) }, true)
try! fm.removeItem(atPath: tree + "/Contents/fifo")
fm.createFile(atPath: tree + "/Contents/MacOS/suid", contents: Data(), attributes: [.posixPermissions: 0o4755])
check("a setuid file is rejected", throwsError { try UpdateInstall.checkBundleTree(tree) }, true)

let files = root + "/files"
try! fm.createDirectory(atPath: files, withIntermediateDirectories: true)
fm.createFile(atPath: files + "/big", contents: Data(count: 100))
check("reads a small file", (try? UpdateInstall.readFile(files + "/big", max: 100))?.count, 100)
check("a file over the limit is rejected", throwsError { _ = try UpdateInstall.readFile(files + "/big", max: 99) }, true)
try! fm.createSymbolicLink(atPath: files + "/link", withDestinationPath: files + "/big")
check("a symlinked file is rejected", throwsError { _ = try UpdateInstall.readFile(files + "/link", max: 1000) }, true)
mkfifo(files + "/fifo", 0o644)
check("a FIFO file is rejected", throwsError { _ = try UpdateInstall.readFile(files + "/fifo", max: 1000) }, true)

// Запит
let reqDir = root + "/req"
try! fm.createDirectory(atPath: reqDir, withIntermediateDirectories: true)
let req = UpdateRequest(id: "abc", version: "1.2.0", dmg: "Lynx-Battery-1.2.0.dmg", sha256: sha, signature: sig.base64EncodedString(),
                        app: app, requestedAt: Date(timeIntervalSince1970: 1_800_000_000))
fm.createFile(atPath: reqDir + "/" + UpdateInstall.requestName, contents: UpdateInstall.encode(req))
check("the request round-trips", try? UpdateInstall.takeRequest(dir: reqDir), req)
check("the request is gone once read", fm.fileExists(atPath: reqDir + "/" + UpdateInstall.requestName), false)
fm.createFile(atPath: reqDir + "/" + UpdateInstall.requestName, contents: Data("junk".utf8))
check("a junk request is rejected", throwsError { _ = try UpdateInstall.takeRequest(dir: reqDir) }, true)
check("a junk request is removed too", fm.fileExists(atPath: reqDir + "/" + UpdateInstall.requestName), false)
fm.createFile(atPath: reqDir + "/real.json", contents: UpdateInstall.encode(req))
try! fm.createSymbolicLink(atPath: reqDir + "/" + UpdateInstall.requestName, withDestinationPath: reqDir + "/real.json")
check("a symlinked request is rejected", throwsError { _ = try UpdateInstall.takeRequest(dir: reqDir) }, true)
fm.createFile(atPath: reqDir + "/" + UpdateInstall.requestName, contents: Data(count: UpdateInstall.maxRequest + 1))
check("an oversized request is rejected", throwsError { _ = try UpdateInstall.takeRequest(dir: reqDir) }, true)

// Homebrew
check("no Caskroom, not Homebrew", UpdatePolicy.isHomebrewInstall(caskrooms: [root + "/Caskroom/lynx-battery"]), false)
try! fm.createDirectory(atPath: root + "/Caskroom/lynx-battery", withIntermediateDirectories: true)
check("a Caskroom folder means Homebrew", UpdatePolicy.isHomebrewInstall(caskrooms: ["/nonexistent", root + "/Caskroom/lynx-battery"]), true)
check("both Homebrew prefixes are checked", UpdatePolicy.caskrooms.contains("/opt/homebrew/Caskroom/lynx-battery") && UpdatePolicy.caskrooms.contains("/usr/local/Caskroom/lynx-battery"), true)

// Розбір релізу з підписом і коли ставити самим
let json = """
{"tag_name":"v1.2.0","html_url":"https://github.com/Mansfera/lynx-battery/releases/tag/v1.2.0","draft":false,"prerelease":false,
 "assets":[{"name":"Lynx-Battery-1.2.0.dmg","browser_download_url":"https://github.com/Mansfera/lynx-battery/releases/download/v1.2.0/Lynx-Battery-1.2.0.dmg","digest":"sha256:\(sha)"},
           {"name":"Lynx-Battery-1.2.0.dmg.sig","browser_download_url":"https://github.com/Mansfera/lynx-battery/releases/download/v1.2.0/Lynx-Battery-1.2.0.dmg.sig"}]}
"""
let rel = UpdatePolicy.parse(Data(json.utf8))!
check("the DMG is still the .dmg asset", rel.dmgURL?.lastPathComponent, "Lynx-Battery-1.2.0.dmg")
check("finds the .sig asset", rel.sigURL?.lastPathComponent, "Lynx-Battery-1.2.0.dmg.sig")
var unsigned = rel; unsigned.sigURL = nil
var noDigest = rel; noDigest.dmgSHA256 = nil
check("installable with key, signature and digest", UpdatePolicy.canInstall(rel, keyPresent: true, homebrew: false), true)
check("not without a key", UpdatePolicy.canInstall(rel, keyPresent: false, homebrew: false), false)
check("not from Homebrew", UpdatePolicy.canInstall(rel, keyPresent: true, homebrew: true), false)
check("not without a .sig", UpdatePolicy.canInstall(unsigned, keyPresent: true, homebrew: false), false)
check("not without a digest", UpdatePolicy.canInstall(noDigest, keyPresent: true, homebrew: false), false)
func auto(_ r: ReleaseInfo = rel, current: String = "1.1.0", check c: Bool = true, on: Bool = true, homebrew: Bool = false, attempted: Set<String> = []) -> Bool {
    UpdatePolicy.shouldAutoInstall(r, current: current, checkOn: c, autoOn: on, keyPresent: true, homebrew: homebrew, attempted: attempted)
}
check("auto-installs a newer version", auto(), true)
check("not with the switch off", auto(on: false), false)
check("not with checks off", auto(check: false), false)
check("not when up to date", auto(current: "1.2.0"), false)
check("not a downgrade", auto(current: "1.3.0"), false)
check("not twice for one version", auto(attempted: ["1.2.0"]), false)
check("not from Homebrew", auto(homebrew: true), false)
check("not an unsigned release", auto(unsigned), false)

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
