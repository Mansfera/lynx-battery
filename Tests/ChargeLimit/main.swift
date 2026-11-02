import Foundation

// Межі ліміту заряду й переведення між шкалами. Лише чиста логіка: файл налаштувань і хелпер не чіпає.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(got), want \(want)")")
}

func snap(_ percent: Int, health: Int) -> BatterySnapshot {
    BatterySnapshot(percent: percent, isCharging: false, onAC: true, fullyCharged: false, minutes: nil, watts: 0,
                    adapterWatts: nil, cycles: 0, designCycles: 1000, designCapacity: 1000, fullCapacity: health * 10,
                    temperature: nil, systemWatts: 0, inputWatts: 0, lowPower: false,
                    designTop: health, percentTop: 100)
}

let b = snap(80, health: 89)

check("top: true charge", ChargeScale.trueCharge.top(b), 100)
check("top: original capacity is the health", ChargeScale.ofDesign.top(b), 89)
check("lowest: true charge", ChargeScale.trueCharge.lowest(b), 15)
check("lowest: original capacity", ChargeScale.ofDesign.lowest(b), 13)
check("lowest on a very worn battery", ChargeScale.ofDesign.lowest(snap(5, health: 10)), 2)

check("original 72 is true 81", ChargeScale.ofDesign.convert(72, to: .trueCharge, b), 81)
check("true 81 is original 72", ChargeScale.trueCharge.convert(81, to: .ofDesign, b), 72)

var c = ChargeConfig()
c.limit = 15; c.sailRange = 20
check("sail floor never drops below the safety level", c.sailFloor, 10)
c.limit = 80; c.sailRange = 5
check("sail floor is limit minus range", c.sailFloor, 75)
c.limit = 3
check("sanitized raises a limit under 10", c.sanitized().limit, 10)
c.limit = 15
check("sanitized keeps 15", c.sanitized().limit, 15)
c.limit = 140
check("sanitized caps at 100", c.sanitized().limit, 100)

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
