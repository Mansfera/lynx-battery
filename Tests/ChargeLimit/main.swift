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

check("helper pace: normal tick", ChargeConfig().tickInterval, 15)
check("helper pace: normal key check", ChargeConfig().enforceInterval, 3)
var minimalConfig = ChargeConfig(); minimalConfig.minimalEnergy = true
check("helper pace: minimal tick", minimalConfig.tickInterval, 40)
check("helper pace: minimal key check", minimalConfig.enforceInterval, 15)
// Допуск таймера плюс читання раз на 5 с у відкритому поповері: інакше апка вважала б живий хелпер мертвим
check("helper pace: a slow helper still counts as alive", minimalConfig.tickInterval * 9 / 8 + 5 < ChargeStatus.aliveWindow, true)
let oldConfigFile = #"{"enabled":true,"limit":80,"sailing":true,"sailRange":5,"heatProtection":true,"heatMax":35,"sleepUntilLimit":false,"magsafeLED":false,"discharge":true,"topUp":false,"lowPower":false}"#
check("config: an older file still loads", (try? JSONDecoder().decode(ChargeConfig.self, from: Data(oldConfigFile.utf8)))?.minimalEnergy == nil, true)
check("config: an older file means normal pace", (try? JSONDecoder().decode(ChargeConfig.self, from: Data(oldConfigFile.utf8)))?.tickInterval, 15)

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
c.enabled = true; c.limit = 80; c.topUp = false; c.scale = .trueCharge
check("target: enabled limit", c.chargingTarget(display: .trueCharge, b), 80)
c.topUp = true
check("target: top up goes to full", c.chargingTarget(display: .trueCharge, b), 100)
c.topUp = false; c.enabled = false
check("target: limit off goes to full", c.chargingTarget(display: .trueCharge, b), 100)
c.enabled = true; c.limit = 80; c.scale = .trueCharge
check("target: true limit in original capacity", c.chargingTarget(display: .ofDesign, b), 71)

// Перехід зі старої назви
let script = ChargeInstall.script(helperPath: "/tmp/helper", uid: 501)
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
// Порожній файл домену лишається і після removePersistentDomain, тож прибираємо й його
for domain in [fromDomain, toDomain] {
    UserDefaults.standard.removePersistentDomain(forName: domain)
    CFPreferencesAppSynchronize(domain as CFString)
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(domain).plist")
    try? FileManager.default.removeItem(at: file)
}

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
