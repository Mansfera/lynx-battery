import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var fullyCharged: Bool
    var minutes: Int?          // until empty or until full
    var watts: Double          // >0 — into the battery, <0 — out of the battery
    var adapterWatts: Int?
    var cycles: Int
    var designCycles: Int
    var designCapacity: Int    // mAh
    var fullCapacity: Int      // mAh, current full capacity
    var temperature: Double?
    var systemWatts: Double    // how much the Mac itself draws
    var inputWatts: Double     // how much is coming from the adapter right now
    var lowPower: Bool
    /// What macOS shows (CurrentCapacity) — for comparison with our number.
    var macPercent: Int = 0
    /// Charge relative to a new battery's capacity: true charge × health, so 100 % at 90 % health → 90 %.
    var designPercent: Int = 0
    /// What designPercent shows at full charge — the same number as health, and the limit ceiling in this mode.
    var designTop: Int = 100
    /// Ceiling of percent in the chosen mode: the app sets it along with percent. In the helper's raw snapshot it stays 100.
    var percentTop: Int = 100
    /// AppleRawMaxCapacity: how many mAh the battery holds now. Both health and charge derive from it, so the percentage agrees with mAh.
    var usableCapacity: Int = 0

    /// The number never reaches a threshold above the ceiling, so for it "reached" means a truly full battery.
    func reachedHigh(_ threshold: Int) -> Bool { threshold > percentTop ? fullyCharged : percent >= threshold }

    /// Plugged in, but the battery is draining. Many reasons: just plugged in, the limit is holding the charge, or macOS itself.
    var drainingOnAC: Bool { onAC && !isCharging && watts < -1.5 }

    /// The charger can't keep up: the Mac draws almost everything the adapter gives. Wattage unknown — assume so.
    var underpowered: Bool { drainingOnAC && adapterWatts.map { systemWatts >= Double($0) * 0.8 } ?? true }

    /// underpowered that has lasted longer than the adapter takes to negotiate power. Set by the app (WeakChargerTracker).
    var chargerTooWeak = false

    /// Where the power goes. On the adapter everything is computed from the input: the Mac gets what's left after the battery
    /// (including charging losses inside the Mac), so the flows always add up to the input rather than three separate readings.
    var flow: PowerFlow {
        // Without an adapter the Mac runs only on battery, even if the current hasn't updated yet (can take up to a minute): then it counts the Mac's draw
        guard onAC else { return PowerFlow(toBattery: 0, adapterToMac: 0, batteryToMac: systemWatts > 0 ? systemWatts : max(0, -watts)) }
        let toBattery = isCharging ? max(0, watts) : 0
        let input = max(inputWatts, toBattery)
        return PowerFlow(toBattery: toBattery, adapterToMac: input - toBattery, batteryToMac: max(0, -watts))
    }

    /// On battery the flow shows the same draw as the breakdown below it when that's open: both come from PSTR, but with different averaging
    func drawing(_ macWatts: Double?) -> BatterySnapshot {
        guard !onAC, let macWatts else { return self }
        var b = self
        b.systemWatts = macWatts
        return b
    }

    var needsService: Bool { health > 0 && (health < 80 || cycles >= designCycles) }

    /// Capacity health is computed from: what the battery holds now, or the design capacity without it.
    var healthCapacity: Int { usableCapacity > 0 ? usableCapacity : fullCapacity }

    var health: Int {
        guard designCapacity > 0 else { return 0 }
        return min(100, Int((Double(healthCapacity) / Double(designCapacity) * 100).rounded()))
    }

    /// target — where we're charging to: the limit or the mode ceiling. To full — just the time; to the limit — time to it and to full.
    var statusLine: String { statusLine(target: percentTop) }

    func statusLine(target: Int) -> String {
        if isCharging {
            let dest = min(percentTop, max(0, target))
            let toFull = dest >= percentTop
            let left = max(0, dest - percent)
            var s = "Charging"
            if let a = adapterWatts { s += " · \(a) W" }
            if let m = minutes, m > 0 {
                if toFull {
                    s += " · full in \(formatMinutes(m))"
                } else {
                    if left > 0 {
                        let span = max(1, percentTop - percent)
                        let eta = max(1, Int((Double(m) * Double(left) / Double(span)).rounded()))
                        s += " · \(formatMinutes(eta)) to \(dest)%"
                    }
                    s += " · \(formatMinutes(m)) to full"
                }
            }
            return s
        }
        if chargerTooWeak { return "Plugged in, still draining" }
        if drainingOnAC { return "Plugged in, using battery" }
        if onAC { return fullyCharged || percent >= percentTop ? "Charged · on power adapter" : "On adapter · not charging" }
        if let m = minutes { return "On battery · \(formatMinutes(m)) left" }
        return "On battery · estimating…"
    }
}

struct PowerFlow: Equatable {
    var toBattery: Double
    var adapterToMac: Double
    var batteryToMac: Double
    var total: Double { toBattery + adapterToMac + batteryToMac }
    /// Sum of the numbers shown on the bands: labels and "W total" don't diverge due to rounding
    var shownTotal: Double { [toBattery, adapterToMac, batteryToMac].reduce(0) { $0 + ($1 * 10).rounded() / 10 } }
}

/// Which high thresholds have already fired: each alerts once until the charge drops below it.
struct HighAlertTracker {
    private(set) var fired: Set<Int> = []

    /// Start: treat thresholds we're already past as fired, so we don't spam.
    mutating func start(_ thresholds: Set<Int>, _ b: BatterySnapshot) {
        fired = thresholds.filter { b.reachedHigh($0) }
    }

    /// The threshold to alert about now: fires only while charging, the highest one reached.
    mutating func update(_ thresholds: Set<Int>, _ b: BatterySnapshot) -> Int? {
        var hit: Int?
        if b.onAC, let t = thresholds.sorted(by: >).first(where: { b.reachedHigh($0) && !fired.contains($0) }) {
            fired.formUnion(thresholds.filter { $0 <= t })
            hit = t
        }
        // A threshold above the ceiling is reset relative to the ceiling: otherwise it would reset immediately and alert every time
        fired = fired.filter { b.percent >= min($0, b.percentTop) - 2 }
        return hit
    }

    /// A threshold above the ceiling is reached only on a full battery, so the title is the same as for 100.
    static func title(_ threshold: Int, _ b: BatterySnapshot) -> String {
        threshold >= 100 || threshold > b.percentTop ? "Fully charged" : "Charged to \(b.percent)%"
    }
}

/// After plugging in, a USB-C PD brick negotiates power in steps (5 → 15 → full) over a few seconds,
/// and macOS takes a bit longer to update AdapterDetails: only one that can't keep up for longer than settle counts as weak.
struct WeakChargerTracker {
    static let settle: TimeInterval = 30
    private(set) var since: Date?

    mutating func update(_ b: BatterySnapshot, now: Date = Date()) -> Bool {
        guard b.underpowered else { since = nil; return false }
        let start = since ?? now
        since = start
        return now.timeIntervalSince(start) >= Self.settle
    }
}

func formatMinutes(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    if h == 0 { return "\(mm) min" }
    return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
}

/// One power port: what's connected to it, from IOKit. Transports — "CC", "USB2", "USB3", "CIO" (Thunderbolt), "DisplayPort".
struct PowerPort: Equatable {
    var connected: Bool
    var transports: Set<String>

    /// A monitor or dock. USB2 alone doesn't count: a YubiKey looks the same, and IOKit doesn't say which port the power belongs to ("Power In" is always No).
    var carriesDevices: Bool { !transports.isDisjoint(with: ["DisplayPort", "CIO", "USB3"]) }
    var carriesData: Bool { !transports.subtracting(["CC"]).isEmpty }
}

enum BatteryReader {
    static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        // iMac, Mac mini, Studio: the service exists but there's no battery — then treat it as having none at all
        if (d["BatteryInstalled"] as? NSNumber)?.boolValue == false { return nil }
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        let design0 = ((d["DesignCapacity"] ?? bd["DesignCapacity"]) as? NSNumber)?.intValue ?? 0
        let full0 = ((d["NominalChargeCapacity"] ?? bd["FullChargeCapacity"]) as? NSNumber)?.intValue ?? 0
        if design0 == 0 && full0 == 0 { return nil }
        func num(_ k: String) -> Int? {
            ((d[k] ?? bd[k]) as? NSNumber).map { Int($0.int64Value) }
        }
        func flag(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        // CurrentCapacity is the controller's smoothed "UI SoC": on macOS 27 it differs from the menu bar
        // by a few percent (99 vs 95). We compute it like the system does: remaining / full capacity.
        let cur = num("CurrentCapacity") ?? 0
        let max = num("MaxCapacity") ?? 100
        var percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        // BatteryData may lack these fields (macOS 15): then take mAh from AppleRaw*, otherwise all modes show the same thing
        let rem = ((bd["RemainingCapacity"] ?? d["AppleRawCurrentCapacity"]) as? NSNumber)?.doubleValue
        let full = ((bd["FullChargeCapacity"] ?? d["AppleRawMaxCapacity"]) as? NSNumber)?.doubleValue
        if let rem, let full, full > 0, rem > 0 {
            percent = Int((rem / full * 100).rounded())
        }
        if flag("FullyCharged") { percent = 100 }
        let macPercent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        // Health and charge are computed from the same working capacity (AppleRawMaxCapacity), so a full battery gives exactly its Health
        let fullCapacity = num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity") ?? 0
        let usable = num("AppleRawMaxCapacity") ?? fullCapacity
        var designPercent = percent
        var designTop = 100
        if let design = num("DesignCapacity"), design > 0, usable > 0 {
            let worn = Swift.min(1, Double(usable) / Double(design))
            designPercent = Int((Double(Swift.min(100, percent)) * worn).rounded())
            designTop = Int((worn * 100).rounded())
        }
        var charging = flag("IsCharging")
        let ac = flag("ExternalConnected")
        var mA = Double(num("InstantAmperage") ?? num("Amperage") ?? 0)
        var liveInput: Double?
        // AppleSmartBattery updates these fields once a minute, while charging starts and stops within seconds
        if ac, !flag("FullyCharged"), let current = SMC.shared.chargeCurrent() {
            (charging, mA) = liveCharge(current: current, amperage: mA)
            // Input from the same moment as the current: the per-minute PowerTelemetryData doesn't agree with the live current
            liveInput = SMC.shared.read("PDTR").flatMap { $0.isFinite && $0 > 0 && $0 < 1000 ? $0 : nil }
        }

        var minutes: Int?
        if charging {
            if let t = num("AvgTimeToFull"), t > 0, t < 65535 { minutes = t }
        } else if !ac {
            if let t = num("AvgTimeToEmpty") ?? num("TimeRemaining"), t > 0, t < 65535 { minutes = t }
        }

        let mV = Double(num("Voltage") ?? 0)
        let adapter = (d["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
        let tel = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        func telW(_ k: String) -> Double { Double((tel[k] as? NSNumber)?.int64Value ?? 0) / 1000 }
        let battW = mV * mA / 1_000_000
        var load = telW("SystemLoad")
        if load <= 0 { load = Swift.max(0, -battW) }
        var input = telW("SystemPowerIn")
        if input <= 0 && ac { input = Swift.max(0, load + battW) }
        if let liveInput {
            input = liveInput
            load = Swift.max(0, input - battW)
        }

        return BatterySnapshot(
            percent: Swift.min(100, Swift.max(0, percent)),
            isCharging: charging,
            onAC: ac,
            fullyCharged: flag("FullyCharged"),
            minutes: minutes,
            watts: battW,
            adapterWatts: ac ? adapter?.intValue : nil,
            cycles: num("CycleCount") ?? 0,
            designCycles: num("DesignCycleCount9C") ?? 1000,
            designCapacity: num("DesignCapacity") ?? 0,
            fullCapacity: fullCapacity,
            temperature: SMC.shared.batteryTemperature(),
            systemWatts: load,
            inputWatts: ac ? input : 0,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            macPercent: macPercent,
            designPercent: designPercent,
            designTop: designTop,
            usableCapacity: num("AppleRawMaxCapacity") ?? full.map { Int($0) } ?? 0
        )
    }

    /// The live current beats the last reading: current flowing — charging; none — the charge current from ioreg is stale, but discharge stays.
    static func liveCharge(current: Int, amperage: Double) -> (charging: Bool, mA: Double) {
        current > 0 ? (true, Double(current)) : (false, min(0, amperage))
    }

    /// What's on the ports now. The properties are readable without root; empty where there are no such ports.
    static func powerPorts() -> [PowerPort] {
        var ports: [PowerPort] = []
        for cls in ["AppleHPMInterfaceType10", "AppleHPMInterfaceType11"] {
            var it: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(it) }
            while case let port = IOIteratorNext(it), port != 0 {
                defer { IOObjectRelease(port) }
                func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(port, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
                ports.append(PowerPort(connected: prop("ConnectionActive") as? Bool ?? false,
                                       transports: Set(prop("TransportsActive") as? [String] ?? [])))
            }
        }
        return ports
    }

    /// Instant updates when the charger is plugged in/unplugged.
    static func observe(_ handler: @escaping () -> Void) {
        let box = Unmanaged.passRetained(HandlerBox(handler)).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<HandlerBox>.fromOpaque(ctx).takeUnretainedValue().fn()
        }, box)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }

    private final class HandlerBox { let fn: () -> Void; init(_ f: @escaping () -> Void) { fn = f } }
}

enum LowPowerMode {
    /// pmset needs admin rights — macOS asks for the password itself.
    static func set(_ on: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let src = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async { completion(err == nil) }
        }
    }
}
