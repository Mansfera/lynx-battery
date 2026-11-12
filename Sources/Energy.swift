import AppKit
import Darwin

struct AppEnergy: Identifiable {
    static let macOS = "macOS"          // системні процеси, згруповані в один рядок
    var id: String { name }
    var name: String
    var bundlePath: String?
    var impact: Double                 // сумарний Energy Impact процесів апки
    var processes: [(name: String, impact: Double)]
    var history: [Double]              // останні заміри для спарклайну
    var average: Double                // середнє за весь збережений період
    var hot: Bool { history.count >= 6 && impact > max(8, average * 2.2) }

    var icon: NSImage {
        if let p = bundlePath { return NSWorkspace.shared.icon(forFile: p) }
        return NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)!
    }
}

/// Енергія по апках: «top» дає Energy Impact процесу, ми групуємо хелпери в їхній .app.
final class EnergyMonitor {
    private struct Hour: Codable { var t: Date; var totals: [String: Double]; var n: Int }

    /// Стеля правдивого POWER із «top». У реальній історії найбільше за годину — 346.5 на замір (усі процеси macOS разом), а збій дав 19 млн на замір. 10 000 лишає запас у ~30 разів для потужніших Mac.
    static let maxPower = 10_000.0

    private(set) var apps: [AppEnergy] = []
    private var recent: [String: [Double]] = [:]
    private var hours: [Hour] = []
    private var paths: [String: String] = [:]
    private let url: URL
    private let queue = DispatchQueue(label: "sik.energy", qos: .utility)
    private var busy = false

    init(url: URL = AppData.dir.appendingPathComponent("energy.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let h = try? JSONDecoder().decode([Hour].self, from: d) { hours = Self.healed(h) }
    }

    /// Збій, що вже у файлі: сума не може бути більшою за стелю на кожен замір. Прибираємо лише цю апку в цю годину, бо решта рядків години чесні. Файл очиститься при наступному save().
    private static func healed(_ hours: [Hour]) -> [Hour] {
        hours.map { h in
            var h = h
            h.totals = h.totals.filter { $0.value >= 0 && $0.value <= maxPower * Double(max(h.n, 1)) }
            return h
        }
    }

    /// Коли востаннє закінчився замір, будь-який.
    private(set) var lastSample: Date?
    private var lastSave = Date()
    private var recordNext = false

    /// record — замір за розкладом, і лише він іде в історію: так години рівномірні в часі,
    /// а часті живі заміри при відкритому поповері не роздувають частку апок, що працюють саме тоді (і нашої теж).
    func sample(record: Bool, _ done: @escaping () -> Void) {
        if record { recordNext = true }
        guard !busy else { return }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let procs = Self.readTop()
            DispatchQueue.main.async {
                self.ingest(procs, record: self.recordNext)
                self.recordNext = false
                self.lastSample = Date()
                self.busy = false
                done()
            }
        }
    }

    func ingest(_ procs: [(pid: Int32, cmd: String, power: Double)], record: Bool = true) {
        var groups: [String: (impact: Double, path: String?, procs: [(String, Double)])] = [:]
        // Умова відсікає й nan та inf: Double() їх розбирає, а JSON зберегти вже не зможе.
        for p in procs where p.power > 0 && p.power <= Self.maxPower {
            let (app, path) = Self.owningApp(pid: p.pid, fallback: p.cmd)
            var g = groups[app] ?? (0, path, [])
            g.impact += p.power
            g.procs.append((p.cmd, p.power))
            groups[app] = g
        }
        for (name, g) in groups {
            recent[name, default: []].append(g.impact)
            if recent[name]!.count > 40 { recent[name]!.removeFirst() }
            if let p = g.path { paths[name] = p }
        }
        // Апки, що зникли з виводу, отримують 0 — інакше спарклайн бреше.
        for k in recent.keys where groups[k] == nil {
            recent[k]!.append(0)
            if recent[k]!.count > 40 { recent[k]!.removeFirst() }
            if recent[k]!.allSatisfy({ $0 == 0 }) { recent[k] = nil }
        }

        // Погодинні суми для 24 год / 7 / 30 днів
        if record {
            let hourStart = Calendar.current.dateInterval(of: .hour, for: Date())!.start
            if hours.last?.t != hourStart { hours.append(Hour(t: hourStart, totals: [:], n: 0)) }
            for (name, g) in groups { hours[hours.count - 1].totals[name, default: 0] += g.impact }
            hours[hours.count - 1].n += 1
            hours.removeAll { $0.t < Date().addingTimeInterval(-30 * 86_400) }
            // За часом, а не за числом замірів: у Eco їх лише 4 на годину
            if Date().timeIntervalSince(lastSave) >= 20 * 60 { save() }
        }

        let avg = averages(.month)
        apps = groups.map { name, g in
            AppEnergy(name: name, bundlePath: g.path, impact: g.impact,
                      processes: g.procs.sorted { $0.1 > $1.1 }.map { (name: $0.0, impact: $0.1) },
                      history: recent[name] ?? [], average: avg[name] ?? g.impact)
        }
        .sorted { $0.impact > $1.impact }
    }

    /// Середній Energy Impact кожної апки за проміжок (на замір).
    func averages(_ r: HistoryRange) -> [String: Double] {
        let cutoff = Date().addingTimeInterval(-r.seconds)
        var sum: [String: Double] = [:], n = 0
        for h in hours where h.t >= cutoff {
            n += h.n
            for (k, v) in h.totals { sum[k, default: 0] += v }
        }
        guard n > 0 else { return [:] }
        return sum.mapValues { $0 / Double(n) }
    }

    /// Топ апок за проміжок з часткою від загального.
    func top(_ r: HistoryRange, limit: Int = 8) -> [(name: String, share: Double, path: String?)] {
        let a = averages(r)
        let total = a.values.reduce(0, +)
        guard total > 0 else { return [] }
        return a.sorted { $0.value > $1.value }.prefix(limit).map { (name: $0.key, share: $0.value / total, path: paths[$0.key]) }
    }

    func save() {
        lastSave = Date()
        if let d = try? JSONEncoder().encode(hours) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: - Системне

    private static func readTop() -> [(pid: Int32, cmd: String, power: Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        p.arguments = ["-l", "2", "-n", "40", "-stats", "pid,command,power", "-o", "power", "-s", "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        // Перший замір top завжди нульовий — беремо лише рядки після другого заголовка.
        var headers = 0
        var out: [(Int32, String, Double)] = []
        for line in text.split(separator: "\n") {
            if line.hasPrefix("PID") { headers += 1; continue }
            guard headers == 2 else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let pw = Double(parts.last!) else { continue }
            let cmd = parts[1..<(parts.count - 1)].joined(separator: " ")
            if cmd == "top" || cmd == "kernel_task" { continue }
            out.append((pid, cmd, pw))
        }
        return out
    }

    private static func owningApp(pid: Int32, fallback: String) -> (String, String?) {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return (fallback, nil) }
        let path = String(cString: buf)
        // Найзовнішній .app у шляху: «Claude.app/…/Claude Helper.app/…» → Claude
        if let r = path.range(of: ".app/") {
            let appPath = String(path[..<r.lowerBound]) + ".app"
            let name = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (name, appPath)
        }
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/sbin/") { return (AppEnergy.macOS, "/System/Applications/System Settings.app") }
        return ((path as NSString).lastPathComponent, nil)
    }
}
