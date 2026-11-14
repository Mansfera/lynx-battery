import AppKit
import SwiftUI

// The "Track devices" toggle: what stops when it's off and what comes back without a restart, plus PNGs. Run: Tests/device-tracking.sh

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

/// Whether the model read the devices within a few seconds. system_profiler runs ~0.1 s, the process is easy to miss,
/// so we look at the paired list, which every read rewrites.
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

// CFFIXED_USER_HOME relocates data files but not preferences: they live in the real ~/Library/Preferences under this program's name
let testDefaults = ProcessInfo.processInfo.processName
UserDefaults.standard.removePersistentDomain(forName: testDefaults)

check("on by default", Settings.shared.trackDevices)
Settings.shared.trackDevices = false

let model = AppModel()
// Without this, AppModel changes the limit scale to match the tests' empty settings, and ChargeControl writes it to the file the helper enforces.
model.charge.setPreview(installed: false, status: nil)

// CoreBluetooth without permission in Info.plist kills the process, so the startup itself already checks that Bluetooth isn't touched
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
render(SoundSettings(model: model), "settings-sounds-tracking-off", width: 480)
model.popoverShown = false

// Without permission, turning it on doesn't touch Bluetooth either until Devices is opened: otherwise the process would crash here
if !model.ble.authorized {
    Settings.shared.trackDevices = true
    check("on again: devices are read without relaunch", readsDevices(model))
    check("on again: Devices tab is back", model.tabs.contains(.devices))
    check("on again: no Bluetooth prompt until the Devices tab opens", model.ble.state == .unknown)
    render(AlertSettings(model: model), "settings-alerts-tracking-on", width: 480)
    render(SoundSettings(model: model), "settings-sounds-tracking-on", width: 480)
    render(UpdateSettings(model: model), "settings-updates", width: 480)

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
