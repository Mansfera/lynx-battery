import Foundation
import IOKit.ps

struct BTDevice: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var kind: String            // Headphones, Keyboard, Mouse…
    var main: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var address: String?

    init(name: String, kind: String, main: Int? = nil, left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.name = name; self.kind = kind; self.main = main; self.left = left; self.right = right; self.caseLevel = caseLevel
    }

    /// Найнижчий рівень — за ним сортуємо й сповіщаємо.
    var lowest: Int? { [main, left, right].compactMap { $0 }.min() }

    /// Дозаповнює порожні рівні з іншого джерела: те саме пристрій часто бачать кілька.
    mutating func fill(from o: BTDevice) {
        main = main ?? o.main; left = left ?? o.left; right = right ?? o.right; caseLevel = caseLevel ?? o.caseLevel
        if kind.isEmpty { kind = o.kind }
    }

    var symbol: String {
        let k = kind.lowercased(), n = name.lowercased()
        if k == "phone" || n.contains("iphone") { return "iphone" }
        if k == "tablet" || n.contains("ipad") { return "ipad" }
        if k == "watch" { return "applewatch" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods") { return "airpods" }
        if k.contains("keyboard") { return "keyboard" }
        if k.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if k.contains("mouse") { return "magicmouse" }
        if k.contains("headphone") || k.contains("headset") { return "headphones" }
        if k.contains("game") { return "gamecontroller" }
        return "dot.radiowaves.left.and.right"
    }
}

enum DeviceReader {
    /// Три джерела: system_profiler (AirPods з L/R/кейсом), джерела живлення-аксесуари (звідти заряд бере Пункт керування,
    /// AirPods там є навіть без підключення) і реєстр IOKit (BatteryPercent — Magic Keyboard / Trackpad / Mouse на новій macOS).
    /// system_profiler повільний (~1 с) — викликати лише з фонової черги.
    /// paired — назви всіх спарених пристроїв (назва → тип), за ними BLE впізнає свої iPhone та iPad.
    static func read() -> (devices: [BTDevice], paired: [String: String]) {
        let (connected, names, paired) = readProfiler()
        var list = connected
        for var d in readPowerSources() + readIORegistry() {
            // Імʼя користувача («Magic Keyboard volo») беремо з system_profiler за адресою пристрою
            if let addr = d.address, let custom = names[addr] { d.name = custom }
            absorb(d, into: &list)
        }
        return (list.sorted { ($0.lowest ?? 101) < ($1.lowest ?? 101) }, paired)
    }

    /// Той самий пристрій із кількох джерел зливаємо в одну картку.
    static func absorb(_ d: BTDevice, into list: inout [BTDevice]) {
        if let i = list.firstIndex(where: { $0.name == d.name || $0.name.hasPrefix(d.name) }) { list[i].fill(from: d) }
        else { list.append(d) }
    }

    /// Те саме, що показує `pmset -g accps`. Публічний IOPSCopyPowerSourcesList віддає лише батарею Mac,
    /// аксесуари — тільки IOPSCopyPowerSourcesByType. Функція приватна, тож dlsym: зникне — просто втратимо це джерело.
    private static func readPowerSources() -> [BTDevice] {
        typealias ByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else { return [] } // RTLD_DEFAULT
        let accessories: Int32 = 4 // kIOPSSourceForAccessories
        guard let blob = unsafeBitCast(sym, to: ByType.self)(accessories)?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }

        // Кожен навушник і кейс — окреме джерело; збираємо їх в один пристрій
        var out: [String: BTDevice] = [:]
        for src in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  (info["Is Present"] as? Bool) ?? true,
                  let name = info["Name"] as? String,
                  let cur = (info["Current Capacity"] as? NSNumber)?.intValue else { continue }
            let max = (info["Max Capacity"] as? NSNumber)?.intValue ?? 100
            let level = min(100, Swift.max(0, max > 0 ? cur * 100 / max : cur))
            let group = (info["Accessory Identifier"] as? String) ?? (info["Group Identifier"] as? String) ?? name
            let part = info["Part Identifier"] as? String
            var d = out[group] ?? BTDevice(name: name, kind: "")
            switch part {
            case "Left": d.left = level
            case "Right": d.right = level
            case "Case": d.caseLevel = level
            default: d.main = level
            }
            // Назву й тип беремо з самого пристрою, а не з кейса («AirPods Case»)
            if part != "Case" {
                d.name = name
                d.kind = info["Accessory Category"] as? String ?? d.kind
            } else if d.kind.isEmpty {
                d.kind = "Headphones"
            }
            d.address = normalise(info["Group Identifier"] as? String)
            out[group] = d
        }
        return Array(out.values)
    }

    /// ioreg -r -k BatteryPercent -a: HID-пристрої Apple (і не тільки), що звітують заряд.
    private static func readIORegistry() -> [BTDevice] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-k", "BatteryPercent", "-a"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let arr = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return [] }
        var out: [BTDevice] = []
        for e in arr {
            guard let level = (e["BatteryPercent"] as? NSNumber)?.intValue,
                  let name = (e["Product"] as? String) ?? (e["DeviceName"] as? String) else { continue }
            let n = name.lowercased()
            let kind = n.contains("keyboard") ? "Keyboard" : n.contains("trackpad") ? "Magic Trackpad" : n.contains("mouse") ? "Mouse" : "Headphones"
            var d = BTDevice(name: name, kind: kind, main: min(100, max(0, level)))
            d.address = normalise((e["DeviceAddress"] as? String) ?? (e["SerialNumber"] as? String))
            if !out.contains(where: { $0.name == d.name && $0.address == d.address }) { out.append(d) }
        }
        return out
    }

    /// «aa-bb-cc…» і «AA:BB:CC…» — одна адреса.
    static func normalise(_ a: String?) -> String? {
        guard let a, !a.isEmpty else { return nil }
        return a.lowercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func readProfiler() -> ([BTDevice], [String: String], [String: String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ([], [:], [:]) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctrl = (root["SPBluetoothDataType"] as? [[String: Any]])?.first else { return ([], [:], [:]) }

        func level(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            return Int(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
        }

        var out: [BTDevice] = []
        var names: [String: String] = [:]
        var paired: [String: String] = [:]
        for entry in ctrl["device_not_connected"] as? [[String: Any]] ?? [] {
            for (name, value) in entry {
                guard let info = value as? [String: Any] else { continue }
                if let addr = normalise(info["device_address"] as? String) { names[addr] = name }
                paired[name] = info["device_minorType"] as? String ?? ""
            }
        }
        for entry in ctrl["device_connected"] as? [[String: Any]] ?? [] {
            for (name, value) in entry {
                guard let info = value as? [String: Any] else { continue }
                if let addr = normalise(info["device_address"] as? String) { names[addr] = name }
                paired[name] = info["device_minorType"] as? String ?? ""
                // Показуємо й те, що заряд не звітує: інакше вкладка каже «нічого не підключено», хоч пристрій підключений
                out.append(BTDevice(
                    name: name,
                    kind: info["device_minorType"] as? String ?? "",
                    main: level(info["device_batteryLevelMain"] ?? info["device_batteryLevel"]),
                    left: level(info["device_batteryLevelLeft"]),
                    right: level(info["device_batteryLevelRight"]),
                    caseLevel: level(info["device_batteryLevelCase"])
                ))
            }
        }
        return (out, names, paired)
    }
}
