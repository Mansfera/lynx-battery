import AppKit
import SwiftUI

// Power breakdown in the macOS row: channel grouping, "everything else", live reading and PNG. Run: Tests/power-breakdown.sh

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }
func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// Channel set from a real M3
let m3 = ["CPU Energy": 1.4, "ECPU": 0.2, "PCPU": 1.2, "GPU Energy": 0.4, "GPU": 0.38, "GPU SRAM": 0.02,
          "DRAM": 1.1, "AMCC": 0.3, "DCS": 0.5, "VDEC": 0.04, "ISP": 0.01, "AVE": 0.01,
          "DISP": 0.02, "DISPEXT": 0.08, "SOC_AON": 0.01, "SOC_REST": 0.3]
let lidOpen = DisplayState(builtInOn: true, externalOn: false, brightness: 0.62)
let curve = DisplayState(builtInOn: true, externalOn: false, brightness: 0.62, backlightEstimate: 2.5)
let lidShut = DisplayState(builtInOn: false, externalOn: true, brightness: nil)

func part(_ b: PowerBreakdown, _ name: String) -> PowerPart? { b.parts.first { $0.name == name } }

let bright = PowerBreakdown.make(channels: m3, total: 8, display: lidOpen)
check("CPU counts only the total channel, not its cores", near(part(bright, "CPU")?.watts, 1.4))
check("GPU counts only the total channel", near(part(bright, "GPU")?.watts, 0.4))
check("memory is DRAM and its controllers", near(part(bright, "Memory")?.watts, 1.9))
check("video and camera together", near(part(bright, "Video & camera")?.watts, 0.06))
check("unmeasured model: no made-up watts", part(bright, "Display")?.watts == nil)
check("unmeasured model: shows brightness", part(bright, "Display")?.detail == "Brightness 62%")
check("unmeasured model: everything else admits it holds the backlight", part(bright, "Everything else")?.detail == "Includes backlight")

let estimated = PowerBreakdown.make(channels: m3, total: 8, display: curve)
check("measured model: backlight estimate plus the display engine", near(part(estimated, "Display")?.watts, 2.6))
check("measured model: marked as an estimate", part(estimated, "Display")?.estimated == true)
check("measured model: backlight leaves everything else", near(part(estimated, "Everything else")?.watts, 8 - 2.6 - 1.4 - 0.4 - 1.9 - 0.06 - 0.31) && part(estimated, "Everything else")?.detail == "No sensors")
check("measured sensors aren't marked as estimates", part(estimated, "CPU")?.estimated == false)

func curveWatts(_ b: Double) -> Double { DisplayState.estimateBacklight(brightness: b, model: "Mac15,12") ?? -1 }
// Measurements from brightness changes on Mac15,12: increase from 10% to 50% and to 100%
check("curve matches the sweep: 10% to 50%", abs(curveWatts(0.5) - curveWatts(0.1) - 1.68) < 0.1)
check("curve matches the sweep: 10% to 100%", abs(curveWatts(1) - curveWatts(0.1) - 4.63) < 0.1)
check("curve stays in range", curveWatts(2) == curveWatts(1) && curveWatts(-1) == 0)
check("no curve for other models", DisplayState.estimateBacklight(brightness: 0.5, model: "Mac14,2") == nil)
check("idle Neural Engine still shows", near(part(bright, "Neural Engine")?.watts, 0))
check("the chip's leftovers get their own row", near(part(bright, "Rest of chip")?.watts, 0.31))
check("everything else is what's left of the total", near(part(bright, "Everything else")?.watts, 8 - 1.4 - 0.4 - 1.9 - 0.06 - 0.31))
check("parts add up to the total", near(bright.parts.reduce(0) { $0 + ($1.watts ?? 0) }, 8))

let shut = PowerBreakdown.make(channels: m3, total: 5, display: lidShut)
check("lid shut: only the display engine", near(part(shut, "Display")?.watts, 0.1))
check("lid shut: says the monitor powers itself", part(shut, "Display")?.detail == "External, own power")
check("lid shut: everything else has no backlight in it", part(shut, "Everything else")?.detail == "No sensors")

let noTotal = PowerBreakdown.make(channels: m3, total: nil, display: lidShut)
check("no total: everything else has no number", part(noTotal, "Everything else") != nil && part(noTotal, "Everything else")?.watts == nil)
check("no total: sums what it knows", near(noTotal.total, 4.17))

let low = PowerBreakdown.make(channels: m3, total: 1, display: lidShut)
check("total lagging behind the parts: never below their sum", near(low.total, 4.17) && near(part(low, "Everything else")?.watts, 0))

let npu = PowerBreakdown.make(channels: ["ANE0": 1.5, "CPU Energy": 1], total: 3, display: lidShut)
check("working Neural Engine shows", near(part(npu, "Neural Engine")?.watts, 1.5))

let a = PowerBreakdown(total: 4, parts: [PowerPart(name: "CPU", watts: 2)])
let b = PowerBreakdown(total: 8, parts: [PowerPart(name: "CPU", watts: 4), PowerPart(name: "GPU", watts: 1)])
let smooth = b.smoothed(after: a)
check("smooths towards the last reading", near(smooth.total, 6) && near(part(smooth, "CPU")?.watts, 3))
check("a part that just appeared isn't halved", near(part(smooth, "GPU")?.watts, 1))

let sample = [PowerActivity(name: "Wi-Fi", value: "Idle"), PowerActivity(name: "SSD", value: "12.0 MB/s"), PowerActivity(name: "Audio", value: "Idle")]
let full = PowerBreakdown.make(channels: m3, total: 9.6, display: curve, activity: sample)
check("Wi-Fi, SSD and audio sit under everything else", part(full, "Everything else")?.inside == sample)
check("activity adds no watts of its own", near(full.parts.reduce(0) { $0 + ($1.watts ?? 0) }, 9.6))
let usage = PowerBreakdown(total: 10, parts: [PowerPart(name: "A", watts: 1), PowerPart(name: "B", watts: nil), PowerPart(name: "C", watts: 5), PowerPart(name: "D", watts: 1.04), PowerPart(name: "E", watts: 3), PowerPart(name: "F", watts: 0), PowerPart(name: "G", watts: 0.1)]).sortedByUsage
check("sort: biggest first, no number last", usage.parts.map(\.name) == ["C", "E", "A", "D", "G", "F", "B"])
check("sort: parts showing the same number keep their order", usage.parts.firstIndex { $0.name == "A" }! < usage.parts.firstIndex { $0.name == "D" }!)
check("sort: never shows a smaller number above a bigger one", usage.parts.firstIndex { $0.name == "G" }! < usage.parts.firstIndex { $0.name == "F" }!)
check("rate: quiet is idle", PowerActivity.rate(500) == "Idle")
check("rate: kilobytes", PowerActivity.rate(20 * 1024) == "20 KB/s")
check("rate: megabytes", PowerActivity.rate(3.5 * 1024 * 1024) == "3.5 MB/s")

// Power flow in Power: the bands together are exactly what comes in
func flowSnap(ac: Bool, charging: Bool, watts: Double, system: Double, input: Double) -> PowerFlow {
    BatterySnapshot(percent: 60, isCharging: charging, onAC: ac, fullyCharged: false, minutes: nil, watts: watts,
                    adapterWatts: ac ? 35 : nil, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: 1000,
                    temperature: nil, systemWatts: system, inputWatts: input, lowPower: false).flow
}
let stale = flowSnap(ac: true, charging: true, watts: 22.15, system: 23.55, input: 32.7)
check("charging: battery and Mac add up to the input", near(stale.total, 32.7) && near(stale.toBattery, 22.15) && near(stale.adapterToMac, 10.55))
let weak = flowSnap(ac: true, charging: true, watts: 20, system: 5, input: 12)
check("charging: input below the charge is raised, never a negative Mac", near(weak.total, 20) && near(weak.adapterToMac, 0))
let resting = flowSnap(ac: true, charging: false, watts: 0, system: 9.9, input: 9.9)
check("holding on the adapter: all of it goes to the Mac", near(resting.total, 9.9) && near(resting.adapterToMac, 9.9) && resting.toBattery == 0)
let topUp = flowSnap(ac: true, charging: false, watts: -6, system: 30, input: 24)
check("adapter plus battery feed the Mac together", near(topUp.adapterToMac, 24) && near(topUp.batteryToMac, 6) && near(topUp.total, 30))
let unplugged = flowSnap(ac: false, charging: false, watts: -8, system: 7.5, input: 0)
check("on battery: the band is the Mac's draw, not the minute-old current", near(unplugged.total, 7.5) && unplugged.adapterToMac == 0)
let justUnplugged = flowSnap(ac: false, charging: false, watts: 3, system: 0, input: 0)
check("on battery with no draw known and a stale charge: no negative band", justUnplugged.batteryToMac == 0)
let noLoad = flowSnap(ac: false, charging: false, watts: -8, system: 0, input: 0)
check("on battery with no draw known: falls back to the battery current", near(noLoad.total, 8))
func snap(ac: Bool, watts: Double, system: Double, input: Double) -> BatterySnapshot {
    BatterySnapshot(percent: 60, isCharging: watts > 0, onAC: ac, fullyCharged: false, minutes: nil, watts: watts,
                    adapterWatts: ac ? 35 : nil, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: 1000,
                    temperature: nil, systemWatts: system, inputWatts: input, lowPower: false)
}
let onBattery = snap(ac: false, watts: -4.52, system: 4.4, input: 0)
check("on battery: the flow shows the same draw as the breakdown below it", near(onBattery.drawing(4.7).flow.total, 4.7))
check("on battery with the breakdown closed: the flow keeps its own draw", near(onBattery.drawing(nil).flow.total, 4.4))
let plugged = snap(ac: true, watts: 22.15, system: 10.55, input: 32.7)
check("on the adapter: the breakdown doesn't replace the input", plugged.drawing(9.8) == plugged)
let split = PowerFlow(toBattery: 22.15, adapterToMac: 10.55, batteryToMac: 0)
check("total is the sum of the band labels", near(split.shownTotal, 22.2 + 10.6))

// Live reading: without root and on a real chip
let monitor = PowerBreakdownMonitor()
var live: PowerBreakdown?
let deadline = Date().addingTimeInterval(8)
while live == nil, Date() < deadline {
    monitor.tick { live = $0 }
    pump(PowerBreakdownMonitor.tickInterval)
}
check("reads live counters without root", live != nil)
if let live {
    print("      " + live.parts.map { "\($0.name) \($0.watts.map { String(format: "%.2f", $0) } ?? "–")" }.joined(separator: ", ") + String(format: " | total %.2f W", live.total))
    print("      " + (part(live, "Everything else")?.inside ?? []).map { "\($0.name): \($0.value)" }.joined(separator: ", "))
    check("live CPU is a sane number", (part(live, "CPU")?.watts).map { $0 > 0 && $0 < 200 } ?? false)
}

// The timer lives only while the breakdown is visible and the popover is open
_ = NSApplication.shared
let wiring = AppModel()
wiring.charge.setPreview(installed: false, status: nil)
wiring.breakdownOnScreen = true
pump(4.5)
check("closed menu: nothing is measured", wiring.breakdown == nil)
wiring.popoverShown = true
pump(4.5)
check("open menu with the row open: numbers arrive", wiring.breakdown != nil)
wiring.breakdownOnScreen = false
pump(0.2)
wiring.breakdown = nil
pump(4.5)
check("row closed: measuring stops", wiring.breakdown == nil)
wiring.breakdownOnScreen = true
Settings.shared.minimalEnergy = true
wiring.popoverShown = false
wiring.popoverShown = true
wiring.breakdown = nil
pump(4.5)
check("Minimal energy use: nothing is measured", wiring.breakdown == nil)
Settings.shared.minimalEnergy = false
wiring.popoverShown = false
UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)

// PNG: expanded macOS row
NSApp.setActivationPolicy(.prohibited)
Brand.registerFonts(in: fonts)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ breakdown: PowerBreakdown?, _ name: String, dark: Bool = false) {
    let model = AppModel()
    model.charge.setPreview(installed: false, status: nil)
    model.expandedApp = AppEnergy.macOS
    model.breakdown = breakdown
    let app = AppEnergy(name: AppEnergy.macOS, bundlePath: "/System/Applications/System Settings.app", impact: 55,
                        processes: [("WindowServer", 41.5), ("VTDecoderXPCServ", 5.3), ("coreaudiod", 5.2), ("logd", 0.7)].map { (name: $0.0, impact: $0.1) },
                        history: [40, 60, 50, 45, 55, 52], average: 48)
    struct Row: View {
        let model: AppModel, app: AppEnergy, pal: Palette
        var body: some View {
            AppRow(model: model, app: app).padding(14).frame(width: 344)
                .background(pal.bg).foregroundStyle(pal.fg).environment(\.palette, pal).font(Brand.text(12))
        }
    }
    let host = NSHostingView(rootView: Row(model: model, app: app, pal: Palette(scheme: dark ? .dark : .light)))
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 344, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentView = host
    pump(0.3)
    win.setContentSize(host.fittingSize)
    host.layoutSubtreeIfNeeded()
    pump(0.2)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
    win.contentView = nil
}

render(bright, "lid-open-light")
render(bright, "lid-open-dark", dark: true)
render(shut, "lid-shut-dark", dark: true)
render(full, "full-fixed-dark", dark: true)
render(full, "full-fixed-light")
UserDefaults.standard.set(true, forKey: "powerBreakdownByUsage")
render(full, "full-by-usage-dark", dark: true)
UserDefaults.standard.removeObject(forKey: "powerBreakdownByUsage")
render(nil, "measuring-dark", dark: true)
if let live { render(live, "live-dark", dark: true) }

print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
