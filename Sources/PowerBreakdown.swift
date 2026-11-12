import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import SystemConfiguration

struct PowerPart: Identifiable {
    var name: String
    var watts: Double?                 // nil — this part exists but doesn't report its own power
    var detail: String?
    var estimated = false
    var inside: [PowerActivity] = []   // what's inside this part, but without its own watts
    var id: String { name }
}

/// There's no power sensor, so we show whether this part is active right now. We don't make up watts: loading the SSD and Wi-Fi on an M3 didn't produce a separate line among the SMC keys.
struct PowerActivity: Identifiable, Equatable {
    var name: String
    var value: String
    var id: String { name }

    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1024 { return "Idle" }
        if bytesPerSecond < 1024 * 1024 { return String(format: "%.0f KB/s", bytesPerSecond / 1024) }
        return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
    }
}

/// What's going on with the built-in display. An external monitor powers itself, so its panel isn't in the Mac's power.
struct DisplayState {
    var builtInOn: Bool
    var externalOn: Bool
    var brightness: Double?
    var backlightEstimate: Double?     // estimate from brightness: there's no direct sensor

    /// PBLR and IBLR read 0 with the display on, so the backlight is measured empirically, not by a sensor: curve W = maxWatts · brightness^exponent.
    /// Mac15,12 (MacBook Air M3): brightness 10/50/100% under steady load, PSTR minus chip — 3.1 / 4.8 / 7.7 W.
    /// No measurements for other models: the panel is different, so better no number than someone else's.
    private static let backlightCurves: [String: (maxWatts: Double, exponent: Double)] = ["Mac15,12": (4.85, 1.35)]

    static func estimateBacklight(brightness: Double, model: String) -> Double? {
        backlightCurves[model].map { $0.maxWatts * pow(min(max(brightness, 0), 1), $0.exponent) }
    }
}

/// Where the whole Mac's power goes. These are whole-machine watts, not process Energy Impact: CPU or GPU can't be split between apps without root.
struct PowerBreakdown {
    var total: Double
    var parts: [PowerPart]

    /// channels — watts of the "Energy Model" channels; total — PSTR over the same interval, nil if this Mac doesn't report it.
    static func make(channels: [String: Double], total: Double?, display: DisplayState, activity: [PowerActivity] = []) -> PowerBreakdown {
        func sum(_ matches: (String) -> Bool) -> Double { channels.reduce(0) { matches($1.key) ? $0 + $1.value : $0 } }
        func prefixed(_ names: String...) -> Double { sum { key in names.contains { key.hasPrefix($0) } } }

        // Channel names differ between chips: "CPU Energy" on M3, "DIE_0_CPU Energy" on Ultra, "ANE0" on Max
        let engine = prefixed("DISP")
        var parts = [
            displayPart(display, engine: engine),
            PowerPart(name: "CPU", watts: sum { $0.hasSuffix("CPU Energy") }),
            PowerPart(name: "GPU", watts: sum { $0.hasSuffix("GPU Energy") }),
            PowerPart(name: "Memory", watts: prefixed("DRAM", "AMCC", "DCS")),
            PowerPart(name: "Neural Engine", watts: prefixed("ANE")),
            PowerPart(name: "Video & camera", watts: prefixed("AVE", "VDEC", "MSR", "ISP")),
            PowerPart(name: "Rest of chip", watts: prefixed("SOC_")),
        ]

        let known = parts.reduce(0) { $0 + ($1.watts ?? 0) }
        // The meters don't update in sync: over a short interval the sum of the parts can be slightly larger than PSTR
        let whole = max(total ?? known, known)
        parts.append(PowerPart(name: "Everything else", watts: total == nil ? nil : whole - known,
                               detail: display.builtInOn && display.backlightEstimate == nil ? "Includes backlight" : "No sensors",
                               inside: activity))
        return PowerBreakdown(total: whole, parts: parts)
    }

    /// Largest on top, by the number shown on screen: items equal by the shown number don't swap places on small jitters.
    var sortedByUsage: PowerBreakdown {
        func shown(_ part: PowerPart) -> Double { part.watts.map { ($0 * 10).rounded() } ?? -1 }
        var out = self
        out.parts = parts.enumerated().sorted {
            let (l, r) = (shown($0.element), shown($1.element))
            return l != r ? l > r : $0.offset < $1.offset
        }.map(\.element)
        return out
    }

    /// Without a curve for this model, display watts go into "Everything else".
    private static func displayPart(_ d: DisplayState, engine: Double) -> PowerPart {
        if d.builtInOn {
            return PowerPart(name: "Display", watts: d.backlightEstimate.map { $0 + engine },
                             detail: d.brightness.map { "Brightness \(Int(($0 * 100).rounded()))%" }, estimated: d.backlightEstimate != nil)
        }
        return PowerPart(name: "Display", watts: engine, detail: d.externalOn ? "External, own power" : "Off")
    }

    /// The readings jump every second: smooth them so the numbers can be read.
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

/// Chip energy counters. IOReport is a private library, so we load it at runtime: if it's missing, there's simply no breakdown.
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

    /// Average watts per channel since the previous call; the first call only records the start.
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

    /// Units differ even within one chip: GPU Energy on M3 is in nJ, the rest in mJ.
    static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return Double(value) / 1e3
        case "uJ": return Double(value) / 1e6
        case "nJ": return Double(value) / 1e9
        default: return nil
        }
    }
}

/// Measures only while the breakdown is visible: PSTR once a second (it jumps), the chip counters once every few seconds.
final class PowerBreakdownMonitor {
    static let tickInterval: TimeInterval = 1
    private static let ticksPerReading = 3

    private let queue = DispatchQueue(label: "sik.powerbreakdown", qos: .utility)
    private lazy var counters = EnergyCounters()
    private var totals: [Double] = []
    private var ticks = 0
    private var latest: PowerBreakdown?
    private var lastBytes: (at: Date, wifi: UInt32?, disk: UInt64)?
    private lazy var wifiName = Self.wifiInterface()

    func reset() {
        queue.async { [self] in
            counters?.reset()
            totals = []
            ticks = 0
            latest = nil
            lastBytes = nil
        }
    }

    func tick(_ done: @escaping (PowerBreakdown) -> Void) {
        queue.async { [self] in
            guard let counters else { return }
            if let w = SystemPower.readWatts() { totals.append(w) }
            // The first tick sets the start of the interval, then we wait a full interval
            if ticks % Self.ticksPerReading == 0 {
                let activity = readActivity()
                if let channels = counters.read() {
                    let total = totals.isEmpty ? nil : totals.reduce(0, +) / Double(totals.count)
                    let next = PowerBreakdown.make(channels: channels, total: total, display: Self.readDisplay(), activity: activity).smoothed(after: latest)
                    latest = next
                    totals = []
                    DispatchQueue.main.async { done(next) }
                }
            }
            ticks += 1
        }
    }

    private func readActivity() -> [PowerActivity] {
        let now = Date()
        let wifi = wifiName.flatMap(Self.interfaceBytes)
        let disk = Self.internalDiskBytes()
        defer { lastBytes = (now, wifi, disk) }
        var out: [PowerActivity] = []
        if let last = lastBytes, now > last.at {
            let seconds = now.timeIntervalSince(last.at)
            // The interface counter is 32-bit and overflows, so subtract with wraparound
            if let wifi, let was = last.wifi { out.append(PowerActivity(name: "Wi-Fi", value: PowerActivity.rate(Double(wifi &- was) / seconds))) }
            if disk >= last.disk { out.append(PowerActivity(name: "SSD", value: PowerActivity.rate(Double(disk - last.disk) / seconds))) }
        }
        if let playing = Self.audioPlaying() { out.append(PowerActivity(name: "Audio", value: playing ? "Active" : "Idle")) }
        return out
    }

    private static func wifiInterface() -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        return all.first { SCNetworkInterfaceGetInterfaceType($0) == kSCNetworkInterfaceTypeIEEE80211 }
            .flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
    }

    private static func interfaceBytes(_ name: String) -> UInt32? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        for ptr in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard String(cString: ifa.ifa_name) == name, ifa.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            return stats.ifi_ibytes &+ stats.ifi_obytes
        }
        return nil
    }

    /// Internal disk only: disk images and external drives also have IOBlockStorageDriver.
    private static func internalDiskBytes() -> UInt64 {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var total: UInt64 = 0
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            let protocolInfo = IORegistryEntrySearchCFProperty(driver, kIOServicePlane, "Protocol Characteristics" as CFString, nil,
                                                               IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) as? [String: Any]
            guard protocolInfo?["Physical Interconnect Location"] as? String == "Internal",
                  let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] else { continue }
            total += (stats["Bytes (Read)"] as? UInt64 ?? 0) + (stats["Bytes (Write)"] as? UInt64 ?? 0)
        }
        return total
    }

    private static func audioPlaying() -> Bool? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
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
