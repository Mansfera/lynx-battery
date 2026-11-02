import Foundation

// Неможливі показники POWER. Історія лише у тимчасовому файлі: справжню energy.json не чіпає.

var failures = 0
func check<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : ": got \(String(describing: got)), want \(String(describing: want))")")
}
func rounded(_ v: Double?) -> Double? { v.map { ($0 * 100).rounded() / 100 } }

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
var fileCount = 0

/// Монітор із файлу в тому самому форматі, що й справжній: секунди від 2001-го. hoursAgo — щоб години не випали за 30 днів.
func monitor(_ hours: [(hoursAgo: Double, totals: [String: Double], n: Int)]) -> (EnergyMonitor, URL) {
    fileCount += 1
    let url = dir.appendingPathComponent("energy-\(fileCount).json")
    let rows: [[String: Any]] = hours.map {
        ["t": Date().addingTimeInterval(-$0.hoursAgo * 3600).timeIntervalSinceReferenceDate, "totals": $0.totals, "n": $0.n]
    }
    try! JSONSerialization.data(withJSONObject: rows).write(to: url)
    return (EnergyMonitor(url: url), url)
}
/// pid −1 не має шляху, тож апкою стає сама назва процесу.
func reading(_ cmd: String, _ power: Double) -> (pid: Int32, cmd: String, power: Double) { (-1, cmd, power) }

// Те, що лежало на справжньому Mac: година з 228990593.5 поруч із нормальними
let realHours: [(hoursAgo: Double, totals: [String: Double], n: Int)] = [
    (5, ["macOS": 3835.3], 30),
    (4, ["macOS": 228990593.5, "Safari": 120], 12),
    (3, ["macOS": 346.5], 1),
]

do {
    let (m, _) = monitor(realHours)
    let avg = m.averages(.month)
    check("the corrupt hour leaves the average", rounded(avg["macOS"]), 97.25)
    check("the same hour's honest app still counts", rounded(avg["Safari"]), 2.79)
    let top = m.top(.month)
    check("top ranks the real order", top.map(\.name), ["macOS", "Safari"])
    check("the corrupt hour leaves the shares", rounded(top.first?.share), 0.97)
}

do {
    let (m, url) = monitor(realHours)
    m.save()
    let again = EnergyMonitor(url: url)
    check("saving writes the healed history", rounded(again.averages(.month)["macOS"]), 97.25)
    let text = String(decoding: try! Data(contentsOf: url), as: UTF8.self)
    check("the corrupt value is gone from the file", text.contains("228990593"), false)
    check("the honest value stays in the file", text.contains("Safari"), true)
}

do {
    let (m, _) = monitor([(3, ["Render": 8000], 1), (2, ["Render": 10_000], 1)])
    check("high saved hours still count", m.averages(.month)["Render"], 9000)
    let (over, _) = monitor([(1, ["Bad": 10_000.5], 1)])
    check("a saved hour over the ceiling is dropped", over.averages(.month)["Bad"], nil)
}

do {
    let (m, _) = monitor([(2, ["Long": 150_000], 30), (1, ["Negative": -5], 3)])
    let avg = m.averages(.month)
    check("the ceiling is per sample, not per hour", rounded(avg["Long"]), 4545.45)
    check("a negative total is dropped", avg["Negative"], nil)
}

do {
    let (m, _) = monitor([])
    m.ingest([reading("Render", 9500), reading("Edge", EnergyMonitor.maxPower), reading("Busy", 346.5)])
    check("high live readings still count", m.apps.map(\.name), ["Edge", "Render", "Busy"])
    check("high live readings keep their value", m.apps.map(\.impact), [10_000, 9500, 346.5])

    let (bad, _) = monitor([])
    bad.ingest([reading("Spike", 228_990_593), reading("Over", 10_000.1), reading("Inf", .infinity), reading("Nan", .nan), reading("Neg", -1), reading("Fine", 12)])
    check("impossible readings never reach the apps", bad.apps.map(\.name), ["Fine"])
    check("impossible readings never reach the averages", bad.averages(.month), ["Fine": 12])
    check("or the sparkline", bad.apps.first?.history, [12])
}

do {
    let (m, _) = monitor([])
    m.ingest([reading("WindowServer", 41), reading("WindowServer", 228_990_593)])
    check("a bad process doesn't sink its app", m.apps.first?.impact, 41)
    check("and it stays out of the process list", m.apps.first?.processes.map(\.impact), [41])
}

do {
    // Із inf у сумах JSONEncoder падає, і save() мовчки не писав би нічого
    let (m, url) = monitor([])
    m.ingest([reading("Inf", .infinity), reading("Fine", 12)])
    m.save()
    let again = EnergyMonitor(url: url)
    check("an infinite reading can't break saving", again.averages(.month)["Fine"], 12)
}

do {
    // Зі зіпсованою годиною середнє було 715674, і «більше, ніж зазвичай» не спрацьовувало ніколи
    let (m, _) = monitor(realHours)
    for _ in 0..<5 { m.ingest([reading("macOS", 50)]) }
    m.ingest([reading("macOS", 1000)])
    check("a real spike is flagged as hot", m.apps.first?.hot, true)
    m.ingest([reading("macOS", 60)])
    check("a normal reading isn't", m.apps.first?.hot, false)
    m.ingest([reading("macOS", 60), reading("macOS", 228_990_593)])
    check("a corrupt reading isn't a spike either", m.apps.first?.hot, false)
    check("and the live value stays honest", m.apps.first?.impact, 60)
}

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
