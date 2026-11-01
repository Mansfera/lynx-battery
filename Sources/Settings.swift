import Foundation
import ServiceManagement

/// Який відсоток показувати.
enum PercentMode: String, CaseIterable, Identifiable {
    case macOS = "As macOS shows"
    case trueCharge = "True charge"
    case ofDesign = "Of original capacity"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .macOS: "The smoothed number from the battery controller, same as pmset."
        case .trueCharge: "Remaining ÷ full capacity, straight from the cells — like AlDente's hardware percentage."
        case .ofDesign: "Remaining ÷ capacity when new. At 90% health a full battery shows 90%."
        }
    }
    func pick(_ b: BatterySnapshot) -> Int {
        switch self {
        case .macOS: b.macPercent
        case .trueCharge: b.percent
        case .ofDesign: b.designPercent
        }
    }
}

enum IconStyle: String, CaseIterable, Identifiable {
    case inside = "Percent inside"
    case beside = "Percent beside"
    case iconOnly = "Icon only"
    var id: String { rawValue }
}

struct DeviceRule: Codable, Equatable {
    var low: Int = 15          // 0 = не сповіщати
    var full: Bool = false     // сповістити, коли зарядився до 100%
    var hidden: Bool = false
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    static let sounds = ["Glass", "Ping", "Pop", "Purr", "Submarine", "Tink", "Hero", "Funk", "Bottle", "None"]

    @Published var lowAlerts: Set<Int> { didSet { d.set(Array(lowAlerts), forKey: "low") } }
    @Published var highAlerts: Set<Int> { didSet { d.set(Array(highAlerts), forKey: "high") } }
    @Published var onPlug: Bool { didSet { d.set(onPlug, forKey: "plug") } }
    @Published var onUnplug: Bool { didSet { d.set(onUnplug, forKey: "unplug") } }
    @Published var fullScreenAt: Int { didSet { d.set(fullScreenAt, forKey: "fullscreen") } }   // 0 = вимкнено
    @Published var deviceLowAt: Int { didSet { d.set(deviceLowAt, forKey: "deviceLow") } }     // 0 = вимкнено
    @Published var glow: Bool { didSet { d.set(glow, forKey: "glow") } }
    @Published var sound: String { didSet { d.set(sound, forKey: "sound") } }
    @Published var iconStyle: IconStyle { didSet { d.set(iconStyle.rawValue, forKey: "icon") } }
    @Published var smartColors: Bool { didSet { d.set(smartColors, forKey: "colors") } }
    @Published var percentMode: PercentMode { didSet { d.set(percentMode.rawValue, forKey: "percentMode") } }
    @Published var animateCharging: Bool { didSet { d.set(animateCharging, forKey: "animate") } }
    @Published var persistent: Bool { didSet { d.set(persistent, forKey: "persistent") } }
    @Published var heatAlert: Bool { didSet { d.set(heatAlert, forKey: "heat") } }
    @Published var deviceRules: [String: DeviceRule] {
        didSet { d.set(try? JSONEncoder().encode(deviceRules), forKey: "deviceRules") }
    }

    func rule(_ name: String) -> DeviceRule { deviceRules[name] ?? DeviceRule(low: deviceLowAt) }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Etherlynx Battery: launch at login — \(error.localizedDescription)")
                DispatchQueue.main.async { self.launchAtLogin = SMAppService.mainApp.status == .enabled }
            }
        }
    }

    /// Автозапуск могли вимкнути в System Settings, поки апка працювала.
    func syncLaunchAtLogin() {
        let on = SMAppService.mainApp.status == .enabled
        if launchAtLogin != on { launchAtLogin = on }
    }

    private init() {
        d.register(defaults: [
            "low": [20, 10, 5], "high": [80], "plug": true, "unplug": true,
            "fullscreen": 3, "deviceLow": 15, "glow": true, "sound": "Glass",
            "icon": IconStyle.inside.rawValue, "colors": true,
            "animate": true, "persistent": false, "heat": true,
        ])
        lowAlerts = Set(d.array(forKey: "low") as? [Int] ?? [])
        highAlerts = Set(d.array(forKey: "high") as? [Int] ?? [])
        onPlug = d.bool(forKey: "plug")
        onUnplug = d.bool(forKey: "unplug")
        fullScreenAt = d.integer(forKey: "fullscreen")
        deviceLowAt = d.integer(forKey: "deviceLow")
        glow = d.bool(forKey: "glow")
        sound = d.string(forKey: "sound") ?? "Glass"
        iconStyle = IconStyle(rawValue: d.string(forKey: "icon") ?? "") ?? .inside
        smartColors = d.bool(forKey: "colors")
        percentMode = PercentMode(rawValue: d.string(forKey: "percentMode") ?? "") ?? .trueCharge
        animateCharging = d.bool(forKey: "animate")
        persistent = d.bool(forKey: "persistent")
        heatAlert = d.bool(forKey: "heat")
        deviceRules = (d.data(forKey: "deviceRules")).flatMap { try? JSONDecoder().decode([String: DeviceRule].self, from: $0) } ?? [:]
    }
}
