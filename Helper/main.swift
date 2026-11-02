import Foundation
import IOKit.pwr_mgt

// Root-хелпер Lynx Battery. Тримає ліміт заряду, Sailing, Heat Protection, Top Up, LED MagSafe.
//
// Важелі залежать від прошивки:
//  • межа в прошивці — bfF0, bfD0, bfE0 (прошивки 20xxx): заряд зупиняє сама прошивка, адаптер живить Mac, і так само уві сні;
//  • заборона заряду — CHTE або CH0B+CH0C: адаптер живить Mac, батарея стоїть;
//  • вимкнення адаптера — CH0I: Mac живе від батареї (розряд до ліміту).
//  • CHIE на різних прошивках поводиться по-різному (на macOS 27 / цьому Mac — як заборона заряду),
//    тож при першому використанні хелпер дивиться, що саме сталося, і запам'ятовує роль ключа.
// На виході, при вимкненні ліміту й при заряді ≤ 10 % — завжди повертає звичайну зарядку.

setvbuf(stdout, nil, _IOLBF, 0)
let smc = SMC.shared
let fm = FileManager.default

let hasCHTE = smc.info("CHTE") != nil
let hasCH0B = smc.info("CH0B") != nil && smc.info("CH0C") != nil
let hasCHIE = smc.info("CHIE") != nil
let hasCH0I = smc.info("CH0I") != nil
let hasLED = smc.info("ACLC") != nil

/// Межа в прошивці є, поки прошивка приймає записи. Деякі збірки 20xxx відхиляють їх навіть від root — тоді стара схема.
var firmwareLimit = smc.info("bfF0") != nil && smc.info("bfD0") != nil && smc.info("bfE0") != nil
/// Яку межу маємо тримати в прошивці; nil — вимкнена.
var firmwareTarget: (lower: Int, upper: Int)?

enum Role: String { case unknown, inhibit, adapter, none }
/// Роль CHIE, яку визначає самотест. З межею в прошивці CHIE лише вимикає адаптер для розряду, як описано в batt, тож без самотесту.
var chieRole: Role = !hasCHIE ? .none : (firmwareLimit ? .adapter : .unknown)
var chieTestStart: Date?

var canInhibit: Bool { firmwareLimit || hasCHTE || hasCH0B || chieRole == .inhibit || chieRole == .unknown }
var canCutAdapter: Bool { hasCH0I || chieRole == .adapter }

func log(_ s: String) { print("[\(Date())] \(s)") }

func writeCHIE(_ on: Bool) { smc.write("CHIE", [on ? 0x00 : 0x08]) }

/// Відсотки в ключах межі — ui32 у little-endian: 80 % — це 50 00 00 00.
func le32(_ v: Int) -> [UInt8] { [UInt8(v), 0, 0, 0] }

func firmwareLimitIs(lower: Int, upper: Int) -> Bool {
    smc.readBytes("bfF0") == [2] && smc.readBytes("bfD0") == le32(upper) && smc.readBytes("bfE0") == le32(lower)
}

/// Порядок записів вимагає прошивка: вимкнути, верхня межа, нижня, увімкнути. Пишемо лише те, що змінилось.
func applyFirmwareLimit(lower: Int, upper: Int) -> Bool {
    if firmwareLimitIs(lower: lower, upper: upper) { return true }
    guard smc.write("bfF0", [0]), smc.write("bfD0", le32(upper)), smc.write("bfE0", le32(lower)), smc.write("bfF0", [2]) else { return false }
    return firmwareLimitIs(lower: lower, upper: upper)
}

func disableFirmwareLimit() { if smc.readBytes("bfF0") != [0] { smc.write("bfF0", [0]) } }

/// Прошивка не прийняла межу: далі старі важелі й самотест CHIE, як на Mac без цих ключів.
func dropFirmwareLimit() {
    firmwareLimit = false
    firmwareTarget = nil
    if hasCHIE { chieRole = .unknown }
    log("firmware limit refused, using the older levers")
}

/// Тримає в прошивці потрібну межу; nil — вимикає, щоб заряд ішов як зазвичай.
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

/// Пауза заряду (адаптер і далі живить Mac).
func setCharging(_ on: Bool) {
    if firmwareLimit { return }   // заряд зупиняє сама прошивка
    if hasCHTE { smc.write("CHTE", on ? [0, 0, 0, 0] : [1, 0, 0, 0]) }
    else if hasCH0B { smc.write("CH0B", [on ? 0 : 2]); smc.write("CH0C", [on ? 0 : 2]) }
    else if chieRole == .inhibit || chieRole == .unknown {
        writeCHIE(on)
        if !on && chieRole == .unknown && chieTestStart == nil { chieTestStart = Date() }
    }
}

/// Вимкнення адаптера (Mac працює від батареї).
func setAdapter(_ on: Bool) {
    if hasCH0I { smc.write("CH0I", [on ? 0 : 1]) }
    else if chieRole == .adapter { writeCHIE(on) }
}

/// ACLC: 0 — керує система, 3 — зелений, 4 — помаранчевий.
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
// Старт із чистого стану: після краху чи оновлення ніщо не лишається на паузі
restoreAll()

// MARK: - Стан

var chargingOn = true
var adapterOn = true
var ledValue: UInt8 = 0
var holding = false           // досягли ліміту й чекаємо, поки спуститься до limit − sailRange
var draining = false          // розряджаємо до межі; вмикається з запасом, щоб округлення 72↔73 не смикало адаптер
var holdUpper: Int?           // на якому значенні прошивки (її відсоток — як у macOS) зупинились, коли число дійшло до ліміту
var heatSince: Date?
var sleepAssertion: IOPMAssertionID = 0
var lastLowPowerRequest: Date?

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
    guard Date().timeIntervalSince(at) < 60 else { return }   // старі запити не виконуємо
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-a", "lowpowermode", cfg.lowPower ? "1" : "0"]
    try? p.run(); p.waitUntilExit()
    log("low power \(cfg.lowPower)")
}

/// Через 20 с після першої паузи через CHIE дивимось, що сталося, і фіксуємо роль ключа.
func classifyCHIE(_ b: BatterySnapshot) {
    guard chieRole == .unknown, let t = chieTestStart, Date().timeIntervalSince(t) > 20 else { return }
    // Якщо за цей час macOS скинула ключ, вимір нічого не означає — пробуємо ще раз
    if smc.readBytes("CHIE") != [0x08] { writeCHIE(false); chieTestStart = Date(); log("CHIE was reset during the test, retrying"); return }
    if !b.onAC || b.watts < -0.3 { chieRole = .adapter }          // Mac перейшов на батарею
    else if !b.isCharging { chieRole = .inhibit }                 // адаптер є, але заряд стоїть
    else { chieRole = .none; writeCHIE(true); chargingOn = true }  // нічого не змінилось — відкат
    log("CHIE role: \(chieRole.rawValue)")
    if chieRole == .adapter {
        // Ми ставили «паузу заряду», а ключ насправді вимикає адаптер — далі працюємо як з адаптером
        chargingOn = true; adapterOn = false
    }
}

/// macOS (своє керування зарядом) скидає ключі назад, тож щоразу читаємо їх і, якщо треба, пишемо знову.
var reasserts = 0
func enforce() {
    func check(_ key: String, _ want: [UInt8]) {
        guard let now = smc.readBytes(key), now != want else { return }
        smc.write(key, want)
        reasserts += 1
        if reasserts <= 20 || reasserts % 50 == 0 { log("re-asserted \(key) (was \(now.map { String(format: "%02x", $0) }.joined()), #\(reasserts))") }
    }
    if firmwareLimit {
        // Межу в прошивці теж може скинути macOS чи інша програма
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

// MARK: - Рішення

func tick() {
    var cfg = loadConfig()
    applyLowPower(cfg)
    guard let b = BatteryReader.read() else { return }
    classifyCHIE(b)

    // Ліміт тримаємо в тому відсотку, який бачить користувач; безпека (≤ 10 %) і Top Up — за справжнім зарядом
    let scale = cfg.scale ?? .trueCharge
    let shown = scale.percent(b)
    let toFull = cfg.limit >= scale.top(b)

    var st = ChargeStatus(percent: shown, temperature: b.temperature)
    st.capabilities = (canInhibit && chieRole != .unknown || hasCHTE || hasCH0B ? ["charge-inhibit"] : [])
        + (canCutAdapter ? ["adapter"] : []) + (hasLED ? ["led"] : []) + (firmwareLimit ? ["firmware-limit"] : [])

    // Що хочемо: stop — не заряджати; drain — ще й вимкнути адаптер, щоб спуститись до ліміту
    var stop = false, drain = false
    let lower = cfg.sailing ? cfg.limit - cfg.sailRange : cfg.limit - 1
    // Межа для прошивки; nil — вимкнена, тобто заряд іде як зазвичай (ліміт вимкнено, Top Up, ≤ 10 %)
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
        // Heat Protection з витримкою 5 хв, як в AlDente
        if cfg.heatProtection, let t = b.temperature {
            if t >= cfg.heatMax, heatSince == nil { heatSince = Date() }
            if let s = heatSince, t < cfg.heatMax - 1, Date().timeIntervalSince(s) > 300 { heatSince = nil }
        } else { heatSince = nil }

        if toFull {
            holding = b.fullyCharged || b.percent >= 100
        } else if firmwareLimit {
            // Між межами заряд стоїть, доки прошивка не почала заряджати сама: Mac міг вимкнутись і прокинутись посеред діапазону
            holding = shown >= cfg.limit || (shown > lower && !b.isCharging)
        } else {
            if shown >= cfg.limit { holding = true }
            if shown <= lower { holding = false }
        }
        if toFull || shown <= cfg.limit { draining = false } else if shown > cfg.limit + 1 { draining = true }
        let overLimit = firmwareLimit ? draining : !toFull && shown > cfg.limit + 1
        let willDrain = overLimit && cfg.discharge && canCutAdapter

        if firmwareLimit && !toFull {
            // Прошивка рахує у відсотку macOS, тож переводимо за поточним співвідношенням
            let toFirmware = { (v: Int) in min(100, Int((Double(v) * Double(b.macPercent) / Double(max(1, shown))).rounded())) }
            // Поки заряджається, верхня межа трохи вище, а зупиняємо, щойно число дійшло до ліміту. Уві сні зупинить сама прошивка, на 1–2 % неточно
            if b.isCharging && shown < cfg.limit { holdUpper = nil }
            else if shown >= cfg.limit && !willDrain { holdUpper = b.macPercent }
            if willDrain { holdUpper = nil }
            let upper = holdUpper ?? min(100, toFirmware(cfg.limit) + (scale == .macOS ? 0 : 1))
            target = (min(toFirmware(lower), upper - 1), upper)
            // Поки заряджається, округлення не варте перезапису ключів: зупинить перевірка вище
            if holdUpper == nil, scale != .macOS, let cur = firmwareTarget, abs(cur.upper - upper) <= 1 { target = cur }
        } else { holdUpper = nil }

        if heatSince != nil && b.onAC {
            st.mode = .heat
            stop = true
            // Спека: зупиняємо заряд на поточному рівні, адаптер і далі живить Mac
            target = (max(10, b.macPercent - 20), b.macPercent)
        } else if holding {
            stop = true
            if willDrain {
                drain = true
                st.mode = .discharging
            } else {
                st.mode = firmwareLimit && !b.onAC ? .off : .holding
            }
        } else {
            st.mode = b.onAC ? .charging : .off
        }
    }

    setFirmwareTarget(target)

    // Важелі: є заборона заряду — нею тримаємо; адаптер вимикаємо лише для розряду.
    // Є тільки вимкнення адаптера — ним і тримаємо (Mac живе від батареї до точки Sailing).
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

    // LED MagSafe: зелений — тримаємо ліміт, помаранчевий — заряджає до ліміту
    var led: UInt8 = 0
    if cfg.enabled && cfg.magsafeLED && b.onAC {
        led = (st.mode == .holding || st.mode == .discharging) ? 3 : (st.mode == .heat ? 4 : (b.isCharging ? 4 : 0))
    }
    if led != ledValue { setLED(led); ledValue = led }

    // Не спати, поки заряджаємо до ліміту, інакше в сні Mac дозарядиться до 100 %
    // (межа в прошивці діє й уві сні, тож там не потрібно)
    preventSleep(!firmwareLimit && cfg.enabled && cfg.sleepUntilLimit && b.onAC && !holding && shown < cfg.limit)

    st.adapterPaused = !adapterOn
    st.chargingPaused = !chargingOn
    st.wallHold = st.mode == .holding && adapterOn && b.onAC && !b.isCharging && !b.drainingOnAC
    writeStatus(st)
}

log("start · firmware limit=\(firmwareLimit) CHTE=\(hasCHTE) CH0B/C=\(hasCH0B) CHIE=\(hasCHIE) CH0I=\(hasCH0I) LED=\(hasLED)")
tick()
BatteryReader.observe { tick() }
Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in tick() }
// Запити з апки (Top Up, енергозбереження) — підхоплюємо за 2 с, не чекаючи 15
var lastConfigStamp: Date?
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    let m = (try? fm.attributesOfItem(atPath: ChargePaths.config))?[.modificationDate] as? Date
    if m != lastConfigStamp { lastConfigStamp = m; tick() }
}
// Поки щось на паузі — перевіряємо ключі кожні 3 с, щоб macOS не встигала дозарядити
Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
    if !chargingOn || !adapterOn { enforce() }
}
RunLoop.main.run()
