import Foundation
import CryptoKit

// Update checks before install: signatures (throwaway keys, not the real ones), request paths, Homebrew, when to auto-install.
// No network, no root; files only in a temp folder. ssh-keygen is used only to cross-check the signature format.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}
func throwsError(_ f: () throws -> Void) -> Bool { do { try f(); return false } catch { return true } }

let fm = FileManager.default
var tmpl = Array((NSTemporaryDirectory() + "update-verify.XXXXXX").utf8CString)
let root = String(cString: realpath(mkdtemp(&tmpl)!, nil)!)
defer { try? fm.removeItem(atPath: root) }

// Signature
let key1 = SKSigner(), key2 = SKSigner(), stranger = SKSigner()
let trusted = [key1.trusted("yubikey 1"), key2.trusted("yubikey 2")]
let sha = UpdateSignature.sha256(Data("a DMG".utf8))
let sig = key1.sign(sha256: sha, version: "1.2.0")
func verifies(_ s: Data, sha256: String = sha, version: String = "1.2.0", bundleID: String = UpdateSignature.bundleID,
              trusted t: [TrustedUpdateKey] = trusted) -> Bool {
    UpdateSignature.verify(signatureFile: s, sha256: sha256, version: version, bundleID: bundleID, trusted: t) != nil
}
check("key 1 verifies", UpdateSignature.verify(signatureFile: sig, sha256: sha, version: "1.2.0", trusted: trusted)?.label, "yubikey 1")
check("key 2 verifies", UpdateSignature.verify(signatureFile: key2.sign(sha256: sha, version: "1.2.0"), sha256: sha, version: "1.2.0", trusted: trusted)?.label, "yubikey 2")
check("v prefix signs the same version", verifies(sig, version: "v1.2.0"), true)
check("uppercase sha256 is the same", verifies(sig, sha256: sha.uppercased()), true)
check("an untrusted key is rejected", verifies(stranger.sign(sha256: sha, version: "1.2.0")), false)
check("an empty trusted list verifies nothing", verifies(sig, trusted: []), false)
check("another DMG is rejected", verifies(sig, sha256: UpdateSignature.sha256(Data("a DMG!".utf8))), false)
check("another version is rejected", verifies(sig, version: "1.2.1"), false)
check("another bundle id is rejected", verifies(sig, bundleID: "com.example.app"), false)
check("a prerelease is rejected", verifies(key1.sign(Data("lynx-battery-update/1\n\(UpdateSignature.bundleID)\n1.3.0-beta\n\(sha)\n".utf8)), version: "1.3.0-beta"), false)
check("junk sha256 is rejected", verifies(sig, sha256: "abc"), false)
check("another namespace is rejected", verifies(key1.sign(UpdateSignature.message(sha256: sha, version: "1.2.0")!, namespace: "file")), false)
check("sha256 as the hash algorithm is rejected", verifies(key1.sign(UpdateSignature.message(sha256: sha, version: "1.2.0")!, hash: "sha256")), false)
check("no touch (UP flag) is rejected", verifies(key1.sign(UpdateSignature.message(sha256: sha, version: "1.2.0")!, flags: 0x04)), false)
check("no PIN (UV flag) is rejected", verifies(key1.sign(UpdateSignature.message(sha256: sha, version: "1.2.0")!, flags: 0x01)), false)
check("extra flags are fine", verifies(key1.sign(UpdateSignature.message(sha256: sha, version: "1.2.0")!, flags: 0x25)), true)
check("a plain ed25519 signature type is rejected", verifies(key1.sign(UpdateSignature.message(sha256: sha, version: "1.2.0")!, keyType: "ssh-ed25519")), false)
var otherApp = key1; otherApp.application = "ssh:"
check("the same key under another application is rejected", verifies(otherApp.sign(sha256: sha, version: "1.2.0")), false)
check("a trusted key with another application is rejected", verifies(otherApp.sign(sha256: sha, version: "1.2.0"), trusted: [otherApp.trusted("git")]), false)
check("a trusted key with another application isn't usable", UpdateSignature.hasUsableKey([otherApp.trusted("git")]), false)
check("the compiled keys are all usable", UpdateKey.trusted.allSatisfy(UpdateSignature.isUsable), true)
check("the compiled keys are distinct", Set(UpdateKey.trusted.map(\.key)).count, UpdateKey.trusted.count)

let blob = UpdateSignature.dearmor(sig)!
func rearmor(_ b: Data) -> Data { Data(UpdateSignature.armor(b).utf8) }
check("re-armoring keeps it valid", verifies(rearmor(blob)), true)
var flipped = blob; flipped[flipped.count - 10] ^= 1
check("a flipped signature byte is rejected", verifies(rearmor(flipped)), false)
var flippedCounter = blob; flippedCounter[flippedCounter.count - 1] ^= 1
check("a changed counter is rejected", verifies(rearmor(flippedCounter)), false)
var flippedFlags = blob; flippedFlags[flippedFlags.count - 5] ^= 0x20
check("a changed flags byte is rejected", verifies(rearmor(flippedFlags)), false)
check("trailing bytes are rejected", verifies(rearmor(blob + Data([0]))), false)
check("a truncated blob is rejected", verifies(rearmor(blob.prefix(blob.count - 1))), false)
var v2 = blob; v2[9] = 2
check("SSHSIG version 2 is rejected", verifies(rearmor(v2)), false)
check("no armor is rejected", verifies(Data(blob.base64EncodedString().utf8)), false)
check("garbage is rejected", verifies(Data("hello".utf8)), false)
check("empty is rejected", verifies(Data()), false)
let text = String(data: sig, encoding: .utf8)!
check("a truncated armor is rejected", verifies(Data(text.prefix(text.count - 30).utf8)), false)
check("a missing END line is rejected", verifies(Data(text.replacingOccurrences(of: UpdateSignature.armorEnd, with: "").utf8)), false)
check("CRLF line ends are fine", verifies(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)), true)
check("an oversized file is rejected", verifies(sig + Data(repeating: 0x20, count: UpdateSignature.maxSignatureFile)), false)

// A real `ssh-keygen -Y sign` signature (plain ed25519 key): the SSHSIG framing and signed data match OpenSSH's
let fixtures = "Tests/UpdateVerify/fixtures/"
let fxMessage = fm.contents(atPath: fixtures + "message")!
let fxSig = fm.contents(atPath: fixtures + "message.sig")!
let fxPub = String(data: fm.contents(atPath: fixtures + "ed25519.pub")!, encoding: .utf8)!
let fxBlob = Data(base64Encoded: String(fxPub.split(separator: " ")[1]))!
check("the fixture message is ours", fxMessage, UpdateSignature.message(sha256: sha, version: "1.2.0"))
let fx = UpdateSignature.parse(fxSig)
check("ssh-keygen's SSHSIG parses", fx != nil, true)
check("  namespace", fx?.namespace, UpdateSignature.namespace)
check("  hash algorithm", fx?.hashAlgorithm, "sha512")
check("  reserved is empty", fx?.reserved, Data())
check("  public key", fx?.publicKey, fxBlob)
check("  re-encodes byte for byte", fx.map { rearmor(UpdateSignature.encode($0)) }, fxSig)
var fr = UpdateSignature.Reader(fx?.signature ?? Data())
let fxType = fr.text(), fxRaw = fr.string()
check("  signature is ssh-ed25519", fxType, "ssh-ed25519")
let fxKey = try! Curve25519.Signing.PublicKey(rawRepresentation: fxBlob.suffix(32))
check("  verifies over our signed data", fxKey.isValidSignature(fxRaw ?? Data(), for: UpdateSignature.signedData(fxMessage)), true)
check("  not over another namespace", fxKey.isValidSignature(fxRaw ?? Data(), for: UpdateSignature.signedData(fxMessage, namespace: "file")), false)
check("a plain ed25519 key is rejected even if listed", verifies(fxSig, trusted: [TrustedUpdateKey(label: "plain", key: fxPub)]), false)

// The sk encoder against real OpenSSH: ssh-keygen -Y verify must accept what SKSigner makes, and refuse it once the flags
// or counter are changed, so both sit in the signed data where OpenSSH puts them. ssh-keygen doesn't require the flags
// themselves (allowed_signers has no option for it), so that's checked only by our verifier above.
func sshVerify(_ keygen: String, _ sigData: Data, allowed: String, message: Data) -> Bool {
    let dir = root + "/ssh-\(UUID().uuidString)"
    try! fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    fm.createFile(atPath: dir + "/msg", contents: message)
    fm.createFile(atPath: dir + "/msg.sig", contents: sigData)
    fm.createFile(atPath: dir + "/allowed", contents: Data(allowed.utf8))
    let p = Process()
    p.executableURL = URL(fileURLWithPath: keygen)
    p.arguments = ["-Y", "verify", "-f", dir + "/allowed", "-I", "release", "-n", UpdateSignature.namespace, "-s", dir + "/msg.sig"]
    p.standardInput = FileHandle(forReadingAtPath: dir + "/msg")
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    return p.terminationStatus == 0
}
let keygens = ["/opt/homebrew/bin/ssh-keygen", "/usr/bin/ssh-keygen"].filter { fm.isExecutableFile(atPath: $0) }
check("ssh-keygen is available", keygens.isEmpty, false)
let msg = UpdateSignature.message(sha256: sha, version: "1.2.0")!
for kg in keygens {
    let allowed = "release namespaces=\"\(UpdateSignature.namespace)\" \(key1.line)\n"
    check("\(kg) accepts the plain fixture", sshVerify(kg, fxSig, allowed: "release namespaces=\"\(UpdateSignature.namespace)\" \(fxPub)", message: fxMessage), true)
    check("\(kg) accepts our sk signature", sshVerify(kg, sig, allowed: allowed, message: msg), true)
    check("\(kg) refuses it for another message", sshVerify(kg, sig, allowed: allowed, message: msg + Data("x".utf8)), false)
    check("\(kg) accepts other flags and counter when signed", sshVerify(kg, key1.sign(msg, flags: 0x01, counter: 7), allowed: allowed, message: msg), true)
    var f = blob; f[f.count - 5] ^= 0x04
    check("\(kg) refuses a changed flags byte", sshVerify(kg, rearmor(f), allowed: allowed, message: msg), false)
    check("\(kg) refuses a changed counter", sshVerify(kg, rearmor(flippedCounter), allowed: allowed, message: msg), false)
    check("\(kg) refuses another application", sshVerify(kg, otherApp.sign(msg), allowed: allowed, message: msg), false)
}

// Names and folders
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

// Links inside the bundle
check("link down inside", UpdateInstall.symlinkStaysInside(rel: "Contents/Frameworks/A.framework/A", dest: "Versions/Current/A"), true)
check("link up within the bundle", UpdateInstall.symlinkStaysInside(rel: "Contents/Resources/x", dest: "../Info.plist"), true)
check("link out of the bundle", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "../../etc"), false)
check("absolute link", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "/etc/passwd"), false)
check("up after down", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "MacOS/.."), false)
check("dot link", UpdateInstall.symlinkStaysInside(rel: "Contents/x", dest: "."), false)

// Files
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

// Request
let reqDir = root + "/req"
try! fm.createDirectory(atPath: reqDir, withIntermediateDirectories: true)
let req = UpdateRequest(id: "abc", version: "1.2.0", dmg: "Lynx-Battery-1.2.0.dmg", sha256: sha, signature: String(data: sig, encoding: .utf8)!,
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

// Parsing a signed release, and when to install on our own
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
