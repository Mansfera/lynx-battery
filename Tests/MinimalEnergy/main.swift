import AppKit
import SwiftUI

// Режим «Minimal energy use»: що зупиняється на старті й при перемиканні, плюс PNG вкладки Power. Запуск: Tests/minimal-energy.sh

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

check("off by default", !Settings.shared.minimalEnergy)
Settings.shared.minimalEnergy = true

let model = AppModel()
// Без цього AppModel змінює шкалу ліміту під порожні налаштування тестів, і ChargeControl пише її у файл, який виконує хелпер.
model.charge.setPreview(installed: false, status: nil)

// CoreBluetooth без дозволу в Info.plist валить процес, тож сам старт уже перевіряє, що Bluetooth не чіпаємо
model.start()
check("Bluetooth stays off", model.ble.state == .unknown)
pump(0.2)
check("no top at launch", childCount(named: "top") == 0)
check("no system_profiler at launch", childCount(named: "system_profiler") == 0)
model.sampleEnergy()
pump(0.2)
check("asking for an energy sample starts nothing", childCount(named: "top") == 0)
pump(2.5)
check("no live app list", model.apps.isEmpty)

check("closed menu: battery every 5 minutes", model.refreshInterval == 300)
check("closed menu: wattage every minute", model.powerInterval == 60)
model.popoverShown = true
check("open menu: battery back to 20 seconds", model.refreshInterval == 20)
check("open menu: wattage back to live", model.powerInterval == AppModel.wattInterval)
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

print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
