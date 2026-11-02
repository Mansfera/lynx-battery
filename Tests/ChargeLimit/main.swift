import Foundation

// Межі ліміту заряду й переведення між шкалами. Лише чиста логіка: файл налаштувань і хелпер не чіпає.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}

func snap(_ percent: Int, health: Int) -> BatterySnapshot {
    BatterySnapshot(percent: percent, isCharging: false, onAC: true, fullyCharged: false, minutes: nil, watts: 0,
                    adapterWatts: nil, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: health * 10,
                    temperature: nil, systemWatts: 0, inputWatts: 0, lowPower: false,
                    designTop: health, percentTop: 100)
}

let b = snap(80, health: 89)

check("top: true charge", ChargeScale.trueCharge.top(b), 100)
check("top: original capacity is the health", ChargeScale.ofDesign.top(b), 89)
check("lowest: true charge", ChargeScale.trueCharge.lowest(b), 15)
check("lowest: original capacity", ChargeScale.ofDesign.lowest(b), 13)
check("lowest on a very worn battery", ChargeScale.ofDesign.lowest(snap(5, health: 10)), 2)

check("original 72 is true 81", ChargeScale.ofDesign.convert(72, to: .trueCharge, b), 81)
check("true 81 is original 72", ChargeScale.trueCharge.convert(81, to: .ofDesign, b), 72)

var c = ChargeConfig()
c.limit = 15; c.sailRange = 20
check("sail floor never drops below the safety level", c.sailFloor, 10)
c.limit = 80; c.sailRange = 5
check("sail floor is limit minus range", c.sailFloor, 75)
c.limit = 3
check("sanitized raises a limit under 10", c.sanitized().limit, 10)
c.limit = 15
check("sanitized keeps 15", c.sanitized().limit, 15)
c.limit = 140
check("sanitized caps at 100", c.sanitized().limit, 100)

// Перехід зі старої назви
let script = ChargeControl.installScript(helperPath: "/tmp/helper", uid: 501)
func position(_ text: String) -> Int { script.range(of: text).map { script.distance(from: script.startIndex, to: $0.lowerBound) } ?? -1 }
check("install stops the old helper", script.contains("launchctl bootout system/\(ChargePaths.legacyLabel)"), true)
check("install removes the old helper", script.contains("rm -f '\(ChargePaths.legacyDaemonPlist)' '\(ChargePaths.legacyHelperBinary)'"), true)
check("old helper stops before the new one starts", position("system/\(ChargePaths.legacyLabel)") < position("launchctl bootstrap"), true)
check("limit settings copied before the old folder goes", position("cp '\(ChargePaths.legacyDir)/charge-config.json'") < position("rm -rf '\(ChargePaths.legacyDir)'"), true)
check("the new folder is the app's to write", script.contains("chown -R 501 '\(ChargePaths.dir)'"), true)
check("daemon logs to the new path", script.contains(ChargePaths.log), true)

let syntax = Process()
let scriptInput = Pipe()
syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
syntax.arguments = ["-n"]
syntax.standardInput = scriptInput
try! syntax.run()
scriptInput.fileHandleForWriting.write(Data(script.utf8))
try! scriptInput.fileHandleForWriting.close()
syntax.waitUntilExit()
check("install script parses", syntax.terminationStatus, 0)

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lynx-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
let oldDir = tmp.appendingPathComponent("old"), newDir = tmp.appendingPathComponent("new")
try! FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
try! Data("h".utf8).write(to: oldDir.appendingPathComponent("history.json"))
AppData.migrateFolder(from: oldDir, to: newDir)
check("folder: data moved", FileManager.default.fileExists(atPath: newDir.appendingPathComponent("history.json").path), true)
check("folder: old one gone", FileManager.default.fileExists(atPath: oldDir.path), false)
try! FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
try! Data("stale".utf8).write(to: oldDir.appendingPathComponent("history.json"))
AppData.migrateFolder(from: oldDir, to: newDir)
check("folder: never overwrites newer data", try! String(contentsOf: newDir.appendingPathComponent("history.json"), encoding: .utf8), "h")

let suffix = UUID().uuidString
let fromDomain = "com.mansfera.lynxbattery.test-old-\(suffix)", toDomain = "com.mansfera.lynxbattery.test-new-\(suffix)"
UserDefaults.standard.setPersistentDomain(["percentMode": "Of original capacity"], forName: fromDomain)
AppData.migratePreferences(from: fromDomain, to: toDomain)
check("prefs: copied", UserDefaults.standard.persistentDomain(forName: toDomain)?["percentMode"] as? String, "Of original capacity")
UserDefaults.standard.setPersistentDomain(["percentMode": "stale"], forName: fromDomain)
AppData.migratePreferences(from: fromDomain, to: toDomain)
check("prefs: never overwrites newer settings", UserDefaults.standard.persistentDomain(forName: toDomain)?["percentMode"] as? String, "Of original capacity")
UserDefaults.standard.removePersistentDomain(forName: fromDomain)
UserDefaults.standard.removePersistentDomain(forName: toDomain)

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
