import AppKit

// Як часто міряємо енергію по апках (Frequent / Normal / Eco) і живі заміри на вкладці Power. Запуск: Tests/tracking-cadence.sh

var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func childCount(named name: String) -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-P", "\(getpid())", name]
    let pipe = Pipe()
    p.standardOutput = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").count
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

// CFFIXED_USER_HOME переносить файли даних, але не налаштування: вони живуть у справжньому ~/Library/Preferences під назвою цієї програми
let testDefaults = ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: testDefaults)

let s = Settings.shared
check("Normal by default, so existing users move to it too", s.appTracking == .normal)
check("live Power tab on by default", s.livePowerTab)
check("Frequent is today's 2 minutes", AppTracking.frequent.interval == 120)
check("Normal is less often than Frequent", AppTracking.normal.interval > AppTracking.frequent.interval)
check("Eco is less often than Normal", AppTracking.eco.interval > AppTracking.normal.interval)
check("Eco still gives the hourly history a few samples", AppTracking.eco.interval <= 3600 / 4)

let model = AppModel()
// Без цього AppModel змінює шкалу ліміту під порожні налаштування тестів, і ChargeControl пише її у файл, який виконує хелпер.
model.charge.setPreview(installed: false, status: nil)

check("the schedule follows the setting", model.energyInterval == AppTracking.normal.interval)
s.appTracking = .eco
check("Eco schedule", model.energyInterval == AppTracking.eco.interval)
s.appTracking = .frequent
s.minimalEnergy = true
check("Minimal energy use samples on the Eco schedule", model.energyInterval == AppTracking.eco.interval)
s.minimalEnergy = false
check("and gives the choice back when it's off", model.energyInterval == AppTracking.frequent.interval)
s.appTracking = .normal

check("closed menu: battery every 20 seconds", model.refreshInterval == 20)
model.popoverShown = true
check("Overview: battery every 5 seconds", model.refreshInterval == 5 && !model.powerTabLive)
model.tab = .power
check("Power tab: battery every 2 seconds", model.refreshInterval == AppModel.liveRefreshInterval && model.powerTabLive)

pump(0.5)
check("no top while the popover is still drawing", childCount(named: "top") == 0)
pump(AppModel.liveEnergyDelay)
check("a live sample starts once it has drawn", childCount(named: "top") == 1)
pump(2)
check("the live sample fills the list", !model.apps.isEmpty)
check("a live sample stays out of the history", model.energy.averages(.day).isEmpty)
let first = model.energy.lastSample
pump(AppModel.liveEnergyInterval)
check("the Power tab keeps sampling", model.energy.lastSample.map { $0 > first! } == true)

model.tab = .overview
pump(0.1)
check("another tab: back to 5 seconds", model.refreshInterval == 5)
let last = model.energy.lastSample
pump(AppModel.liveEnergyInterval + 1.5)
check("another tab: no more live samples", model.energy.lastSample == last)

s.livePowerTab = false
model.tab = .power
check("toggle off: Power tab like any other", model.refreshInterval == 5 && !model.powerTabLive)
pump(AppModel.liveEnergyDelay + 2)
let opened = model.energy.lastSample
check("toggle off: still one sample on opening", opened != last)
model.tab = .overview
model.tab = .power
pump(AppModel.liveEnergyDelay + 2)
check("toggle off: back to Power right away takes no new sample", model.energy.lastSample == opened)
pump(AppModel.liveEnergyInterval)
check("toggle off: and no more after it", model.energy.lastSample == opened)
model.tab = .overview
s.livePowerTab = true

model.popoverShown = false
pump(0.1)
check("closed: back to 20 seconds", model.refreshInterval == 20)

model.sampleEnergy()
pump(2)
check("a scheduled sample goes into the history", !model.energy.averages(.day).isEmpty)

UserDefaults.standard.removePersistentDomain(forName: testDefaults)
print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
