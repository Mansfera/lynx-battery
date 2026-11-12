import Foundation
import IOKit.ps

/// Mac without a battery (iMac, mini, Studio): whether there's a battery according to macOS, and how much the system draws.
/// A separate file because the helper doesn't need it: its binary doesn't change, so the app doesn't ask for a password on update.
enum SystemPower {
    /// Adapter just plugged in: for up to a minute macOS still reports the old battery current, and it looks like the battery still powers the Mac.
    /// PDTR and PSTR are live: if the adapter covers the draw, there's actually no discharge.
    static func dropStaleDrain(_ b: inout BatterySnapshot) {
        guard b.drainingOnAC, let input = SMC.shared.read("PDTR"), let load = SMC.shared.read("PSTR"),
              input > 0, input >= load - 0.5 else { return }
        b.watts = 0
    }

    /// On battery, SystemLoad and the current update once a minute, while PSTR is live — the same as in the "Whole Mac right now" breakdown.
    static func liveDraw(_ b: inout BatterySnapshot) {
        guard !b.onAC, let load = SMC.shared.read("PSTR"), plausible(load) else { return }
        b.systemWatts = load
    }

    /// IOPS is the same source pmset uses. The AppleSmartBattery service alone proves nothing:
    /// it can exist on a Mac without a battery. NULL is an error, not "no battery"; then BatteryReader decides.
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

    /// A UPS also shows up in this list, but it doesn't make a desktop Mac a laptop.
    static func hasInternalBattery(in sources: [[String: Any]]) -> Bool {
        sources.contains { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType && $0[kIOPSIsPresentKey] as? Bool != false }
    }

    /// PSTR — the whole system (on a MacBook it matches the battery's SystemLoad), PDTR — input from the power supply.
    /// Both are readable without root. nil — this Mac doesn't report it.
    static func readWatts() -> Double? {
        #if SIMULATE_NO_WATTS
        return nil
        #else
        return ["PSTR", "PDTR"].lazy.compactMap { SMC.shared.read($0) }.first(where: plausible)
        #endif
    }

    /// A running Mac doesn't draw less than a watt: zero or garbage means "unknown", not a reading.
    static func plausible(_ watts: Double) -> Bool { watts.isFinite && watts >= 1 && watts < 1000 }
}
