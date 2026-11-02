import AppKit
import SwiftUI

// Розбивка потужності в рядку macOS: групування каналів, «усе інше», живе читання і PNG. Запуск: Tests/power-breakdown.sh

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.001 } ?? false }
func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

// Набір каналів із справжнього M3
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
check("measured model: backlight leaves everything else", near(part(estimated, "Everything else")?.watts, 8 - 2.6 - 1.4 - 0.4 - 1.9 - 0.06) && part(estimated, "Everything else")?.detail == "Wi-Fi, SSD, audio")
check("measured sensors aren't marked as estimates", part(estimated, "CPU")?.estimated == false)

func curveWatts(_ b: Double) -> Double { DisplayState.estimateBacklight(brightness: b, model: "Mac15,12") ?? -1 }
// Заміри зі зміни яскравості на Mac15,12: приріст від 10% до 50% і до 100%
check("curve matches the sweep: 10% to 50%", abs(curveWatts(0.5) - curveWatts(0.1) - 1.68) < 0.1)
check("curve matches the sweep: 10% to 100%", abs(curveWatts(1) - curveWatts(0.1) - 4.63) < 0.1)
check("curve stays in range", curveWatts(2) == curveWatts(1) && curveWatts(-1) == 0)
check("no curve for other models", DisplayState.estimateBacklight(brightness: 0.5, model: "Mac14,2") == nil)
check("idle Neural Engine stays hidden", part(bright, "Neural Engine") == nil)
check("everything else is what's left of the total", near(part(bright, "Everything else")?.watts, 8 - 1.4 - 0.4 - 1.9 - 0.06))
check("parts add up to the total", near(bright.parts.reduce(0) { $0 + ($1.watts ?? 0) }, 8))

let shut = PowerBreakdown.make(channels: m3, total: 5, display: lidShut)
check("lid shut: only the display engine", near(part(shut, "Display")?.watts, 0.1))
check("lid shut: says the monitor powers itself", part(shut, "Display")?.detail == "External, own power")
check("lid shut: everything else has no backlight in it", part(shut, "Everything else")?.detail == "Wi-Fi, SSD, audio")

let noTotal = PowerBreakdown.make(channels: m3, total: nil, display: lidShut)
check("no total: nothing to call everything else", part(noTotal, "Everything else") == nil)
check("no total: sums what it knows", near(noTotal.total, 3.86))

let low = PowerBreakdown.make(channels: m3, total: 1, display: lidShut)
check("total lagging behind the parts: never below their sum", near(low.total, 3.86) && part(low, "Everything else") == nil)

let npu = PowerBreakdown.make(channels: ["ANE0": 1.5, "CPU Energy": 1], total: 3, display: lidShut)
check("working Neural Engine shows", near(part(npu, "Neural Engine")?.watts, 1.5))

let a = PowerBreakdown(total: 4, parts: [PowerPart(name: "CPU", watts: 2)])
let b = PowerBreakdown(total: 8, parts: [PowerPart(name: "CPU", watts: 4), PowerPart(name: "GPU", watts: 1)])
let smooth = b.smoothed(after: a)
check("smooths towards the last reading", near(smooth.total, 6) && near(part(smooth, "CPU")?.watts, 3))
check("a part that just appeared isn't halved", near(part(smooth, "GPU")?.watts, 1))

// Живе читання: без root і на справжньому чипі
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
    check("live CPU is a sane number", (part(live, "CPU")?.watts).map { $0 > 0 && $0 < 200 } ?? false)
}

// Таймер живе лише поки розбивку видно й поповер відкритий
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

// PNG: розгорнутий рядок macOS
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
render(estimated, "measured-model-dark", dark: true)
render(nil, "measuring-dark", dark: true)
if let live { render(live, "live-dark", dark: true) }

print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
