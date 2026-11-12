import AppKit
import SwiftUI

// Right-click on the icon must not ask for a password: it toggles Low Power only with the setting on and a live helper.

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func render<V: View>(_ view: V, _ name: String, width: CGFloat) {
    let host = NSHostingView(rootView: view)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: .aqua)
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

Brand.registerFonts(in: fonts)

// cfprefsd remembers the test domain between runs, even when the plist is already deleted
UserDefaults.standard.removeObject(forKey: "rightClickLowPower")
let s = Settings.shared
let model = AppModel()
let battery = BatterySnapshot(percent: 62, isCharging: false, onAC: false, fullyCharged: false, minutes: 240, watts: -9.5,
                              adapterWatts: nil, cycles: 120, designCycles: 1000, designCapacity: 6000, fullCapacity: 5400,
                              temperature: 31, systemWatts: 9.5, inputWatts: 0, lowPower: false)
let alive = ChargeStatus(updated: Date(), mode: .holding, percent: 62)
let dead = ChargeStatus(updated: Date().addingTimeInterval(-ChargeStatus.aliveWindow - 1), mode: .holding, percent: 62)

model.charge.setPreview(installed: false, status: nil)
model.battery = battery

check("off by default", !s.rightClickLowPower)
model.charge.setPreview(installed: true, status: alive)
check("the helper alone doesn't turn it on", !model.rightClickTogglesLowPower())

s.rightClickLowPower = true
check("on with a live helper", model.rightClickTogglesLowPower())
model.charge.setPreview(installed: false, status: nil)
check("the setting without a helper opens the popover", !model.rightClickTogglesLowPower())
model.charge.setPreview(installed: true, status: dead)
check("a helper that stopped reporting opens the popover", !model.rightClickTogglesLowPower())
model.charge.setPreview(installed: true, status: alive)
model.battery = nil
check("a Mac without a battery opens the popover", !model.rightClickTogglesLowPower())
model.battery = battery

model.charge.setPreview(installed: false, status: nil)
render(GeneralSettings(model: model), "settings-no-helper", width: 480)
render(LowPowerRow(model: model, b: battery).frame(width: 340), "low-power-no-helper", width: 340)
model.charge.setPreview(installed: true, status: alive)
render(GeneralSettings(model: model), "settings-with-helper", width: 480)
render(LowPowerRow(model: model, b: battery).frame(width: 340), "low-power-with-helper", width: 340)

UserDefaults.standard.removeObject(forKey: "rightClickLowPower")
print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
