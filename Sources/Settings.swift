import Foundation
import ServiceManagement

/// Which percentage to show.
enum PercentMode: String, CaseIterable, Identifiable {
    case macOS = "As macOS shows"
    case trueCharge = "True charge"
    case ofDesign = "Of original capacity"
    var id: String { rawValue }
    var detail: String {
        switch self {
        case .macOS: "The smoothed number from the battery controller, same as pmset."
        case .trueCharge: "Remaining ÷ full capacity, straight from the cells — like AlDente's hardware percentage."
        case .ofDesign: "True charge × health, so it's measured against the battery when new. At 90% health a full battery shows 90%."
        }
    }
    var chargeScale: ChargeScale {
        switch self {
        case .macOS: .macOS
        case .trueCharge: .trueCharge
        case .ofDesign: .ofDesign
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
    case percentOnly = "Percent only"
    var id: String { rawValue }
}

/// How often to measure per-app energy. Each sample runs top for ~1 s, so less often is cheaper.
enum AppTracking: String, CaseIterable, Identifiable {
    case frequent = "Frequent"
    case normal = "Normal"
    case eco = "Eco"
    var id: String { rawValue }
    var interval: TimeInterval {
        switch self {
        case .frequent: 120
        case .normal: 300
        case .eco: 900
        }
    }
    var detail: String {
        switch self {
        case .frequent: "Every 2 minutes. The finest history, at the highest cost."
        case .normal: "Every 5 minutes. Enough for the 24-hour, 7-day and 30-day averages."
        case .eco: "Every 15 minutes. Still builds the history, at the lowest cost. Minimal energy use always uses this."
        }
    }
}

/// Which sound an alert plays. Each kind has its own setting, so the event can be told apart without looking.
enum AlertSound: String, CaseIterable, Identifiable {
    case plug, charged, unplug, low, critical, warning, deviceLow, deviceFull, lowPower, update
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plug: "Charger connected"
        case .charged: "Charged"
        case .unplug: "Charger disconnected"
        case .low: "Battery low"
        case .critical: "Battery critical"
        case .warning: "Warnings"
        case .deviceLow: "Device low"
        case .deviceFull: "Device charged"
        case .lowPower: "Low Power Mode"
        case .update: "New version"
        }
    }
    var detail: String? {
        switch self {
        case .critical: "At 5% or below, and the full-screen alert."
        case .warning: "Battery too hot, charger can't keep up."
        default: nil
        }
    }
    var defaultSound: String {
        switch self {
        case .plug, .charged: "Glass"
        case .unplug: "Pop"
        case .low: "Submarine"
        case .critical: "Sosumi"
        case .warning: "Funk"
        case .deviceLow: "Bottle"
        case .deviceFull: "Hero"
        case .lowPower: "Purr"
        case .update: "Ping"
        }
    }
}

struct DeviceRule: Codable, Equatable {
    var low: Int = 15          // 0 = don't alert
    var full: Bool = false     // alert when charged to 100%
    var hidden: Bool = false
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// The macOS system sounds (/System/Library/Sounds).
    static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    static let noSound = "None"

    @Published var lowAlerts: Set<Int> { didSet { d.set(Array(lowAlerts), forKey: "low") } }
    @Published var highAlerts: Set<Int> { didSet { d.set(Array(highAlerts), forKey: "high") } }
    @Published var onPlug: Bool { didSet { d.set(onPlug, forKey: "plug") } }
    @Published var onUnplug: Bool { didSet { d.set(onUnplug, forKey: "unplug") } }
    @Published var fullScreenAt: Int { didSet { d.set(fullScreenAt, forKey: "fullscreen") } }   // 0 = off
    @Published var deviceLowAt: Int { didSet { d.set(deviceLowAt, forKey: "deviceLow") } }     // 0 = off
    @Published var glow: Bool { didSet { d.set(glow, forKey: "glow") } }
    /// Master switch: off silences every alert, but keeps the per-alert choices.
    @Published var soundsOn: Bool { didSet { d.set(soundsOn, forKey: "soundsOn") } }
    /// Per-alert sound; a missing key means that kind's default. "None" mutes just that alert.
    @Published var alertSounds: [String: String] { didSet { d.set(alertSounds, forKey: "alertSounds") } }

    func sound(for kind: AlertSound) -> String { alertSounds[kind.rawValue] ?? kind.defaultSound }
    func setSound(_ name: String, for kind: AlertSound) {
        if name == kind.defaultSound { alertSounds.removeValue(forKey: kind.rawValue) } else { alertSounds[kind.rawValue] = name }
    }
    /// What to play for this alert, or nil when it should be silent.
    func soundToPlay(_ kind: AlertSound) -> String? {
        let name = sound(for: kind)
        return soundsOn && name != Self.noSound ? name : nil
    }
    @Published var iconStyle: IconStyle { didSet { d.set(iconStyle.rawValue, forKey: "icon") } }
    @Published var appIcon: AppIconVariant {
        didSet {
            d.set(appIcon.rawValue, forKey: "appIcon")
            if appIcon != oldValue { appIcon.apply() }
        }
    }
    @Published var smartColors: Bool { didSet { d.set(smartColors, forKey: "colors") } }
    @Published var percentMode: PercentMode { didSet { d.set(percentMode.rawValue, forKey: "percentMode") } }
    /// Only for the "Of original capacity" mode: set the limit in true charge, 0–100 %.
    @Published var limitTrueCharge: Bool { didSet { d.set(limitTrueCharge, forKey: "limitTrueCharge") } }
    var limitScale: ChargeScale { percentMode == .ofDesign && limitTrueCharge ? .trueCharge : percentMode.chargeScale }
    @Published var animateCharging: Bool { didSet { d.set(animateCharging, forKey: "animate") } }
    @Published var persistent: Bool { didSet { d.set(persistent, forKey: "persistent") } }
    @Published var heatAlert: Bool { didSet { d.set(heatAlert, forKey: "heat") } }
    /// Right-click on the icon toggles Low Power. Works only with the helper, since it doesn't ask for a password.
    @Published var rightClickLowPower: Bool { didSet { d.set(rightClickLowPower, forKey: "rightClickLowPower") } }
    @Published var appTracking: AppTracking { didSet { d.set(appTracking.rawValue, forKey: "appTracking") } }
    /// While the Power tab is open, wattage and per-app energy update more often.
    @Published var livePowerTab: Bool { didSet { d.set(livePowerTab, forKey: "livePowerTab") } }
    /// Minimal mode doesn't turn off per-app samples, it moves them to the slowest step.
    var effectiveAppTracking: AppTracking { minimalEnergy ? .eco : appTracking }
    /// Minimum energy: per-app energy in Eco mode, no animations or Bluetooth, everything else read less often. The charge limit and alerts stay.
    @Published var minimalEnergy: Bool { didSet { d.set(minimalEnergy, forKey: "minimalEnergy") } }
    /// Off — no Devices tab, no device polling, no Bluetooth, no device alerts.
    @Published var trackDevices: Bool { didSet { d.set(trackDevices, forKey: "trackDevices") } }
    /// Every few hours ask GitHub about a new version and show a banner in the popover.
    @Published var updateCheck: Bool { didSet { d.set(updateCheck, forKey: "updateCheck") } }
    /// Pill alert about a new version; stays until clicked or closed.
    @Published var updateAlert: Bool { didSet { d.set(updateAlert, forKey: "updateAlert") } }
    /// Download, verify the signature and replace the app automatically. With the helper — no password.
    @Published var autoInstall: Bool { didSet { d.set(autoInstall, forKey: "autoInstall") } }
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
                NSLog("Lynx Battery: launch at login — \(error.localizedDescription)")
                DispatchQueue.main.async { self.launchAtLogin = SMAppService.mainApp.status == .enabled }
            }
        }
    }

    /// Launch at login may have been turned off in System Settings while the app was running.
    func syncLaunchAtLogin() {
        let on = SMAppService.mainApp.status == .enabled
        if launchAtLogin != on { launchAtLogin = on }
    }

    private init() {
        d.register(defaults: [
            "low": [20, 10, 5], "high": [80], "plug": true, "unplug": true,
            "fullscreen": 3, "deviceLow": 15, "glow": true,
            "icon": IconStyle.inside.rawValue, "colors": true,
            "animate": true, "persistent": false, "heat": true, "trackDevices": true,
            "updateCheck": true, "updateAlert": true,
            "appTracking": AppTracking.normal.rawValue, "livePowerTab": true,
        ])
        lowAlerts = Set(d.array(forKey: "low") as? [Int] ?? [])
        highAlerts = Set(d.array(forKey: "high") as? [Int] ?? [])
        onPlug = d.bool(forKey: "plug")
        onUnplug = d.bool(forKey: "unplug")
        fullScreenAt = d.integer(forKey: "fullscreen")
        deviceLowAt = d.integer(forKey: "deviceLow")
        glow = d.bool(forKey: "glow")
        // Before per-alert sounds there was one "sound" setting; "None" there meant silence, so carry that over
        soundsOn = d.object(forKey: "soundsOn") as? Bool ?? (d.string(forKey: "sound") != Self.noSound)
        alertSounds = d.dictionary(forKey: "alertSounds") as? [String: String] ?? [:]
        iconStyle = IconStyle(rawValue: d.string(forKey: "icon") ?? "") ?? .inside
        appIcon = AppIconVariant(rawValue: d.string(forKey: "appIcon") ?? "") ?? .standard
        smartColors = d.bool(forKey: "colors")
        percentMode = PercentMode(rawValue: d.string(forKey: "percentMode") ?? "") ?? .trueCharge
        limitTrueCharge = d.bool(forKey: "limitTrueCharge")
        animateCharging = d.bool(forKey: "animate")
        persistent = d.bool(forKey: "persistent")
        heatAlert = d.bool(forKey: "heat")
        rightClickLowPower = d.bool(forKey: "rightClickLowPower")
        minimalEnergy = d.bool(forKey: "minimalEnergy")
        trackDevices = d.bool(forKey: "trackDevices")
        updateCheck = d.bool(forKey: "updateCheck")
        updateAlert = d.bool(forKey: "updateAlert")
        autoInstall = d.bool(forKey: "autoInstall")
        appTracking = AppTracking(rawValue: d.string(forKey: "appTracking") ?? "") ?? .normal
        livePowerTab = d.bool(forKey: "livePowerTab")
        deviceRules = (d.data(forKey: "deviceRules")).flatMap { try? JSONDecoder().decode([String: DeviceRule].self, from: $0) } ?? [:]
    }
}
