import CoreGraphics
import Foundation

struct PowerPart: Identifiable {
    var name: String
    var watts: Double?                 // nil — ця частина є, але свою потужність не повідомляє
    var detail: String?
    var estimated = false
    var id: String { name }
}

/// Що зараз із вбудованим екраном. Зовнішній монітор живиться сам, тож у потужності Mac його панелі немає.
struct DisplayState {
    var builtInOn: Bool
    var externalOn: Bool
    var brightness: Double?
    var backlightEstimate: Double?     // оцінка за яскравістю: прямого датчика немає

    /// PBLR та IBLR дають 0 при ввімкненому екрані, тож підсвітку міряємо заміром, а не датчиком: крива Вт = maxWatts · яскравість^exponent.
    /// Mac15,12 (MacBook Air M3): яскравість 10/50/100% при сталому навантаженні, PSTR мінус чип — 3,1 / 4,8 / 7,7 Вт.
    /// Для інших моделей замірів немає: панель інша, тож краще без числа, ніж із чужим.
    private static let backlightCurves: [String: (maxWatts: Double, exponent: Double)] = ["Mac15,12": (4.85, 1.35)]

    static func estimateBacklight(brightness: Double, model: String) -> Double? {
        backlightCurves[model].map { $0.maxWatts * pow(min(max(brightness, 0), 1), $0.exponent) }
    }
}

/// Куди йде потужність усього Mac. Це ватти всієї машини, а не Energy Impact процесів: розділити CPU чи GPU між апками без root не можна.
struct PowerBreakdown {
    var total: Double
    var parts: [PowerPart]

    /// channels — ватти каналів «Energy Model»; total — PSTR за той самий проміжок, nil якщо цей Mac його не повідомляє.
    static func make(channels: [String: Double], total: Double?, display: DisplayState) -> PowerBreakdown {
        func sum(_ matches: (String) -> Bool) -> Double { channels.reduce(0) { matches($1.key) ? $0 + $1.value : $0 } }
        func prefixed(_ names: String...) -> Double { sum { key in names.contains { key.hasPrefix($0) } } }

        // Назви каналів відрізняються між чипами: «CPU Energy» на M3, «DIE_0_CPU Energy» на Ultra, «ANE0» на Max
        let engine = prefixed("DISP")
        var parts = [
            displayPart(display, engine: engine),
            PowerPart(name: "CPU", watts: sum { $0.hasSuffix("CPU Energy") }),
            PowerPart(name: "GPU", watts: sum { $0.hasSuffix("GPU Energy") }),
            PowerPart(name: "Memory", watts: prefixed("DRAM", "AMCC", "DCS")),
        ]
        let optional = [
            PowerPart(name: "Neural Engine", watts: prefixed("ANE")),
            PowerPart(name: "Video & camera", watts: prefixed("AVE", "VDEC", "MSR", "ISP")),
        ]
        parts += optional.filter { ($0.watts ?? 0) >= visibleWatts }

        let known = parts.reduce(0) { $0 + ($1.watts ?? 0) }
        // Вимірювачі оновлюються не синхронно: на короткому проміжку сума частин буває трохи більшою за PSTR
        let whole = max(total ?? known, known)
        if whole - known >= visibleWatts {
            parts.append(PowerPart(name: "Everything else", watts: whole - known, detail: display.builtInOn && display.backlightEstimate == nil ? "Includes backlight" : "Wi-Fi, SSD, audio"))
        }
        return PowerBreakdown(total: whole, parts: parts)
    }

    private static let visibleWatts = 0.05

    /// Без кривої для цієї моделі ватти екрана потрапляють у «Everything else».
    private static func displayPart(_ d: DisplayState, engine: Double) -> PowerPart {
        if d.builtInOn {
            return PowerPart(name: "Display", watts: d.backlightEstimate.map { $0 + engine },
                             detail: d.brightness.map { "Brightness \(Int(($0 * 100).rounded()))%" }, estimated: d.backlightEstimate != nil)
        }
        return PowerPart(name: "Display", watts: engine, detail: d.externalOn ? "External, own power" : "Off")
    }

    /// Показники стрибають щосекунди: згладжуємо, щоб числа встигали прочитати.
    func smoothed(after old: PowerBreakdown?) -> PowerBreakdown {
        guard let old else { return self }
        var out = self
        out.total = (old.total + total) / 2
        for i in out.parts.indices {
            if let w = out.parts[i].watts, let was = old.parts.first(where: { $0.name == out.parts[i].name })?.watts {
                out.parts[i].watts = (was + w) / 2
            }
        }
        return out
    }
}

/// Лічильники енергії чипа. IOReport — приватна бібліотека, тож вантажимо її під час роботи: якщо її немає, просто немає розбивки.
private final class EnergyCounters {
    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: ChannelString
    private let channelUnit: ChannelString
    private let channelValue: ChannelValue
    private let subscription: UnsafeMutableRawPointer
    private let subscribed: CFMutableDictionary
    private var last: (at: Date, sample: CFDictionary)?

    init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW),
              let copy = dlsym(lib, "IOReportCopyChannelsInGroup"), let create = dlsym(lib, "IOReportCreateSubscription"),
              let samples = dlsym(lib, "IOReportCreateSamples"), let delta = dlsym(lib, "IOReportCreateSamplesDelta"),
              let name = dlsym(lib, "IOReportChannelGetChannelName"), let unit = dlsym(lib, "IOReportChannelGetUnitLabel"),
              let value = dlsym(lib, "IOReportSimpleGetIntegerValue") else { return nil }
        createSamples = unsafeBitCast(samples, to: CreateSamples.self)
        createDelta = unsafeBitCast(delta, to: CreateDelta.self)
        channelName = unsafeBitCast(name, to: ChannelString.self)
        channelUnit = unsafeBitCast(unit, to: ChannelString.self)
        channelValue = unsafeBitCast(value, to: ChannelValue.self)
        guard let channels = unsafeBitCast(copy, to: CopyChannels.self)("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let wanted = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) else { return nil }
        var out: Unmanaged<CFMutableDictionary>?
        guard let sub = unsafeBitCast(create, to: CreateSubscription.self)(nil, wanted, &out, 0, nil), let out else { return nil }
        subscription = sub
        subscribed = out.takeRetainedValue()
    }

    func reset() { last = nil }

    /// Середні ватти кожного каналу від попереднього виклику; перший виклик лише запам'ятовує початок.
    func read() -> [String: Double]? {
        guard let now = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        defer { last = (Date(), now) }
        guard let last, let delta = createDelta(last.sample, now, nil)?.takeRetainedValue() else { return nil }
        let seconds = Date().timeIntervalSince(last.at)
        guard seconds > 0, let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return nil }
        var out: [String: Double] = [:]
        for item in items {
            let channel = item as CFDictionary
            guard let name = channelName(channel)?.takeUnretainedValue() as String?,
                  let unit = channelUnit(channel)?.takeUnretainedValue() as String?,
                  let joules = Self.joules(channelValue(channel, 0), unit: unit) else { continue }
            out[name] = joules / seconds
        }
        return out
    }

    /// Одиниці різні навіть в одному чипі: GPU Energy на M3 у нДж, решта в мДж.
    static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return Double(value) / 1e3
        case "uJ": return Double(value) / 1e6
        case "nJ": return Double(value) / 1e9
        default: return nil
        }
    }
}

/// Вимірює лише поки розбивку видно: раз на секунду PSTR (він стрибає), раз на кілька секунд лічильники чипа.
final class PowerBreakdownMonitor {
    static let tickInterval: TimeInterval = 1
    private static let ticksPerReading = 3

    private let queue = DispatchQueue(label: "sik.powerbreakdown", qos: .utility)
    private lazy var counters = EnergyCounters()
    private var totals: [Double] = []
    private var ticks = 0
    private var latest: PowerBreakdown?

    func reset() {
        queue.async { [self] in
            counters?.reset()
            totals = []
            ticks = 0
            latest = nil
        }
    }

    func tick(_ done: @escaping (PowerBreakdown) -> Void) {
        queue.async { [self] in
            guard let counters else { return }
            if let w = SystemPower.readWatts() { totals.append(w) }
            // Перший такт задає початок проміжку, далі чекаємо повний проміжок
            if ticks % Self.ticksPerReading == 0, let channels = counters.read() {
                let total = totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
                let next = PowerBreakdown.make(channels: channels, total: total, display: Self.readDisplay()).smoothed(after: latest)
                latest = next
                totals = []
                DispatchQueue.main.async { done(next) }
            }
            ticks += 1
        }
    }

    private static func readDisplay() -> DisplayState {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let online = ids.prefix(Int(count))
        guard let builtIn = online.first(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }) else {
            return DisplayState(builtInOn: false, externalOn: !online.isEmpty, brightness: nil)
        }
        let level = brightness(of: builtIn)
        return DisplayState(builtInOn: true, externalOn: online.count > 1, brightness: level,
                            backlightEstimate: level.flatMap { DisplayState.estimateBacklight(brightness: $0, model: hardwareModel) })
    }

    private static let hardwareModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    private static func brightness(of display: CGDirectDisplayID) -> Double? {
        typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        guard let lib = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(lib, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        return unsafeBitCast(get, to: GetBrightness.self)(display, &value) == 0 ? Double(value) : nil
    }
}
