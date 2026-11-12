import AppKit
import SwiftUI

// "Minimal energy use" mode: what stops at startup and on toggling, plus a PNG of the Power tab. Run: Tests/minimal-energy.sh

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func render(_ model: AppModel, _ name: String, dark: Bool = false) {
    let host = NSHostingView(rootView: PopoverView(model: model))
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentView = host
    pump(0.4)
    win.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    pump(0.2)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
    win.contentView = nil
}

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
Brand.registerFonts(in: fonts)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// CFFIXED_USER_HOME relocates data files but not preferences: they live in the real ~/Library/Preferences under this program's name
let testDefaults = ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: testDefaults)

check("off by default", !Settings.shared.minimalEnergy)
Settings.shared.minimalEnergy = true

let model = AppModel()
// Without this, AppModel changes the limit scale to match the tests' empty settings, and ChargeControl writes it to the file the helper enforces.
model.charge.setPreview(installed: false, status: nil)

// CoreBluetooth without permission in Info.plist kills the process, so the startup itself already checks that Bluetooth isn't touched
model.start()
check("Bluetooth stays off", model.ble.state == .unknown)
model.popoverShown = true
model.tab = .devices
check("the Devices tab leaves Bluetooth off too", model.ble.state == .unknown)
model.tab = .overview
model.popoverShown = false
pump(0.2)
check("no top at launch", childCount(named: "top") == 0)
check("no system_profiler at launch", childCount(named: "system_profiler") == 0)
check("energy by app on the Eco schedule", model.energyInterval == AppTracking.eco.interval)
Settings.shared.appTracking = .frequent
pump(0.1)
check("the chosen frequency waits until Minimal energy use is off", model.energyInterval == AppTracking.eco.interval)
Settings.shared.appTracking = .normal

check("the helper is told to slow down", model.charge.config.minimalEnergy == true)
model.charge.minimalEnergy = false
check("off leaves the helper's config as it was", model.charge.config.minimalEnergy == nil)
model.charge.minimalEnergy = true

check("closed menu: battery every 5 minutes", model.refreshInterval == 300)
check("closed menu: wattage every minute", model.powerInterval == 60)
model.popoverShown = true
check("open menu: battery every 5 seconds", model.refreshInterval == 5)
check("open menu: wattage back to live", model.powerInterval == AppModel.wattInterval)
model.tab = .power
check("no faster Power tab in Minimal energy use", model.refreshInterval == 5 && !model.powerTabLive)
model.tab = .overview
model.popoverShown = false
check("closed again: rare again", model.refreshInterval == 300)

model.battery = BatterySnapshot(percent: 62, isCharging: false, onAC: false, fullyCharged: false, minutes: 240, watts: -9.5,
                                adapterWatts: nil, cycles: 120, designCycles: 1000, designCapacity: 6000, fullCapacity: 5400,
                                temperature: 31, systemWatts: 9.5, inputWatts: 0, lowPower: false)
model.tab = .power
render(model, "power-minimal-light")
render(model, "power-minimal-dark", dark: true)
model.battery = nil
render(model, "power-minimal-desktop")

// Without permission, leaving the mode doesn't touch Bluetooth either until Devices is opened: otherwise the process would crash here
if !model.ble.authorized {
    Settings.shared.minimalEnergy = false
    pump(0.5)
    check("no Bluetooth prompt until the Devices tab opens", model.ble.state == .unknown)
}

UserDefaults.standard.removePersistentDomain(forName: testDefaults)
print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
