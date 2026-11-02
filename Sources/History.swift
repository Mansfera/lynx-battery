import Foundation

struct Sample: Codable, Identifiable {
    var t: Date
    var p: Int
    var c: Bool      // заряджалась
    var w: Double    // Вт
    var id: Date { t }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case day = "24H", week = "7D", month = "30D"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self { case .day: 86_400; case .week: 7 * 86_400; case .month: 30 * 86_400 }
    }
}

final class HistoryStore {
    private(set) var samples: [Sample] = []
    private let url: URL
    private var lastSaved = Date.distantPast

    init() {
        let dir = AppData.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let s = try? JSONDecoder().decode([Sample].self, from: data) { samples = s }
    }

    /// Пишемо точку раз на 5 хв або при зміні стану зарядки.
    func record(_ b: BatterySnapshot) {
        let now = Date()
        if let last = samples.last, now.timeIntervalSince(last.t) < 300, last.c == b.isCharging, abs(last.p - b.percent) < 2 { return }
        samples.append(Sample(t: now, p: b.percent, c: b.isCharging, w: b.watts))
        let cutoff = now.addingTimeInterval(-HistoryRange.month.seconds)
        samples.removeAll { $0.t < cutoff }
        if now.timeIntervalSince(lastSaved) > 600 { save() }
    }

    /// Для прев'ю/тестів — без збереження на диск.
    func appendForPreview(_ s: Sample) { samples.append(s) }

    func save() {
        lastSaved = Date()
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: url, options: .atomic) }
    }

    func range(_ r: HistoryRange) -> [Sample] {
        let cutoff = Date().addingTimeInterval(-r.seconds)
        let s = samples.filter { $0.t >= cutoff }
        // На 30 днів — проріджуємо, щоб графік не важчав.
        guard s.count > 400 else { return s }
        let step = s.count / 400 + 1
        return s.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    /// Стовпці для точкової матриці: середній рівень у кожному відрізку часу.
    func buckets(_ r: HistoryRange, count: Int) -> [(level: Int, charging: Bool)?] {
        let span = r.seconds / Double(count)
        let start = Date().addingTimeInterval(-r.seconds)
        var sums = [Double](repeating: 0, count: count), ns = [Int](repeating: 0, count: count), ch = [Int](repeating: 0, count: count)
        for x in samples where x.t >= start {
            let i = min(count - 1, Int(x.t.timeIntervalSince(start) / span))
            sums[i] += Double(x.p); ns[i] += 1; if x.c { ch[i] += 1 }
        }
        var out: [(level: Int, charging: Bool)?] = []
        for i in 0..<count {
            guard ns[i] > 0 else { out.append(nil); continue }
            let avg = sums[i] / Double(ns[i])
            out.append((level: Int(avg.rounded()), charging: ch[i] * 2 > ns[i]))
        }
        return out
    }

    /// Скільки відсотків за годину в середньому тратиться від батареї за проміжок.
    func drainPerHour(_ r: HistoryRange) -> Double? {
        let s = range(r)
        var drop = 0.0, time = 0.0
        for (a, b) in zip(s, s.dropFirst()) where !a.c && !b.c && b.p <= a.p {
            let dt = b.t.timeIntervalSince(a.t)
            guard dt < 3600 else { continue }   // пропускаємо сон
            drop += Double(a.p - b.p); time += dt
        }
        return time > 1800 ? drop / (time / 3600) : nil
    }
}
