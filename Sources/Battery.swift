import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var fullyCharged: Bool
    var minutes: Int?          // до розряду або до повного
    var watts: Double          // >0 — у батарею, <0 — з батареї
    var adapterWatts: Int?
    var cycles: Int
    var designCycles: Int
    var designCapacity: Int    // мА·год
    var fullCapacity: Int      // мА·год, поточна повна ємність
    var temperature: Double?
    var systemWatts: Double    // скільки споживає сам Mac
    var inputWatts: Double     // скільки зараз іде від адаптера
    var lowPower: Bool
    /// Те, що показує macOS (CurrentCapacity) — для порівняння з нашим числом.
    var macPercent: Int = 0
    /// Заряд відносно ємності нової батареї: 100 % macOS при здоров'ї 90 % → 90 %.
    var designPercent: Int = 0

    /// Підключено, але батарея сідає. Причин багато: щойно підключили, заряд тримає ліміт або сама macOS.
    var drainingOnAC: Bool { onAC && !isCharging && watts < -1.5 }

    /// Зарядка справді не тягне: Mac споживає майже все, що дає адаптер. Потужність невідома — вважаємо, що так.
    var chargerTooWeak: Bool { drainingOnAC && adapterWatts.map { systemWatts >= Double($0) * 0.8 } ?? true }

    var needsService: Bool { health > 0 && (health < 80 || cycles >= designCycles) }

    var health: Int {
        guard designCapacity > 0 else { return 0 }
        return min(100, Int((Double(fullCapacity) / Double(designCapacity) * 100).rounded()))
    }

    var statusLine: String {
        if isCharging {
            var s = "Charging"
            if let a = adapterWatts { s += " · \(a) W" }
            if let m = minutes { s += " · full in \(formatMinutes(m))" }
            return s
        }
        if chargerTooWeak { return "Plugged in, still draining" }
        if drainingOnAC { return "Plugged in, using battery" }
        if onAC { return fullyCharged || percent >= 100 ? "Charged · on power adapter" : "On adapter · not charging" }
        if let m = minutes { return "On battery · \(formatMinutes(m)) left" }
        return "On battery · estimating…"
    }
}

func formatMinutes(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    if h == 0 { return "\(mm) min" }
    return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
}

enum BatteryReader {
    static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        // iMac, Mac mini, Studio: служба є, але батареї немає — тоді рахуємо, що її нема зовсім
        if (d["BatteryInstalled"] as? NSNumber)?.boolValue == false { return nil }
        let bd = d["BatteryData"] as? [String: Any] ?? [:]
        let design0 = ((d["DesignCapacity"] ?? bd["DesignCapacity"]) as? NSNumber)?.intValue ?? 0
        let full0 = ((d["NominalChargeCapacity"] ?? bd["FullChargeCapacity"]) as? NSNumber)?.intValue ?? 0
        if design0 == 0 && full0 == 0 { return nil }
        func num(_ k: String) -> Int? {
            ((d[k] ?? bd[k]) as? NSNumber).map { Int($0.int64Value) }
        }
        func flag(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        // CurrentCapacity — згладжений «UI SoC» контролера: на macOS 27 він розходиться з меню-баром
        // на кілька відсотків (99 проти 95). Рахуємо, як система: залишок / повна ємність.
        let cur = num("CurrentCapacity") ?? 0
        let max = num("MaxCapacity") ?? 100
        var percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        if let rem = (bd["RemainingCapacity"] as? NSNumber)?.doubleValue,
           let full = (bd["FullChargeCapacity"] as? NSNumber)?.doubleValue, full > 0, rem > 0 {
            percent = Int((rem / full * 100).rounded())
        }
        if flag("FullyCharged") { percent = 100 }
        let macPercent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        var designPercent = percent
        if let rem = (bd["RemainingCapacity"] as? NSNumber)?.doubleValue,
           let design = num("DesignCapacity"), design > 0 {
            designPercent = Swift.min(100, Int((rem / Double(design) * 100).rounded()))
        }
        let charging = flag("IsCharging")
        let ac = flag("ExternalConnected")

        var minutes: Int?
        if charging {
            if let t = num("AvgTimeToFull"), t > 0, t < 65535 { minutes = t }
        } else if !ac {
            if let t = num("AvgTimeToEmpty") ?? num("TimeRemaining"), t > 0, t < 65535 { minutes = t }
        }

        let mV = Double(num("Voltage") ?? 0)
        let mA = Double(num("InstantAmperage") ?? num("Amperage") ?? 0)
        let adapter = (d["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber
        let tel = d["PowerTelemetryData"] as? [String: Any] ?? [:]
        func telW(_ k: String) -> Double { Double((tel[k] as? NSNumber)?.int64Value ?? 0) / 1000 }
        let battW = mV * mA / 1_000_000
        var load = telW("SystemLoad")
        if load <= 0 { load = Swift.max(0, -battW) }
        var input = telW("SystemPowerIn")
        if input <= 0 && ac { input = Swift.max(0, load + battW) }

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
            fullCapacity: num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity") ?? 0,
            temperature: SMC.shared.batteryTemperature(),
            systemWatts: load,
            inputWatts: ac ? input : 0,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            macPercent: macPercent,
            designPercent: designPercent
        )
    }

    /// Миттєві оновлення при підключенні/відключенні зарядки.
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
    /// pmset потребує прав адміністратора — macOS сама попросить пароль.
    static func set(_ on: Bool, completion: @escaping () -> Void) {
        DispatchQueue.global().async {
            let src = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async(execute: completion)
        }
    }
}
