import Foundation
import IOKit.pwr_mgt
import notify

// Lynx Battery root helper. Enforces the charge limit, Sailing, Heat Protection, Top Up, MagSafe LED.
//
// The levers depend on the firmware:
//  • firmware limit — bfF0, bfD0, bfE0 (20xxx firmware): the firmware itself stops charging, the adapter powers the Mac, and it works in sleep too;
//  • charge inhibit — CHTE or CH0B+CH0C: the adapter powers the Mac, the battery holds;
//  • adapter off — CH0I: the Mac runs on battery (drains down to the limit).
//  • CHIE behaves differently across firmware (on macOS 27 it acts as charge inhibit),
//    so on first use the helper checks what actually happened and remembers the key's role.
// On exit, when the limit is turned off, and at charge ≤ 10 % it always restores normal charging.

setvbuf(stdout, nil, _IOLBF, 0)

// The cask runs this without root before --restore: with the limit on, the helper comes back even if it wasn't there before the upgrade.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--mark-restore" {
    guard ChargeInstall.shouldRestore(config: FileManager.default.contents(atPath: ChargePaths.config)) else { exit(0) }
    exit(FileManager.default.createFile(atPath: CommandLine.arguments[2], contents: nil) ? 0 : 1)
}

// The cask runs this via sudo at the end of `brew upgrade` when the marker is present. Before touching any SMC keys: this isn't the daemon, it only reinstalls itself.
if CommandLine.arguments.dropFirst().first == "--restore" {
    guard getuid() == 0 else { print("--restore needs root"); exit(1) }
    let attrs = try? FileManager.default.attributesOfItem(atPath: ChargePaths.dir)
    guard let owner = (attrs?[.ownerAccountID] as? NSNumber)?.uint32Value, owner != 0, CommandLine.arguments[0].hasPrefix("/") else {
        print("Can't restore the helper: reinstall it from the Charge tab.")
        exit(1)
    }
    let install = Process()
    install.executableURL = URL(fileURLWithPath: "/bin/sh")
    install.arguments = ["-c", ChargeInstall.script(helperPath: CommandLine.arguments[0], uid: owner)]
    try? install.run()
    install.waitUntilExit()
    exit(install.terminationStatus)
}

let smc = SMC.shared
let fm = FileManager.default

let hasCHTE = smc.info("CHTE") != nil
let hasCH0B = smc.info("CH0B") != nil && smc.info("CH0C") != nil
let hasCHIE = smc.info("CHIE") != nil
let hasCH0I = smc.info("CH0I") != nil
let hasLED = smc.info("ACLC") != nil

/// The firmware limit is available while the firmware accepts writes. Some 20xxx builds reject them even from root — then the old scheme applies.
var firmwareLimit = smc.info("bfF0") != nil && smc.info("bfD0") != nil && smc.info("bfE0") != nil
/// Which limit we should hold in the firmware; nil — off.
var firmwareTarget: (lower: Int, upper: Int)?

enum Role: String { case unknown, inhibit, adapter, none }
/// CHIE's role, determined by the self-test. With a firmware limit CHIE only turns the adapter off for draining, as described in batt, so no self-test.
var chieRole: Role = !hasCHIE ? .none : (firmwareLimit ? .adapter : .unknown)
var chieTestStart: Date?

var canInhibit: Bool { firmwareLimit || hasCHTE || hasCH0B || chieRole == .inhibit || chieRole == .unknown }
var canCutAdapter: Bool { hasCH0I || chieRole == .adapter }

func log(_ s: String) { print("[\(Date())] \(s)") }

func writeCHIE(_ on: Bool) { smc.write("CHIE", [on ? 0x00 : 0x08]) }

/// Percentages in the limit keys are little-endian ui32: 80 % is 50 00 00 00.
func le32(_ v: Int) -> [UInt8] { [UInt8(v), 0, 0, 0] }

func firmwareLimitIs(lower: Int, upper: Int) -> Bool {
    smc.readBytes("bfF0") == [2] && smc.readBytes("bfD0") == le32(upper) && smc.readBytes("bfE0") == le32(lower)
}

/// The firmware requires this write order: disable, upper limit, lower limit, enable. We only write what changed.
func applyFirmwareLimit(lower: Int, upper: Int) -> Bool {
    if firmwareLimitIs(lower: lower, upper: upper) { return true }
    guard smc.write("bfF0", [0]), smc.write("bfD0", le32(upper)), smc.write("bfE0", le32(lower)), smc.write("bfF0", [2]) else { return false }
    return firmwareLimitIs(lower: lower, upper: upper)
}

func disableFirmwareLimit() { if smc.readBytes("bfF0") != [0] { smc.write("bfF0", [0]) } }

/// The firmware didn't accept the limit: fall back to the old levers and the CHIE self-test, as on a Mac without these keys.
func dropFirmwareLimit() {
    firmwareLimit = false
    firmwareTarget = nil
    if hasCHIE { chieRole = .unknown }
    log("firmware limit refused, using the older levers")
}

/// Holds the required limit in the firmware; nil turns it off so charging works as usual.
func setFirmwareTarget(_ t: (lower: Int, upper: Int)?) {
    guard firmwareLimit else { return }
    if t?.lower == firmwareTarget?.lower && t?.upper == firmwareTarget?.upper { return }
    firmwareTarget = t
    if let t {
        if applyFirmwareLimit(lower: t.lower, upper: t.upper) { log("firmware limit \(t.lower)–\(t.upper)") } else { dropFirmwareLimit() }
    } else {
        disableFirmwareLimit()
        log("firmware limit off")
    }
}

/// Pause charging (the adapter keeps powering the Mac).
func setCharging(_ on: Bool) {
    if firmwareLimit { return }   // the firmware itself stops charging
    if hasCHTE { smc.write("CHTE", on ? [0, 0, 0, 0] : [1, 0, 0, 0]) }
    else if hasCH0B { smc.write("CH0B", [on ? 0 : 2]); smc.write("CH0C", [on ? 0 : 2]) }
    else if chieRole == .inhibit || chieRole == .unknown {
        writeCHIE(on)
        if !on && chieRole == .unknown && chieTestStart == nil { chieTestStart = Date() }
    }
}

/// Turn the adapter off (the Mac runs on battery).
func setAdapter(_ on: Bool) {
    if hasCH0I { smc.write("CH0I", [on ? 0 : 1]) }
    else if chieRole == .adapter { writeCHIE(on) }
}

/// ACLC: 0 — system controlled, 3 — green, 4 — orange.
func setLED(_ v: UInt8) { if hasLED { smc.write("ACLC", [v]) } }

func restoreAll() {
    if firmwareLimit { disableFirmwareLimit() }
    if hasCHTE { smc.write("CHTE", [0, 0, 0, 0]) }
    if hasCH0B { smc.write("CH0B", [0]); smc.write("CH0C", [0]) }
    if hasCHIE { writeCHIE(true) }
    if hasCH0I { smc.write("CH0I", [0]) }
    setLED(0)
}

for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig) { _ in restoreAll(); exit(0) }
}
// Start from a clean state: after a crash or an update nothing stays paused
restoreAll()

// MARK: - State

var chargingOn = true
var adapterOn = true
var ledValue: UInt8 = 0
var holding = false           // reached the limit and waiting for it to drop to limit − sailRange
var draining = false          // draining down to the limit; switches on with a margin so 72↔73 rounding doesn't toggle the adapter
var hold = FirmwareHold()
var limitRaise = LimitRaise()
var wallSince: TimeInterval?   // since when the Mac is on wall power with no monitor visible: its link doesn't come up right away, including after sleep
var cutBlockedLogged = false
var heat = HeatGuard()
var sleepAssertion: IOPMAssertionID = 0
var lastLowPowerRequest: Date?
var tickTimer: Timer?
var enforceTimer: Timer?

func loadConfig() -> ChargeConfig {
    guard let d = fm.contents(atPath: ChargePaths.config),
          let c = try? JSONDecoder().decode(ChargeConfig.self, from: d) else { return ChargeConfig() }
    return c.sanitized()
}

func saveConfig(_ c: ChargeConfig) {
    if let d = try? JSONEncoder().encode(c) { fm.createFile(atPath: ChargePaths.config, contents: d) }
}

func writeStatus(_ st: ChargeStatus) {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    if let d = try? enc.encode(st) {
        fm.createFile(atPath: ChargePaths.status, contents: d, attributes: [.posixPermissions: 0o644])
    }
}

func preventSleep(_ on: Bool) {
    if on, sleepAssertion == 0 {
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Lynx Battery: charging to the limit" as CFString, &sleepAssertion)
    } else if !on, sleepAssertion != 0 {
        IOPMAssertionRelease(sleepAssertion)
        sleepAssertion = 0
    }
}

func applyLowPower(_ cfg: ChargeConfig) {
    guard let at = cfg.lowPowerRequestAt, at != lastLowPowerRequest else { return }
    lastLowPowerRequest = at
    guard Date().timeIntervalSince(at) < 60 else { return }   // don't execute stale requests
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-a", "lowpowermode", cfg.lowPower ? "1" : "0"]
    try? p.run(); p.waitUntilExit()
    log("low power \(cfg.lowPower)")
}

/// 20 s after the first CHIE pause, check what happened and record the key's role.
func classifyCHIE(_ b: BatterySnapshot) {
    guard chieRole == .unknown, let t = chieTestStart, Date().timeIntervalSince(t) > 20 else { return }
    // If macOS reset the key in the meantime, the measurement means nothing — try again
    if smc.readBytes("CHIE") != [0x08] { writeCHIE(false); chieTestStart = Date(); log("CHIE was reset during the test, retrying"); return }
    if !b.onAC || b.watts < -0.3 { chieRole = .adapter }          // the Mac switched to battery
    else if !b.isCharging { chieRole = .inhibit }                 // adapter present, but charging is held
    else { chieRole = .none; writeCHIE(true); chargingOn = true }  // nothing changed — roll back
    log("CHIE role: \(chieRole.rawValue)")
    if chieRole == .adapter {
        // We set "pause charging", but the key actually turns the adapter off — from now on treat it as the adapter lever
        chargingOn = true; adapterOn = false
    }
}

/// macOS (its own charge management) resets the keys, so we read them every time and rewrite them if needed.
var reasserts = 0
func enforce() {
    func check(_ key: String, _ want: [UInt8]) {
        guard let now = smc.readBytes(key), now != want else { return }
        smc.write(key, want)
        reasserts += 1
        if reasserts <= 20 || reasserts % 50 == 0 { log("re-asserted \(key) (was \(now.map { String(format: "%02x", $0) }.joined()), #\(reasserts))") }
    }
    if firmwareLimit {
        // macOS or another app can reset the firmware limit too
        if let t = firmwareTarget {
            if !firmwareLimitIs(lower: t.lower, upper: t.upper) {
                reasserts += 1
                log("re-asserted firmware limit (#\(reasserts))")
                if !applyFirmwareLimit(lower: t.lower, upper: t.upper) { dropFirmwareLimit() }
            }
        } else { disableFirmwareLimit() }
    } else if hasCHTE { check("CHTE", chargingOn ? [0, 0, 0, 0] : [1, 0, 0, 0]) }
    else if hasCH0B { check("CH0B", [chargingOn ? 0 : 2]); check("CH0C", [chargingOn ? 0 : 2]) }
    if hasCHIE {
        let paused = (chieRole == .adapter && !adapterOn) || ((chieRole == .inhibit || chieRole == .unknown) && !chargingOn)
        check("CHIE", [paused ? 0x08 : 0x00])
    }
    if hasCH0I { check("CH0I", [adapterOn ? 0 : 1]) }
    if hasLED && ledValue != 0 { check("ACLC", [ledValue]) }
}

// MARK: - Decision

/// Timers follow the settings: a toggle in the app takes effect on the next tick.
func scheduleTimers(_ cfg: ChargeConfig) {
    if tickTimer?.timeInterval != cfg.tickInterval {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: cfg.tickInterval, repeats: true) { _ in tick() }
        tickTimer?.tolerance = cfg.tickInterval / 8
    }
    // While something is paused, check the keys so macOS doesn't get a chance to top up
    if enforceTimer?.timeInterval != cfg.enforceInterval {
        enforceTimer?.invalidate()
        enforceTimer = Timer.scheduledTimer(withTimeInterval: cfg.enforceInterval, repeats: true) { _ in
            if !chargingOn || !adapterOn { enforce() }
        }
        enforceTimer?.tolerance = cfg.enforceInterval / 8
    }
}

func tick() {
    var cfg = loadConfig()
    scheduleTimers(cfg)
    applyLowPower(cfg)
    guard let b = BatteryReader.read() else { return }
    classifyCHIE(b)
    if b.onAC && adapterOn { wallSince = wallSince ?? ProcessInfo.processInfo.systemUptime } else { wallSince = nil }

    // The limit is held in the percentage the user sees; safety (≤ 10 %) and Top Up use the true charge
    let scale = cfg.scale ?? .trueCharge
    let shown = scale.percent(b)
    let toFull = cfg.limit >= scale.top(b)

    var st = ChargeStatus(percent: shown, temperature: b.temperature)
    st.capabilities = (canInhibit && chieRole != .unknown || hasCHTE || hasCH0B ? ["charge-inhibit"] : [])
        + (canCutAdapter ? ["adapter"] : []) + (hasLED ? ["led"] : []) + (firmwareLimit ? ["firmware-limit"] : [])
        + (UpdateSignature.hasUsableKey(UpdateKey.trusted) ? ["app-update"] : [])

    // What we want: stop — don't charge; drain — also turn the adapter off to go down to the limit
    var stop = false, drain = false
    let lower = cfg.sailing ? cfg.sailFloor : cfg.limit - 1
    // The firmware limit; nil — off, i.e. charging works as usual (limit off, Top Up, ≤ 10 %)
    var target: (lower: Int, upper: Int)?

    if !cfg.enabled || (!canInhibit && !canCutAdapter) {
        holding = false
        draining = false
        st.mode = (!canInhibit && !canCutAdapter) ? .unsupported : .off
        if chieRole == .none && !hasCHTE && !hasCH0B && !hasCH0I { st.note = "This Mac's firmware ignored the charge-control keys, so the limit is off." }
    } else if b.percent <= 10 {
        holding = false
        st.mode = .lowSafety
    } else if cfg.topUp {
        st.mode = .topUp
        if b.fullyCharged || b.percent >= 100 {
            cfg.topUp = false
            saveConfig(cfg)
            holding = true
        }
    } else {
        // Heat Protection with a 5 min hold, as in AlDente
        // An adapter we turned off is still wall power: otherwise a pause via adapter-off would cancel itself
        let plugged = b.onAC || (!adapterOn && !AdapterCut.chargerGone(BatteryReader.powerPorts()))
        heat.update(enabled: cfg.heatProtection, temperature: b.temperature, max: cfg.heatMax, macPercent: b.macPercent, plugged: plugged)

        limitRaise.update(limit: cfg.limit, shown: shown)
        if toFull {
            holding = b.fullyCharged || b.percent >= 100
        } else if firmwareLimit {
            // Between the limits charging holds until the firmware starts charging on its own: the Mac may have shut down and woken mid-range
            holding = shown >= cfg.limit || (shown > lower && !b.isCharging)
        } else {
            if shown >= cfg.limit { holding = true }
            if shown <= lower { holding = false }
        }
        if limitRaise.active { holding = false }
        if toFull || shown <= cfg.limit { draining = false } else if shown > cfg.limit + 1 { draining = true }
        let overLimit = firmwareLimit ? draining : !toFull && shown > cfg.limit + 1
        // Turning the adapter off also cuts a monitor or dock on the same cable: then we only stop charging and let use drain it
        let wantsDrain = overLimit && cfg.discharge && canCutAdapter
        let ports = wantsDrain ? BatteryReader.powerPorts() : []
        let dropsDevices = wantsDrain && AdapterCut.wouldDropDevices(ports)
        if dropsDevices { wallSince = nil }
        let wallFor = wallSince.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let willDrain = wantsDrain && AdapterCut.allowed(ports, adapterOn: adapterOn, onAC: b.onAC, wallFor: wallFor)
        if dropsDevices != cutBlockedLogged {
            cutBlockedLogged = dropsDevices
            log(dropsDevices ? "adapter stays on: a monitor or dock shares it" : "adapter can be cut again")
        }

        if firmwareLimit && !toFull {
            // The firmware counts in the macOS percentage, so convert using the current ratio
            let toFirmware = { (v: Int) in min(100, Int((Double(v) * Double(b.macPercent) / Double(max(1, shown))).rounded())) }
            // While charging, the upper limit is a bit higher and we stop as soon as the number reaches the limit. In sleep the firmware stops it, 1–2 % off
            hold.update(limit: cfg.limit, shown: shown, macPercent: b.macPercent, charging: b.isCharging, willDrain: willDrain)
            let upper = hold.upper ?? min(100, toFirmware(cfg.limit) + (scale == .macOS ? 0 : 1))
            target = (min(toFirmware(lower), upper - 1), upper)
            // While charging, rounding isn't worth rewriting the keys: the check above will stop it. But a limit not above the charge won't let it charge
            if hold.upper == nil, scale != .macOS, let cur = firmwareTarget, abs(cur.upper - upper) <= 1, willDrain || cur.upper > b.macPercent { target = cur }
            // Between the limits the firmware won't start charging on its own: raise the lower limit above the charge
            if limitRaise.active, let t = target { target = (max(t.lower, t.upper - 1), t.upper) }
        } else { hold.reset() }

        if let at = heat.stopAt {
            st.mode = .heat
            stop = true
            // Heat: stop charging at the level where protection tripped; the adapter keeps powering the Mac
            target = (max(10, at - 20), at)
        } else if holding {
            stop = true
            if willDrain {
                drain = true
                st.mode = .discharging
            } else {
                st.mode = firmwareLimit && !b.onAC ? .off : .holding
                if dropsDevices && b.onAC {
                    st.note = "Not charging — \(shown)% is above the \(cfg.limit)% limit. A monitor or dock shares this cable, so the plug stays on. Use it down; charging resumes at \(lower)%."
                }
            }
        } else {
            st.mode = b.onAC ? .charging : .off
        }
    }

    setFirmwareTarget(target)

    // Levers: with charge inhibit, hold with it; turn the adapter off only to drain.
    // With only adapter-off, hold with that (the Mac runs on battery down to the Sailing point).
    let wantCharge: Bool, wantAdapter: Bool
    if canInhibit {
        wantCharge = !stop
        wantAdapter = !drain
    } else {
        wantCharge = true
        wantAdapter = !stop
    }

    if wantCharge != chargingOn { setCharging(wantCharge); chargingOn = wantCharge; log("charging \(wantCharge)") }
    if wantAdapter != adapterOn { setAdapter(wantAdapter); adapterOn = wantAdapter; log("adapter \(wantAdapter)") }
    enforce()

    // MagSafe LED: green — holding the limit, orange — charging up to the limit
    var led: UInt8 = 0
    if cfg.enabled && cfg.magsafeLED && b.onAC {
        led = (st.mode == .holding || st.mode == .discharging) ? 3 : (st.mode == .heat ? 4 : (b.isCharging ? 4 : 0))
    }
    if led != ledValue { setLED(led); ledValue = led }

    // Don't sleep while charging up to the limit, otherwise the Mac tops up to 100 % in sleep
    // (the firmware limit works in sleep too, so it's not needed there)
    preventSleep(!firmwareLimit && cfg.enabled && cfg.sleepUntilLimit && b.onAC && !holding && shown < cfg.limit)

    st.adapterPaused = !adapterOn
    st.chargingPaused = !chargingOn
    st.wallHold = st.mode == .holding && adapterOn && b.onAC && !b.isCharging && !b.drainingOnAC
    writeStatus(st)
}

log("start · firmware limit=\(firmwareLimit) CHTE=\(hasCHTE) CH0B/C=\(hasCH0B) CHIE=\(hasCHIE) CH0I=\(hasCH0I) LED=\(hasLED)")
tick()
BatteryReader.observe { tick() }
// Requests from the app (Top Up, Low Power) are picked up right away, without waiting for a tick. No polling, so the helper isn't woken for nothing.
var lastConfigStamp: Date?
func checkConfig() {
    let m = (try? fm.attributesOfItem(atPath: ChargePaths.config))?[.modificationDate] as? Date
    if m != lastConfigStamp { lastConfigStamp = m; tick() }
}
let configWatcher = FolderWatcher(path: ChargePaths.dir, onChange: checkConfig)
if configWatcher == nil {
    log("can't watch \(ChargePaths.dir), checking the config every 2 s")
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in checkConfig() }
}
// The app also wakes us with a notification after each write — independent of whether the folder delivered an event.
// Repeats are cheap: tick only when the file actually changed.
var configNotifyToken: Int32 = 0
if notify_register_dispatch(ChargePaths.configChanged, &configNotifyToken, .main, { _ in checkConfig() }) != NOTIFY_STATUS_OK {
    log("can't listen for \(ChargePaths.configChanged)")
}

// App update: a non-root process writes the request, so UpdateInstall verifies everything itself (signature with the compiled-in key, sha256, bundle, version, path).
// Separate queue: hdiutil and copying take seconds, and the charge limit must keep working meanwhile.
let updateQueue = DispatchQueue(label: "com.mansfera.lynxbattery.update")
var updateBusy = false
func checkUpdateRequest() {
    guard !updateBusy, fm.fileExists(atPath: ChargePaths.dir + "/" + UpdateInstall.requestName) else { return }
    updateBusy = true
    updateQueue.async {
        UpdateInstall.handleRequest(dir: ChargePaths.dir, workRoot: NSTemporaryDirectory(), trusted: UpdateKey.trusted,
                                    allowedParent: UpdateInstall.helperAllowedParent, log: { s in log(s) })
        DispatchQueue.main.async { updateBusy = false; checkUpdateRequest() }
    }
}
var updateNotifyToken: Int32 = 0
if notify_register_dispatch(ChargePaths.updateRequested, &updateNotifyToken, .main, { _ in checkUpdateRequest() }) != NOTIFY_STATUS_OK {
    log("can't listen for \(ChargePaths.updateRequested)")
}
checkUpdateRequest()
RunLoop.main.run()
