import Foundation
import IOKit.ps

/// Mac без батареї (iMac, mini, Studio): чи є батарея за словами macOS і скільки споживає система.
/// Окремий файл, бо хелпер цього не потребує: його бінарник не змінюється, тож апка не просить пароль на оновлення.
enum SystemPower {
    /// Щойно підключили адаптер: macOS ще до хвилини віддає старий струм батареї, і здається, що вона досі живить Mac.
    /// PDTR і PSTR живі: якщо адаптер покриває споживання, насправді розряду немає.
    static func dropStaleDrain(_ b: inout BatterySnapshot) {
        guard b.drainingOnAC, let input = SMC.shared.read("PDTR"), let load = SMC.shared.read("PSTR"),
              input > 0, input >= load - 0.5 else { return }
        b.watts = 0
    }

    /// На батареї SystemLoad і струм оновлюються раз на хвилину, а PSTR живий — той самий, що в розбивці «Whole Mac right now».
    static func liveDraw(_ b: inout BatterySnapshot) {
        guard !b.onAC, let load = SMC.shared.read("PSTR"), plausible(load) else { return }
        b.systemWatts = load
    }

    /// IOPS — те саме джерело, що й у pmset. Служба AppleSmartBattery сама по собі нічого не доводить:
    /// на Mac без батареї вона може існувати. NULL — це помилка, а не «батареї нема», тоді вирішує BatteryReader.
    static func hasInternalBattery() -> Bool {
        #if SIMULATE_NO_BATTERY
        return false
        #else
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        return hasInternalBattery(in: list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        })
        #endif
    }

    /// ДБЖ теж потрапляє в цей список, але він не робить настільний Mac ноутбуком.
    static func hasInternalBattery(in sources: [[String: Any]]) -> Bool {
        sources.contains { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && $0[kIOPSIsPresentKey] as? Bool != false }
    }

    /// PSTR — уся система (на MacBook збігається з SystemLoad батареї), PDTR — вхід від блока живлення.
    /// Обидва читаються без root. nil — цей Mac такого не повідомляє.
    static func readWatts() -> Double? {
        #if SIMULATE_NO_WATTS
        return nil
        #else
        return ["PSTR", "PDTR"].lazy.compactMap { SMC.shared.read($0) }.first(where: plausible)
        #endif
    }

    /// Працюючий Mac не споживає менше ватта: нуль чи сміття — це «не знаємо», а не показник.
    static func plausible(_ watts: Double) -> Bool { watts.isFinite && watts >= 1 && watts < 1000 }
}
