import Foundation

// High thresholds in all percentage modes. Pure logic only: no Settings, no files and no helper.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}

/// Health 88 %: designTop stays 88 in all modes, only percentTop differs.
func snap(_ percent: Int, top: Int, full: Bool = false, ac: Bool = true) -> BatterySnapshot {
    BatterySnapshot(percent: percent, isCharging: false, onAC: ac, fullyCharged: full, minutes: nil, watts: 0,
                    adapterWatts: nil, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: 880,
                    temperature: nil, systemWatts: 0, inputWatts: 0, lowPower: false,
                    designTop: 88, percentTop: top)
}
let none: Int? = nil

// Of original capacity: the number tops out at 88
do {
    var h = HighAlertTracker()
    let all: Set<Int> = [80, 95, 100]
    check("no alert below the thresholds", h.update(all, snap(70, top: 88)), none)
    check("a reachable threshold fires as usual", h.update(all, snap(80, top: 88)), 80)
    check("the top without the full flag isn't full", h.update(all, snap(88, top: 88)), none)
    let full = snap(88, top: 88, full: true)
    check("100 fires on a really full battery", h.update(all, full), 100)
    check("the title says fully charged", HighAlertTracker.title(100, full), "Fully charged")
    check("no repeat on the next refresh", h.update(all, full), none)
    check("no repeat on the refresh after that", h.update(all, full), none)
    _ = h.update(all, snap(87, top: 88, ac: false))
    _ = h.update(all, snap(86, top: 88, ac: false))
    check("no repeat after a small sag and a replug", h.update(all, full), none)
    _ = h.update(all, snap(85, top: 88, ac: false))
    check("fires again after a real drop", h.update(all, full), 100)
}
do {
    var h = HighAlertTracker()
    let full = snap(88, top: 88, full: true)
    check("a threshold above the top fires when full", h.update([95], full), 95)
    check("and is titled fully charged", HighAlertTracker.title(95, full), "Fully charged")
    check("and doesn't repeat", h.update([95], full), none)
    var at = HighAlertTracker()
    check("a threshold at the top needs no full flag", at.update([88], snap(88, top: 88)), 88)
    check("and keeps its number in the title", HighAlertTracker.title(88, snap(88, top: 88)), "Charged to 88%")
    var off = HighAlertTracker()
    check("nothing fires on battery", off.update([100], snap(88, top: 88, full: true, ac: false)), none)
    check("then it fires once plugged in", off.update([100], full), 100)
    var started = HighAlertTracker()
    started.start([100], full)
    check("launching on a full battery stays quiet", started.update([100], full), none)
}

// True charge and macOS: ceiling 100, even though designTop is 88
do {
    var h = HighAlertTracker()
    check("true: 90 is not 95", h.update([95, 100], snap(90, top: 100)), none)
    check("true: 95 fires at 95", h.update([95, 100], snap(95, top: 100)), 95)
    check("true: title keeps the number", HighAlertTracker.title(95, snap(95, top: 100)), "Charged to 95%")
    check("true: 100 fires at 100", h.update([95, 100], snap(100, top: 100, full: true)), 100)
    _ = h.update([95, 100], snap(98, top: 100))
    check("true: 98 doesn't re-arm 100", h.fired.contains(100), true)
    _ = h.update([95, 100], snap(97, top: 100))
    check("true: 97 re-arms 100", h.fired.contains(100), false)
    var mac = HighAlertTracker()
    check("macOS: the full flag at 99 doesn't fire 100", mac.update([100], snap(99, top: 100, full: true)), none)
    check("macOS: 100 fires at 100", mac.update([100], snap(100, top: 100)), 100)
}

// Mode switch: AlertEngine calls start again, because the number jumped while the charge stayed the same
do {
    var h = HighAlertTracker()
    _ = h.update([90], snap(80, top: 88))
    h.start([90], snap(91, top: 100))
    check("design to true past a threshold stays quiet", h.update([90], snap(91, top: 100)), none)
    check("and it stays quiet while charging on", h.update([90], snap(95, top: 100)), none)
    var back = HighAlertTracker()
    back.start([90], snap(84, top: 88))
    check("true to design drops below it, still quiet", back.update([90], snap(84, top: 88)), none)
    check("then it fires when really full", back.update([90], snap(88, top: 88, full: true)), 90)
    var full = HighAlertTracker()
    full.start([100], snap(100, top: 100, full: true))
    full.start([100], snap(88, top: 88, full: true))
    check("switching on a full battery stays quiet", full.update([100], snap(88, top: 88, full: true)), none)
}

// Status line on the adapter
check("status: at the top in design mode", snap(88, top: 88).statusLine, "Charged · on power adapter")
check("status: below the top in design mode", snap(80, top: 88).statusLine, "On adapter · not charging")
check("status: 88 in true mode isn't charged", snap(88, top: 100).statusLine, "On adapter · not charging")
check("status: 100 in true mode", snap(100, top: 100).statusLine, "Charged · on power adapter")
check("status: full flag in macOS mode", snap(99, top: 100, full: true).statusLine, "Charged · on power adapter")

func charging(_ percent: Int, top: Int, minutes: Int?, watts: Int? = 67) -> BatterySnapshot {
    BatterySnapshot(percent: percent, isCharging: true, onAC: true, fullyCharged: false, minutes: minutes, watts: 20,
                    adapterWatts: watts, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: 880,
                    temperature: nil, systemWatts: 0, inputWatts: 0, lowPower: false,
                    designTop: 88, percentTop: top)
}
check("status: charging to full", charging(70, top: 100, minutes: 70).statusLine,
      "Charging · 67 W · full in 1 h 10 min")
check("status: charging to a limit", charging(68, top: 100, minutes: 40).statusLine(target: 80),
      "Charging · 67 W · 15 min to 80% · 40 min to full")
check("status: charging to a limit, no ETA", charging(68, top: 100, minutes: nil).statusLine(target: 80),
      "Charging · 67 W")
check("status: charging to design top is full", charging(70, top: 88, minutes: 30).statusLine(target: 88),
      "Charging · 67 W · full in 30 min")
check("status: at the limit still charging", charging(80, top: 100, minutes: 20).statusLine(target: 80),
      "Charging · 67 W · 20 min to full")

// Weak adapter: PD negotiates in steps, so the first samples after plugging in aren't a verdict yet
func draining(adapter: Int?, system: Double = 30, ac: Bool = true) -> BatterySnapshot {
    BatterySnapshot(percent: 50, isCharging: false, onAC: ac, fullyCharged: false, minutes: nil, watts: -8,
                    adapterWatts: adapter, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: 880,
                    temperature: nil, systemWatts: system, inputWatts: 0, lowPower: false)
}
do {
    let t0 = Date()
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    var w = WeakChargerTracker()
    check("weak: a 5 W first step isn't weak yet", w.update(draining(adapter: 5), now: at(0)), false)
    check("weak: a 15 W step a moment later isn't either", w.update(draining(adapter: 15), now: at(3)), false)
    check("weak: the full 96 W clears it", w.update(draining(adapter: 96), now: at(6)), false)
    check("weak: and the timer is gone", w.since == nil, true)
    check("weak: still fine long after", w.update(draining(adapter: 96), now: at(60)), false)

    var slow = WeakChargerTracker()
    check("weak: unknown watts on plug-in waits", slow.update(draining(adapter: nil), now: at(0)), false)
    check("weak: still waiting before the settle time", slow.update(draining(adapter: 30), now: at(WeakChargerTracker.settle - 1)), false)
    check("weak: a charger that stays weak is weak", slow.update(draining(adapter: 30), now: at(WeakChargerTracker.settle)), true)
    check("weak: and stays weak", slow.update(draining(adapter: 30), now: at(90)), true)
    check("weak: unplugging resets it", slow.update(draining(adapter: nil, ac: false), now: at(91)), false)
    check("weak: replugging waits again", slow.update(draining(adapter: 30), now: at(92)), false)
}
check("status: a settling charger isn't called weak", draining(adapter: 5).statusLine, "Plugged in, using battery")
var settled = draining(adapter: 30)
settled.chargerTooWeak = true
check("status: a settled weak charger is", settled.statusLine, "Plugged in, still draining")

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
