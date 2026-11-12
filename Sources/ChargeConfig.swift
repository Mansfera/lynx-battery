import Foundation

/// Shared by the app and the root helper: limit settings (written by the app) and status (written by the helper).
enum ChargePaths {
    #if HELPER_TEST
    // Tests/helper-pace.sh: a separate folder instead of the real one. This code isn't in a normal build, so the root helper takes no paths from outside.
    static let dir = ProcessInfo.processInfo.environment["HELPER_TEST_DIR"]!
    #else
    static let dir = "/Library/Application Support/com.mansfera.lynxbattery"
    #endif
    static let config = dir + "/charge-config.json"
    static let status = dir + "/charge-status.json"
    static let label = "com.mansfera.lynxbattery.helper"
    static let helperBinary = "/Library/PrivilegedHelperTools/com.mansfera.lynxbattery.helper"
    static let daemonPlist = "/Library/LaunchDaemons/com.mansfera.lynxbattery.helper.plist"
    static let log = "/var/log/lynx-battery-helper.log"
    /// Darwin notification the app sends after writing settings: the helper rereads the file right away.
    /// It's only "check the file" — the helper takes the settings themselves only from the file, so a foreign post changes nothing.
    #if HELPER_TEST
    static let configChanged = "com.mansfera.lynxbattery.test.config-changed:" + dir
    #else
    static let configChanged = "com.mansfera.lynxbattery.config-changed"
    #endif
    /// The app has dropped an update request (UpdateInstall.requestName) — likewise just "check the file".
    #if HELPER_TEST
    static let updateRequested = "com.mansfera.lynxbattery.test.update-requested:" + dir
    #else
    static let updateRequested = "com.mansfera.lynxbattery.update-requested"
    #endif

    // Helper under the old name: installing the new one stops and removes it so the two don't fight over charging
    static let legacyDir = "/Library/Application Support/Etherlynx Battery"
    static let legacyLabel = "xyz.etherlynx.battery.helper"
    static let legacyHelperBinary = "/Library/PrivilegedHelperTools/xyz.etherlynx.battery.helper"
    static let legacyDaemonPlist = "/Library/LaunchDaemons/xyz.etherlynx.battery.helper.plist"
    static let legacyLog = "/var/log/etherlynx-battery-helper.log"
}

/// Helper install: the app runs it with the password, and after `brew upgrade` the helper itself does via the cask.
enum ChargeInstall {
    static func script(helperPath: String, uid: uid_t) -> String {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(ChargePaths.label)</string>
          <key>ProgramArguments</key><array><string>\(ChargePaths.helperBinary)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardOutPath</key><string>\(ChargePaths.log)</string>
          <key>StandardErrorPath</key><string>\(ChargePaths.log)</string>
        </dict></plist>
        """
        return """
        set -e
        mkdir -p /Library/PrivilegedHelperTools '\(ChargePaths.dir)'
        launchctl bootout system/\(ChargePaths.legacyLabel) 2>/dev/null || true
        rm -f '\(ChargePaths.legacyDaemonPlist)' '\(ChargePaths.legacyHelperBinary)' '\(ChargePaths.legacyLog)'
        if [ -f '\(ChargePaths.legacyDir)/charge-config.json' ] && [ ! -f '\(ChargePaths.config)' ]; then
          cp '\(ChargePaths.legacyDir)/charge-config.json' '\(ChargePaths.config)'
        fi
        rm -rf '\(ChargePaths.legacyDir)'
        launchctl bootout system/\(ChargePaths.label) 2>/dev/null || true
        cp '\(helperPath)' '\(ChargePaths.helperBinary)'
        chown root:wheel '\(ChargePaths.helperBinary)'
        chmod 755 '\(ChargePaths.helperBinary)'
        cat > '\(ChargePaths.daemonPlist)' <<'PLIST'
        \(plist)
        PLIST
        chown root:wheel '\(ChargePaths.daemonPlist)'
        chmod 644 '\(ChargePaths.daemonPlist)'
        chown -R \(uid) '\(ChargePaths.dir)'
        launchctl bootstrap system '\(ChargePaths.daemonPlist)'
        """
    }

    /// brew removes the helper on upgrade but keeps the settings file: bring the helper back only if the limit was on.
    /// Read a single field so an older or newer settings file doesn't get in the way.
    static func shouldRestore(config: Data?) -> Bool {
        guard let config, let json = try? JSONSerialization.jsonObject(with: config) as? [String: Any] else { return false }
        return json["enabled"] as? Bool == true
    }
}

/// Which percentage the limit is set in: the same choice as Settings.percentMode (the helper can't see Settings).
enum ChargeScale: String, Codable {
    case macOS, trueCharge, ofDesign

    /// The helper reads the raw snapshot, where b.percent is the true charge.
    func percent(_ b: BatterySnapshot) -> Int {
        switch self {
        case .macOS: b.macPercent
        case .trueCharge: b.percent
        case .ofDesign: b.designPercent
        }
    }

    /// The highest value in this percentage: a limit at this mark means "charge to full".
    func top(_ b: BatterySnapshot) -> Int { self == .ofDesign ? b.designTop : 100 }

    /// The lowest limit: 15 % true charge. At ≤ 10 % the helper always charges, so a closer limit would bounce the charge back and forth.
    func lowest(_ b: BatterySnapshot) -> Int { min(top(b) - 1, ChargeScale.trueCharge.convert(15, to: self, b)) }

    /// The same physical charge value in another percentage, so the limit doesn't shift when the mode changes.
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
    var limit = 80            // in the scale percentage; 10…100, the slider doesn't go below ChargeScale.lowest
    /// Optional, since older settings files don't have it; nil — true charge, as before.
    var scale: ChargeScale?
    var sailing = true
    var sailRange = 5         // 2…20: resume charging only below limit − sailRange
    var heatProtection = true
    var heatMax = 35.0        // °C, as AlDente recommends, citing Apple
    var sleepUntilLimit = false
    var magsafeLED = true
    var discharge = true      // automatically drain down to the limit if the charge is higher
    var topUp = false         // once to full, then back to the limit
    /// Low Power mode request (right-click on the icon): the helper applies pmset without a password.
    var lowPower = false
    var lowPowerRequestAt: Date?
    /// The "Minimal energy use" toggle: the helper wakes less often. Optional, since older settings files don't have it.
    var minimalEnergy: Bool?

    /// How often the helper recomputes and writes status. Between recomputes it's woken by power notifications and settings changes.
    /// Together with timer leeway and the app's interval between reads, it must stay below ChargeStatus.aliveWindow.
    var tickInterval: TimeInterval { minimalEnergy == true ? 40 : 15 }
    /// How often to check the keys while something is paused. In 15 s macOS can't top up noticeably.
    var enforceInterval: TimeInterval { minimalEnergy == true ? 15 : 3 }

    /// Where Sailing turns charging back on: not below the helper's safety floor, and a negative number can't go into the firmware.
    var sailFloor: Int { max(10, limit - sailRange) }

    /// Where we're charging to now, in the percentage the user sees. Top Up and a disabled limit go to the ceiling.
    func chargingTarget(display: ChargeScale, _ b: BatterySnapshot) -> Int {
        let top = display.top(b)
        if !enabled || topUp { return top }
        return min(top, (scale ?? .trueCharge).convert(limit, to: display, b))
    }

    /// The helper runs as root and reads a file the user can edit — so only validated bounds.
    func sanitized() -> ChargeConfig {
        var c = self
        c.limit = min(100, max(10, c.limit))
        c.sailRange = min(20, max(2, c.sailRange))
        c.heatMax = min(45, max(30, c.heatMax))
        return c
    }
}

/// The firmware value (its percentage is the macOS one) where we stopped when the number reached the limit.
/// Valid only for this limit: if it survived raising the limit, the firmware would never start charging.
struct FirmwareHold {
    private(set) var upper: Int?
    private var limit: Int?

    mutating func update(limit newLimit: Int, shown: Int, macPercent: Int, charging: Bool, willDrain: Bool) {
        if newLimit != limit { upper = nil }
        limit = newLimit
        if willDrain || (charging && shown < newLimit) { upper = nil }
        else if shown >= newLimit { upper = macPercent }
    }

    mutating func reset() { upper = nil }
}

/// A raised limit charges right away, without waiting for the charge to drop to the old lower bound (sailing).
struct LimitRaise {
    private var limit: Int?
    private(set) var active = false

    mutating func update(limit new: Int, shown: Int) {
        if let old = limit {
            if new > old && shown < new { active = true }
            if new < old { active = false }
        }
        if shown >= new { active = false }
        limit = new
    }
}

/// Heat Protection: stops charging as soon as the battery hits the limit, and releases only after 5 min and cooling by `margin`.
/// The percentage we stopped at (on wall power) stays the same until the pause ends: a limit chasing the charge would rewrite the firmware every time.
struct HeatGuard {
    static let hold: TimeInterval = 300
    static let margin = 2.0

    private(set) var since: Date?
    private(set) var stopAt: Int?
    var active: Bool { since != nil }

    mutating func update(enabled: Bool, temperature: Double?, max: Double, macPercent: Int, plugged: Bool, now: Date = Date()) {
        guard enabled else { since = nil; stopAt = nil; return }
        // A missed sensor reading changes nothing
        if let t = temperature {
            if t >= max {
                if since == nil { since = now }
            } else if let s = since, t <= max - Self.margin, now.timeIntervalSince(s) >= Self.hold {
                since = nil
            }
        }
        stopAt = active && plugged ? stopAt ?? macPercent : nil
    }
}

/// When the adapter may be turned off to drain: turning it off also affects whatever is connected over the same cable.
enum AdapterCut {
    /// How long to wait without sleep after plugging in: a monitor brings its link up later than power appears.
    static let settle: TimeInterval = 30

    static func wouldDropDevices(_ ports: [PowerPort]) -> Bool { ports.contains(where: \.carriesDevices) }

    /// Cable pulled while the adapter is off: the charger shows up as a CC-only port, because a port with data wouldn't have allowed turning it off.
    /// Empty list — a Mac without these ports, we know nothing about it.
    static func chargerGone(_ ports: [PowerPort]) -> Bool {
        !ports.isEmpty && !ports.contains { $0.connected && !$0.carriesData }
    }

    static func allowed(_ ports: [PowerPort], adapterOn: Bool, onAC: Bool, wallFor: TimeInterval) -> Bool {
        if wouldDropDevices(ports) { return false }
        if !adapterOn { return !chargerGone(ports) }   // already off: power isn't visible, so only the port decides
        return onAC && wallFor >= settle
    }
}

struct ChargeStatus: Codable, Equatable {
    /// Status older than this means the helper isn't running.
    static let aliveWindow: TimeInterval = 60

    enum Mode: String, Codable {
        case off, charging, holding, discharging, heat, topUp, lowSafety, unsupported
    }
    var updated = Date()
    var mode: Mode = .off
    var percent = 0
    var temperature: Double?
    var adapterPaused = false
    var chargingPaused = false
    /// The limit is holding: the adapter powers the Mac, the battery neither charges nor discharges. Optional, since an older helper doesn't write this field.
    var wallHold: Bool?
    /// What this Mac supports: "charge-inhibit" (CHTE / CH0B+CH0C / firmware limit), "adapter" (CHIE / CH0I), "led" (ACLC), "firmware-limit" (bfF0, bfD0, bfE0).
    var capabilities: [String] = []
    var note: String?
}

/// Wakes when a file appears or is replaced in the folder — no polling. The app writes settings atomically, so it's a change to the folder itself.
final class FolderWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit { source.cancel() }
}
