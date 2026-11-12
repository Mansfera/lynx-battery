import Foundation
import CryptoKit

// Установка оновлення від початку до кінця, як її робить хелпер: справжні DMG (hdiutil), підпис тестовим ключем,
// заміна апки в тимчасовій «Applications». Без root, без хелпера, справжньої /Applications не чіпає.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}

let fm = FileManager.default
var tmpl = Array((NSTemporaryDirectory() + "update-install.XXXXXX").utf8CString)
let root = String(cString: realpath(mkdtemp(&tmpl)!, nil)!)
defer { try? fm.removeItem(atPath: root) }
let apps = root + "/Applications", reqDir = root + "/req", work = root + "/work", build = root + "/build"
for d in [apps, reqDir, work, build] { try! fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
let app = apps + "/Lynx Battery.app"

let key = Curve25519.Signing.PrivateKey()
let pub = key.publicKey.rawRepresentation.base64EncodedString()
let wrongKey = Curve25519.Signing.PrivateKey()

func sh(_ exe: String, _ args: String...) { _ = try! UpdateInstall.run(exe, args) }

func makeApp(_ path: String, id: String = UpdateSignature.bundleID, version: String, tweak: (String) -> Void = { _ in }) {
    try? fm.removeItem(atPath: path)
    try! fm.createDirectory(atPath: path + "/Contents/MacOS", withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "LynxBattery",
                                "CFBundlePackageType": "APPL", "CFBundleName": "Lynx Battery"]
    fm.createFile(atPath: path + "/Contents/Info.plist", contents: try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
    try! fm.copyItem(atPath: "/usr/bin/true", toPath: path + "/Contents/MacOS/LynxBattery")
    tweak(path)
    sh("/usr/bin/codesign", "--force", "--deep", "--sign", "-", path)
}

/// DMG як у release.sh: апка й посилання на /Applications.
func makeDMG(_ name: String, appName: String = UpdateInstall.appName, id: String = UpdateSignature.bundleID, version: String,
             tweak: (String) -> Void = { _ in }) -> String {
    let stage = build + "/stage-\(name)"
    try? fm.removeItem(atPath: stage)
    try! fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
    makeApp(stage + "/" + appName, id: id, version: version, tweak: tweak)
    try! fm.createSymbolicLink(atPath: stage + "/Applications", withDestinationPath: "/Applications")
    let out = build + "/\(name).dmg"
    sh("/usr/bin/hdiutil", "create", "-volname", "Lynx Battery", "-srcfolder", stage, "-ov", "-format", "UDZO", out)
    return out
}

func installedVersion() -> String? { try? UpdateInstall.bundleInfo(app).version }

var logLines: [String] = []
/// Кладе DMG у теку запиту й запускає те, що запускає хелпер.
func attempt(dmg: String, version: String, signVersion: String? = nil, signer: Curve25519.Signing.PrivateKey = key,
             dmgName: String? = nil, target: String = app, publicKey: String? = nil, age: TimeInterval = 0,
             claimSHA: String? = nil, placeDMG: ((String, String) -> Void)? = nil) -> UpdateResult? {
    let name = dmgName ?? "Lynx-Battery-\(version).dmg"
    let data = fm.contents(atPath: dmg)!
    let sha = UpdateSignature.sha256(data)
    let sig = UpdateSignature.sign(sha256: sha, version: signVersion ?? version, with: signer) ?? Data(count: 64)
    if let placeDMG { placeDMG(dmg, reqDir + "/" + name) }
    else if UpdateInstall.isValidDMGName(name) { fm.createFile(atPath: reqDir + "/" + name, contents: data) }
    let req = UpdateRequest(id: UUID().uuidString, version: version, dmg: name, sha256: claimSHA ?? sha,
                            signature: sig.base64EncodedString(), app: target, requestedAt: Date().addingTimeInterval(-age))
    fm.createFile(atPath: reqDir + "/" + UpdateInstall.requestName, contents: UpdateInstall.encode(req))
    logLines = []
    let r = UpdateInstall.handleRequest(dir: reqDir, workRoot: work, publicKey: publicKey ?? pub,
                                        allowedParent: { $0 == apps }, log: { logLines.append($0) })
    check("  request answered with its id", r?.id, req.id)
    check("  request file consumed", fm.fileExists(atPath: reqDir + "/" + UpdateInstall.requestName), false)
    check("  result written for the app", fm.contents(atPath: reqDir + "/" + UpdateInstall.resultName).flatMap { UpdateInstall.decode(UpdateResult.self, $0) }?.id, req.id)
    check("  work folder cleaned (DMG detached)", (try? fm.contentsOfDirectory(atPath: work)) ?? ["?"], [])
    check("  nothing left next to the app", (try? fm.contentsOfDirectory(atPath: apps))?.filter { $0 != "Lynx Battery.app" && $0 != "Other" } ?? ["?"], [])
    return r
}

func refused(_ name: String, _ r: UpdateResult?, _ reason: String) {
    print(name)
    check("  refused", r?.ok, false)
    check("  says why (\(reason))", r?.message.contains(reason) ?? false, true)
    if r?.message.contains(reason) != true { print("    message: \(r?.message ?? "nil")") }
    check("  installed app untouched", installedVersion(), "1.0.0")
    check("  installed app still has its executable", fm.isExecutableFile(atPath: app + "/Contents/MacOS/LynxBattery"), true)
}

makeApp(app, version: "1.0.0")
let good = makeDMG("good", version: "1.2.0")

// Відмови — до успішної установки, поки стоїть 1.0.0
refused("tampered DMG (checksum from before)", attempt(dmg: good, version: "1.2.0", placeDMG: { src, dst in
    var d = fm.contents(atPath: src)!; d[d.count / 2] ^= 0xFF; fm.createFile(atPath: dst, contents: d)
}), "checksum doesn't match")
refused("tampered DMG (checksum updated, signature not)", attempt(dmg: good, version: "1.2.0", claimSHA: String(repeating: "a", count: 64), placeDMG: { src, dst in
    var d = fm.contents(atPath: src)!; d.append(0); fm.createFile(atPath: dst, contents: d)
}), "checksum doesn't match")
var td = fm.contents(atPath: good)!; td.append(0)
refused("tampered DMG with a matching checksum but the old signature", attempt(dmg: good, version: "1.2.0", claimSHA: UpdateSignature.sha256(td), placeDMG: { _, dst in
    fm.createFile(atPath: dst, contents: td)
}), "signature isn't valid")
refused("signed by another key", attempt(dmg: good, version: "1.2.0", signer: wrongKey), "signature isn't valid")
refused("signature for another version", attempt(dmg: good, version: "1.2.0", signVersion: "1.2.1"), "signature isn't valid")
refused("no compiled-in key", attempt(dmg: good, version: "1.2.0", publicKey: ""), "no update key")
refused("stale request", attempt(dmg: good, version: "1.2.0", age: 3600), "stale")
refused("DMG name with ..", attempt(dmg: good, version: "1.2.0", dmgName: "../Lynx-Battery-1.2.0.dmg"), "DMG name")
refused("DMG is a symlink", attempt(dmg: good, version: "1.2.0", placeDMG: { src, dst in
    try! fm.createSymbolicLink(atPath: dst, withDestinationPath: src)
}), "symlink")
let older = makeDMG("older", version: "0.9.0")
refused("downgrade", attempt(dmg: older, version: "0.9.0"), "isn't newer")
let same = makeDMG("same", version: "1.0.0")
refused("same version", attempt(dmg: same, version: "1.0.0"), "isn't newer")
refused("bundle older than the signed version", attempt(dmg: good, version: "1.3.0"), "the release says 1.3.0")
let wrongID = makeDMG("wrong-id", id: "com.example.evil", version: "1.2.0")
refused("wrong bundle id", attempt(dmg: wrongID, version: "1.2.0"), "not Lynx Battery")
let escaping = makeDMG("escaping", version: "1.2.0") { p in
    try! fm.createSymbolicLink(atPath: p + "/Contents/Resources", withDestinationPath: "../../../../../../etc")
}
refused("symlink out of the bundle", attempt(dmg: escaping, version: "1.2.0"), "links outside")
let noApp = makeDMG("no-app", appName: "Something Else.app", version: "1.2.0")
refused("no Lynx Battery.app in the DMG", attempt(dmg: noApp, version: "1.2.0"), "has no Lynx Battery.app")
try! fm.createDirectory(atPath: apps + "/Other", withIntermediateDirectories: true)
makeApp(apps + "/Other/Lynx Battery.app", version: "1.0.0")
refused("target outside the allowed folder", attempt(dmg: good, version: "1.2.0", target: apps + "/Other/Lynx Battery.app"), "Applications folder")
try! fm.createSymbolicLink(atPath: root + "/AppsLink", withDestinationPath: apps)
refused("target through a symlink", attempt(dmg: good, version: "1.2.0", target: root + "/AppsLink/Lynx Battery.app"), "symlink")
try! fm.removeItem(atPath: apps + "/Other")

// Справжня установка
print("good update 1.0.0 → 1.2.0")
let oldInode = (try? fm.attributesOfItem(atPath: app))?[.systemFileNumber] as? Int
let r = attempt(dmg: good, version: "1.2.0")
check("  installed", r?.ok, true)
check("  message", r?.message, "Updated to 1.2.0")
check("  new version in place", installedVersion(), "1.2.0")
check("  it's a new folder, not edited in place", ((try? fm.attributesOfItem(atPath: app))?[.systemFileNumber] as? Int) != oldInode, true)
check("  code signature intact", (try? UpdateInstall.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app])) != nil, true)
check("  DMG removed from the request folder", (try? fm.contentsOfDirectory(atPath: reqDir))?.filter { $0.hasSuffix(".dmg") } ?? ["?"], [])
check("  every step logged", ["target ok", "checksum and signature ok", "mounted read-only", "bundle ok", "copied", "installed at"]
    .allSatisfy { step in logLines.contains { $0.contains(step) } }, true)
check("  no Lynx DMG left attached", (String(data: (try? UpdateInstall.run("/usr/bin/hdiutil", ["info"])) ?? Data(), encoding: .utf8) ?? "").contains(work), false)

print("the same update again")
let again = attempt(dmg: good, version: "1.2.0")
check("  refused once installed", again?.ok, false)
check("  stays on 1.2.0", installedVersion(), "1.2.0")

print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
