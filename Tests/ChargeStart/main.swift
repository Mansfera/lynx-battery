import Foundation

// Початок заряду. Лише чиста логіка: файл налаштувань і хелпер не чіпає.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(String(describing: got)), want \(String(describing: want))")")
}

var h = FirmwareHold()
h.update(limit: 90, shown: 90, macPercent: 91, charging: false, willDrain: false)
check("reaching the limit holds at the firmware's number", h.upper, 91)

// Так і лишалось на реальному Mac: межа 90–91 при ліміті 99, заряд не починався зовсім
h.update(limit: 99, shown: 90, macPercent: 91, charging: false, willDrain: false)
check("raising the limit while holding drops the old upper bound", h.upper, nil)
h.update(limit: 99, shown: 90, macPercent: 91, charging: false, willDrain: false)
check("and it stays dropped before charging is seen", h.upper, nil)

h = FirmwareHold()
h.update(limit: 90, shown: 90, macPercent: 91, charging: false, willDrain: false)
h.update(limit: 90, shown: 88, macPercent: 89, charging: false, willDrain: false)
check("sailing below the same limit keeps the hold", h.upper, 91)
h.update(limit: 90, shown: 85, macPercent: 86, charging: true, willDrain: false)
check("charging again below the limit ends the hold", h.upper, nil)

h = FirmwareHold()
h.update(limit: 90, shown: 90, macPercent: 91, charging: false, willDrain: false)
h.update(limit: 85, shown: 90, macPercent: 91, charging: false, willDrain: false)
check("lowering the limit without a drain holds at the current number", h.upper, 91)
h.update(limit: 85, shown: 90, macPercent: 91, charging: false, willDrain: true)
check("draining releases the hold", h.upper, nil)

h = FirmwareHold()
h.update(limit: 90, shown: 90, macPercent: 91, charging: false, willDrain: false)
h.reset()
check("reset clears the hold", h.upper, nil)

let starting = BatteryReader.liveCharge(current: 1740, amperage: -249)
check("live current wins over a stale drain: charging", starting.charging, true)
check("live current wins over a stale drain: current", starting.mA, 1740)
let stopped = BatteryReader.liveCharge(current: 0, amperage: 1747)
check("no live current wins over a stale charge: charging", stopped.charging, false)
check("no live current wins over a stale charge: current", stopped.mA, 0)
let draining = BatteryReader.liveCharge(current: 0, amperage: -600)
check("a real drain stays a drain: charging", draining.charging, false)
check("a real drain stays a drain: current", draining.mA, -600)

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
