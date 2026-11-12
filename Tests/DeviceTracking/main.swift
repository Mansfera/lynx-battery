import AppKit
import SwiftUI

// Перемикач «Track devices»: що зупиняється, коли вимкнено, і що вертається без перезапуску, плюс PNG. Запуск: Tests/device-tracking.sh

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func render<V: View>(_ view: V, _ name: String, width: CGFloat = 372, dark: Bool = false) {
    let host = NSHostingView(rootView: view)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
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

/// Чи прочитала модель пристрої за кілька секунд. system_profiler працює ~0,1 с, процес легко проґавити,
/// тож дивимось на список спарених, який кожне читання переписує.
func readsDevices(_ model: AppModel, within seconds: TimeInterval = 3) -> Bool {
    model.ble.paired = ["sentinel": ""]
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if model.ble.paired["sentinel"] == nil { return true }
        pump(0.05)
    }
    return false
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Brand.registerFonts(in: fonts)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// CFFIXED_USER_HOME переносить файли даних, але не налаштування: вони живуть у справжньому ~/Library/Preferences під назвою цієї програми
let testDefaults = ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: testDefaults)

check("on by default", Settings.shared.trackDevices)
Settings.shared.trackDevices = false

let model = AppModel()
// Без цього AppModel змінює шкалу ліміту під порожні налаштування тестів, і ChargeControl пише її у файл, який виконує хелпер.
model.charge.setPreview(installed: false, status: nil)

// CoreBluetooth без дозволу в Info.plist валить процес, тож сам старт уже перевіряє, що Bluetooth не чіпаємо
model.start()
check("Bluetooth stays off", model.ble.state == .unknown)
check("no Devices tab", !model.tabs.contains(.devices))
model.popoverShown = true
model.refreshDevices()
check("opening the menu reads no devices", !readsDevices(model, within: 1.5))
model.tab = .devices
check("can't land on Devices", model.tab != .devices)
check("Bluetooth still off with the menu open", model.ble.state == .unknown)
check("no devices listed", model.devices.isEmpty)
render(PopoverView(model: model), "popover-tracking-off")
render(AlertSettings(model: model), "settings-alerts-tracking-off", width: 480)
model.popoverShown = false

// Без дозволу вмикання теж не чіпає Bluetooth, поки не відкрито Devices: інакше тут процес упаде
if !model.ble.authorized {
    Settings.shared.trackDevices = true
    check("on again: devices are read without relaunch", readsDevices(model))
    check("on again: Devices tab is back", model.tabs.contains(.devices))
    check("on again: no Bluetooth prompt until the Devices tab opens", model.ble.state == .unknown)
    render(AlertSettings(model: model), "settings-alerts-tracking-on", width: 480)

    model.tab = .devices
    model.devices = [BTDevice(name: "Magic Mouse", kind: "Mouse", main: 8)]
    Settings.shared.trackDevices = false
    pump(0.2)
    check("off while on Devices: moves to another tab", model.tab != .devices)
    check("off: no devices, so the menu bar shows none", model.devices.isEmpty
          && MenuIcon.desktop(devices: model.devices, watts: nil).0.accessibilityDescription == "On power")
    model.refreshDevices()
    check("off: no more device reads", !readsDevices(model, within: 1.5))
    check("no system_profiler or ioreg left running", childCount(named: "system_profiler") == 0 && childCount(named: "ioreg") == 0)
} else {
    print("SKIP  turning back on: Bluetooth is allowed for this binary, and CoreBluetooth would crash here without Info.plist")
}

UserDefaults.standard.removePersistentDomain(forName: testDefaults)
print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
