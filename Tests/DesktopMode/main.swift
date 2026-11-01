import AppKit
import SwiftUI

// Перевірка режиму Mac без батареї: логіка плюс PNG кожного екрана. Запуск: Tests/desktop-mode.sh
// Симуляцію вмикають ті самі прапорці компіляції, що й у build.sh.

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fonts = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
var failures = 0

func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL")  \(name)")
    if !ok { failures += 1 }
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
}

/// Без показу на екрані: вікно лише дає поповеру тему й розмір.
func render(_ model: AppModel, _ name: String, dark: Bool = false) {
    render(view: PopoverView(model: model), name, dark: dark)
}

func render<V: View>(view: V, _ name: String, dark: Bool = false) {
    let host = NSHostingView(rootView: view)
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 372, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    win.contentView = host
    pump(0.4)
    let size = host.fittingSize
    win.setContentSize(size)
    host.layoutSubtreeIfNeeded()
    pump(0.2)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    save(rep, name)
    win.contentView = nil
}

/// Вміст меню-бару на смузі потрібної теми — те, що updateIcon кладе в кнопку.
func renderMenu(_ states: [(name: String, devices: [BTDevice], watts: Double?)]) {
    let rowH: CGFloat = 26, width: CGFloat = 220, scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2 * scale), pixelsHigh: Int(rowH * CGFloat(states.count) * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width * 2, height: rowH * CGFloat(states.count))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (col, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let x0 = width * CGFloat(col)
            (col == 0 ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
            NSRect(x: x0, y: 0, width: width, height: rep.size.height).fill()
            for (i, s) in states.enumerated() {
                let y = rep.size.height - rowH * CGFloat(i + 1)
                let (img, title) = MenuIcon.desktop(devices: s.devices, watts: s.watts)
                let drawn = img.copy() as! NSImage
                if drawn.isTemplate {
                    drawn.lockFocus(); NSColor.labelColor.set(); NSRect(origin: .zero, size: drawn.size).fill(using: .sourceAtop); drawn.unlockFocus()
                }
                drawn.draw(in: NSRect(x: x0 + 10, y: y + (rowH - img.size.height) / 2, width: img.size.width, height: img.size.height))
                title.draw(at: NSPoint(x: x0 + 12 + img.size.width, y: y + (rowH - title.size().height) / 2))
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    save(rep, "menu-bar")
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)
Brand.registerFonts(in: fonts)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// MARK: - Логіка, однакова на будь-якому Mac

let internalBattery: [String: Any] = ["Type": "InternalBattery", "Is Present": true]
let ups: [String: Any] = ["Type": "UPS", "Is Present": true]
check("no power sources: no battery", !SystemPower.hasInternalBattery(in: []))
check("UPS alone: no battery", !SystemPower.hasInternalBattery(in: [ups]))
check("internal battery: has battery", SystemPower.hasInternalBattery(in: [internalBattery]))
check("internal battery next to a UPS: has battery", SystemPower.hasInternalBattery(in: [ups, internalBattery]))
check("internal battery marked not present: no battery", !SystemPower.hasInternalBattery(in: [["Type": "InternalBattery", "Is Present": false]]))
check("0 W and junk are not a reading", ![0, 0.28, -5, .nan, .infinity, 5000].contains(where: SystemPower.plausible))
check("idle and full-load draw are readings", [4, 14.1, 370].allSatisfy(SystemPower.plausible))

let mouse = BTDevice(name: "Magic Mouse", kind: "Mouse", main: 64)
let lowMouse = BTDevice(name: "Magic Mouse", kind: "Mouse", main: 12)
func title(_ d: [BTDevice], _ w: Double?) -> String { MenuIcon.desktop(devices: d, watts: w).1.string }
check("menu bar: watts", title([], 12.4) == " 12 W")
check("menu bar: a healthy device stays out of it", title([mouse], 12.4) == " 12 W")
check("menu bar: a low device stands next to the watts", title([lowMouse], 12.4) == " 12% 12 W")
check("menu bar: no watts falls back to the device", title([mouse], nil) == " 64%")
check("menu bar: no watts, no devices shows only the plug", title([], nil) == "")

renderMenu([("watts", [], 12.4), ("low device", [lowMouse], 37.6), ("no watts, device", [mouse], nil), ("no watts, no device", [], nil)])

// MARK: - Цей Mac: реальні показники

print("\nThis Mac: \(SystemPower.hasInternalBattery() ? "macOS reports an internal battery" : "no internal battery")")
for key in ["PSTR", "PDTR"] {
    print("  SMC \(key): \(SMC.shared.read(key).map { String(format: "%.2f W", $0) } ?? "missing")")
}
print("")

let model = AppModel()

#if SIMULATE_NO_BATTERY
model.devices = [lowMouse, BTDevice(name: "AirPods", kind: "Headphones", left: 80, right: 76, caseLevel: 55)]
model.refresh()
check("no battery snapshot", model.battery == nil)
check("opens on the Power tab", model.tab == .power)

#if SIMULATE_NO_WATTS
check("no watts when the keys are missing", model.macWatts == nil)
render(model, "no-watts-light")
render(model, "no-watts-dark", dark: true)
#else
check("a wattage straight away", model.macWatts != nil)
model.sampleEnergy()
var seen = Set<Double>()
for _ in 0..<7 { pump(AppModel.wattInterval); if let w = model.macWatts { seen.insert(w) } }
check("the wattage keeps updating", seen.count >= 2)
check("the history fills up", model.wattHistory.count >= 7)
check("energy by app works without a battery", !model.apps.isEmpty)
print("  live readings: " + model.wattHistory.map { String(format: "%.1f", $0) }.joined(separator: " "))
render(model, "power-light")
render(model, "power-dark", dark: true)
#endif

model.tab = .devices
render(model, "devices")
render(view: GeneralSettings(model: model), "settings-general")
render(view: AlertSettings(model: model), "settings-alerts")
render(view: AboutSettings(model: model), "settings-about")
#else
model.refresh()
let has = SystemPower.hasInternalBattery()
check("battery state matches macOS", (model.battery != nil) == has)
check("wattage stays off while there's a battery", !has || model.macWatts == nil)
check("Overview stays the first tab", !has || model.tab == .overview)
#endif

print(failures == 0 ? "\nAll passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
