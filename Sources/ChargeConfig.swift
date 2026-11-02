import Foundation

/// Спільне для апки й root-хелпера: налаштування ліміту (пише апка) і стан (пише хелпер).
enum ChargePaths {
    static let dir = "/Library/Application Support/Etherlynx Battery"
    static let config = dir + "/charge-config.json"
    static let status = dir + "/charge-status.json"
    static let label = "xyz.etherlynx.battery.helper"
    static let helperBinary = "/Library/PrivilegedHelperTools/xyz.etherlynx.battery.helper"
    static let daemonPlist = "/Library/LaunchDaemons/xyz.etherlynx.battery.helper.plist"
}

/// У якому відсотку задано ліміт: той самий вибір, що й Settings.percentMode (хелпер Settings не бачить).
enum ChargeScale: String, Codable {
    case macOS, trueCharge, ofDesign

    /// Хелпер читає сирий знімок, де b.percent — справжній заряд.
    func percent(_ b: BatterySnapshot) -> Int {
        switch self {
        case .macOS: b.macPercent
        case .trueCharge: b.percent
        case .ofDesign: b.designPercent
        }
    }

    /// Найбільше значення в цьому відсотку: ліміт на цій позначці означає «заряджати до повного».
    func top(_ b: BatterySnapshot) -> Int { self == .ofDesign ? b.designTop : 100 }

    /// Найнижчий ліміт: 15 % справжнього заряду. При ≤ 10 % хелпер заряджає завжди, тож ближчий ліміт ганяв би заряд туди й назад.
    func lowest(_ b: BatterySnapshot) -> Int { min(top(b) - 1, ChargeScale.trueCharge.convert(15, to: self, b)) }

    /// Те саме фізичне значення заряду в іншому відсотку, щоб при зміні режиму ліміт не зсувався.
    func convert(_ value: Int, to other: ChargeScale, _ b: BatterySnapshot) -> Int {
        if self == other { return value }
        let design = Double(max(1, b.designTop)) / 100
        let mac = Double(max(1, b.macPercent)) / Double(max(1, b.percent))
        var trueValue = Double(value)
        if self == .macOS { trueValue /= mac } else if self == .ofDesign { trueValue /= design }
        switch other {
        case .macOS: trueValue *= mac
        case .ofDesign: trueValue *= design
        case .trueCharge: break
        }
        return Int(trueValue.rounded())
    }
}

struct ChargeConfig: Codable, Equatable {
    var enabled = false
    var limit = 80            // у відсотку scale; 10…100, у повзунку не нижче ChargeScale.lowest
    /// Необов'язкове, бо в старому файлі налаштувань його немає; nil — справжній заряд, як раніше.
    var scale: ChargeScale?
    var sailing = true
    var sailRange = 5         // 2…20: повертаємо заряд лише нижче limit − sailRange
    var heatProtection = true
    var heatMax = 35.0        // °C, як радить AlDente з посиланням на Apple
    var sleepUntilLimit = false
    var magsafeLED = false
    var discharge = true      // автоматично розряджати до ліміту, якщо заряд вищий
    var topUp = false         // один раз до повного, потім назад до ліміту
    /// Запит на режим енергозбереження (ПКМ по іконці): хелпер застосовує pmset без пароля.
    var lowPower = false
    var lowPowerRequestAt: Date?

    /// Де Sailing знову вмикає заряд: не нижче межі безпеки хелпера, а в прошивку від'ємне число не піде.
    var sailFloor: Int { max(10, limit - sailRange) }

    /// Хелпер працює від root і читає файл, який може правити користувач, — тож лише перевірені межі.
    func sanitized() -> ChargeConfig {
        var c = self
        c.limit = min(100, max(10, c.limit))
        c.sailRange = min(20, max(2, c.sailRange))
        c.heatMax = min(45, max(30, c.heatMax))
        return c
    }
}

struct ChargeStatus: Codable, Equatable {
    enum Mode: String, Codable {
        case off, charging, holding, discharging, heat, topUp, lowSafety, unsupported
    }
    var updated = Date()
    var mode: Mode = .off
    var percent = 0
    var temperature: Double?
    var adapterPaused = false
    var chargingPaused = false
    /// Ліміт тримається: адаптер живить Mac, батарея не заряджається й не віддає. Необов'язкове, бо старий хелпер цього поля не пише.
    var wallHold: Bool?
    /// Що вміє цей Mac: "charge-inhibit" (CHTE / CH0B+CH0C / межа в прошивці), "adapter" (CHIE / CH0I), "led" (ACLC), "firmware-limit" (bfF0, bfD0, bfE0).
    var capabilities: [String] = []
    var note: String?
}
