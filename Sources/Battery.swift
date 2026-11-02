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
    /// Заряд відносно ємності нової батареї: справжній заряд × здоров'я, тож 100 % при здоров'ї 90 % → 90 %.
    var designPercent: Int = 0
    /// Скільки покаже designPercent на повному заряді — те саме число, що health, і стеля ліміту в цьому режимі.
    var designTop: Int = 100
    /// Стеля числа percent у вибраному режимі: його ставить апка разом із percent. У сирому знімку хелпера лишається 100.
    var percentTop: Int = 100

    /// Поріг вище стелі число не досягне ніколи, тож для нього «досягнуто» означає справді повну батарею.
    func reachedHigh(_ threshold: Int) -> Bool { threshold > percentTop ? fullyCharged : percent >= threshold }

    /// Підключено, але батарея сідає. Причин багато: щойно підключили, заряд тримає ліміт або сама macOS.
    var drainingOnAC: Bool { onAC && !isCharging && watts < -1.5 }

    /// Зарядка справді не тягне: Mac споживає майже все, що дає адаптер. Потужність невідома — вважаємо, що так.
    var chargerTooWeak: Bool { drainingOnAC && adapterWatts.map { systemWatts >= Double($0) * 0.8 } ?? true }

    var needsService: Bool { health > 0 && (health < 80 || cycles >= designCycles) }

    var health: Int {
        guard designCapacity > 0 else { return 0 }
        return min(100, Int((Double(fullCapacity) / Double(designCapacity) * 100).rounded()))
    }

    /// target — куди заряджаємось: ліміт або стеля режиму. До повного — лише час; до ліміту — час до нього й до повного.
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

/// Які високі пороги вже спрацювали: кожен сповіщає один раз, поки заряд не впаде нижче нього.
struct HighAlertTracker {
    private(set) var fired: Set<Int> = []

    /// Старт: вважаємо вже пройденими пороги, за якими ми зараз стоїмо, щоб не спамити.
    mutating func start(_ thresholds: Set<Int>, _ b: BatterySnapshot) {
        fired = thresholds.filter { b.reachedHigh($0) }
    }

    /// Поріг, про який треба сповістити зараз: спрацьовує лише при зарядці, найвищий із досягнутих.
    mutating func update(_ thresholds: Set<Int>, _ b: BatterySnapshot) -> Int? {
        var hit: Int?
        if b.onAC, let t = thresholds.sorted(by: >).first(where: { b.reachedHigh($0) && !fired.contains($0) }) {
            fired.formUnion(thresholds.filter { $0 <= t })
            hit = t
        }
        // Поріг вище стелі скидаємо відносно стелі: інакше він скинувся б одразу й сповіщав щоразу
        fired = fired.filter { b.percent >= min($0, b.percentTop) - 2 }
        return hit
    }

    /// Поріг вище стелі досягається лише на повній батареї, тож і заголовок той самий, що для 100.
    static func title(_ threshold: Int, _ b: BatterySnapshot) -> String {
        threshold >= 100 || threshold > b.percentTop ? "Fully charged" : "Charged to \(b.percent)%"
    }
}

func formatMinutes(_ m: Int) -> String {
    let h = m / 60, mm = m % 60
    if h == 0 { return "\(mm) min" }
    return mm == 0 ? "\(h) h" : "\(h) h \(mm) min"
}

/// Один порт живлення: що на ньому підключено, з IOKit. Транспорти — "CC", "USB2", "USB3", "CIO" (Thunderbolt), "DisplayPort".
struct PowerPort: Equatable {
    var connected: Bool
    var transports: Set<String>

    /// Монітор чи док. Лише USB2 не рахуємо: так виглядає й YubiKey, а якому порту належить живлення, IOKit не каже ("Power In" завжди No).
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
        // У BatteryData цих полів може не бути (macOS 15): тоді мА·год беремо з AppleRaw*, інакше всі режими показують те саме
        let rem = ((bd["RemainingCapacity"] ?? d["AppleRawCurrentCapacity"]) as? NSNumber)?.doubleValue
        let full = ((bd["FullChargeCapacity"] ?? d["AppleRawMaxCapacity"]) as? NSNumber)?.doubleValue
        if let rem, let full, full > 0, rem > 0 {
            percent = Int((rem / full * 100).rounded())
        }
        if flag("FullyCharged") { percent = 100 }
        let macPercent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
        // Здоров'я рахуємо від NominalChargeCapacity, а заряд — від меншої робочої ємності (AppleRawMaxCapacity).
        // Ділити залишок на DesignCapacity не можна: повна батарея не дійшла б до свого ж Health (85 проти 88).
        let fullCapacity = num("NominalChargeCapacity") ?? num("AppleRawMaxCapacity") ?? 0
        var designPercent = percent
        var designTop = 100
        if let design = num("DesignCapacity"), design > 0, fullCapacity > 0 {
            let worn = Swift.min(1, Double(fullCapacity) / Double(design))
            designPercent = Int((Double(Swift.min(100, percent)) * worn).rounded())
            designTop = Int((worn * 100).rounded())
        }
        var charging = flag("IsCharging")
        let ac = flag("ExternalConnected")
        var mA = Double(num("InstantAmperage") ?? num("Amperage") ?? 0)
        // AppleSmartBattery оновлює ці поля раз на хвилину, а заряд починається й зупиняється за секунди
        if ac, !flag("FullyCharged"), let current = SMC.shared.chargeCurrent() {
            (charging, mA) = liveCharge(current: current, amperage: mA)
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
            designTop: designTop
        )
    }

    /// Живий струм важливіший за останнє прочитане: є струм — заряджається; немає — зарядний струм із ioreg уже застарів, а розряд лишаємо.
    static func liveCharge(current: Int, amperage: Double) -> (charging: Bool, mA: Double) {
        current > 0 ? (true, Double(current)) : (false, min(0, amperage))
    }

    /// Що зараз на портах. Властивості читаються без root; порожньо там, де таких портів немає.
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
    static func set(_ on: Bool, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global().async {
            let src = "do shell script \"/usr/bin/pmset -a lowpowermode \(on ? 1 : 0)\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            DispatchQueue.main.async { completion(err == nil) }
        }
    }
}
