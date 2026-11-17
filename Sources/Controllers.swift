import Foundation
import GameController
import IOKit.hid

/// Game controller charge: DualSense, DualShock 4 and Xbox Wireless controllers.
/// They don't report charge to system_profiler, ioreg or the Battery Service.
/// Sony controllers put it in every HID input report, so we read it there (see SonyPad): it's known a few milliseconds after
/// the controller connects. Apple's GameController framework has it too, but only 15–20 s after a controller is switched on,
/// so it's the fallback, and the only source for Xbox controllers.
/// Both name a controller the same as Bluetooth settings do, so the card merges with the one from system_profiler.
final class ControllerBattery {
    private var observers: [NSObjectProtocol] = []
    private var settleTimer: Timer?
    private var hid: IOHIDManager?
    private var pads: [SonyPad] = []
    /// Connect or disconnect
    var onChange: (() -> Void)?
    /// A connected controller's level became known or changed
    var onLevel: (() -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.onChange?()
            self?.awaitLevels()
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.onChange?() })
        startHID()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        settleTimer?.invalidate(); settleTimer = nil
        if let hid {
            IOHIDManagerRegisterDeviceMatchingCallback(hid, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(hid, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(hid, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        hid = nil
        pads.forEach { $0.cancel() }
        pads = []
    }

    /// Reads the Sony controllers' charge again, along with the other devices. Main thread only.
    func poll() { pads.forEach { $0.read() } }

    /// Main thread only. Wired Xbox controllers and ones whose charge isn't known yet are left out.
    var devices: [BTDevice] {
        guard !observers.isEmpty else { return [] }
        var list = pads.compactMap { p in p.level.map { BTDevice(name: p.name, kind: "Gamepad", main: $0) } }
        for c in GCController.controllers() {
            guard let b = c.battery, Self.known(b), let name = c.vendorName, !name.isEmpty,
                  !list.contains(where: { $0.name == name }) else { continue }
            list.append(BTDevice(name: name, kind: "Gamepad", main: min(100, max(0, Int((b.batteryLevel * 100).rounded())))))
        }
        return list
    }

    // MARK: GameController

    private static func known(_ b: GCDeviceBattery) -> Bool { b.batteryState != .unknown || b.batteryLevel > 0 }

    /// Controllers with a battery whose level hasn't arrived yet
    private var pending: Int { GCController.controllers().filter { $0.battery.map { !Self.known($0) } ?? false }.count }

    /// The framework reads 0 for a controller that was just switched on. Re-check every second (a property read, no I/O)
    /// for up to 30 s and report as soon as the level shows up, instead of waiting for the next device refresh.
    private func awaitLevels() {
        settleTimer?.invalidate(); settleTimer = nil
        var waiting = pending
        guard waiting > 0 else { return }
        var ticks = 0
        settleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            ticks += 1
            let now = self.pending
            if now < waiting { self.onLevel?() }
            waiting = now
            if now == 0 || ticks >= 30 { t.invalidate(); self.settleTimer = nil }
        }
        settleTimer?.tolerance = 0.2
    }

    // MARK: HID

    /// Watches for Sony gamepads. Matching alone opens nothing: a controller is opened only for the moment of a read.
    private func startHID() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [
            kIOHIDVendorIDKey: SonyPad.vendor,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_GamePad,
        ] as CFDictionary)
        // Unretained: the model keeps this object for the app's lifetime, and stop() removes the callbacks
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<ControllerBattery>.fromOpaque(ctx).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<ControllerBattery>.fromOpaque(ctx).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        hid = m
    }

    private func added(_ device: IOHIDDevice) {
        guard !pads.contains(where: { CFEqual($0.device, device) }), let pad = SonyPad(device) else { return }
        pad.onLevel = { [weak self] in self?.onLevel?() }
        pads.append(pad)
        pad.read()
    }

    private func removed(_ device: IOHIDDevice) {
        guard let i = pads.firstIndex(where: { CFEqual($0.device, device) }) else { return }
        pads.remove(at: i).cancel()
        onLevel?()
    }
}

/// A DualSense or DualShock 4 seen over HID. Every input report carries the charge, so a read opens the controller,
/// takes the battery byte from the first report that has it and closes the controller again.
/// Nothing else in the report (buttons, sticks, motion) is looked at.
final class SonyPad {
    static let vendor = 0x054C
    private static let dualSenseIDs: Set<Int> = [0x0CE6, 0x0DF2]   // DualSense, DualSense Edge
    private static let dualShockIDs: Set<Int> = [0x05C4, 0x09CC]   // DualShock 4, first and second version
    private static let bufferSize = 128

    let device: IOHIDDevice
    let name: String
    let isDualSense: Bool
    private(set) var level: Int?
    var onLevel: (() -> Void)?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: SonyPad.bufferSize)
    private var reading = false
    private var generation = 0

    init?(_ device: IOHIDDevice) {
        let pid = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        guard Self.dualSenseIDs.contains(pid) || Self.dualShockIDs.contains(pid),
              let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String, !name.isEmpty else { return nil }
        self.device = device
        self.name = name
        isDualSense = Self.dualSenseIDs.contains(pid)
    }

    deinit { buffer.deallocate() }

    /// Main thread only. Reports come about 60 times a second, so this takes a few milliseconds.
    func read() {
        guard !reading, IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        reading = true
        generation += 1
        let g = generation
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let pad = Unmanaged<SonyPad>.fromOpaque(ctx).takeUnretainedValue()
            guard let level = SonyPad.level(UnsafeBufferPointer(start: report, count: length), dualSense: pad.isDualSense) else { return }
            pad.finish(level)
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // A controller in its basic Bluetooth mode sends reports without the charge: give up rather than keep listening
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.reading, self.generation == g else { return }
            self.cancel()
        }
    }

    private func finish(_ new: Int) {
        cancel()
        if new != level { level = new; onLevel?() }
    }

    /// Stops listening and closes the controller. Must run before the pad is dropped: the callback holds it unretained.
    func cancel() {
        guard reading else { return }
        reading = false
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.bufferSize, nil, nil)
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Charge in percent from one input report (report ID first), at the offsets Linux's hid-playstation and hid-sony use.
    /// The controller reports tenths, so 8 means 80–89% and we show the middle, 85%. nil for reports without the charge.
    static func level(_ r: UnsafeBufferPointer<UInt8>, dualSense: Bool) -> Int? {
        let at: Int
        switch (dualSense, r.first) {
        case (true, 0x01) where r.count >= 64: at = 53    // USB
        case (true, 0x31) where r.count >= 78: at = 54    // Bluetooth
        case (false, 0x01) where r.count >= 64: at = 30   // USB
        case (false, 0x11) where r.count >= 78: at = 32   // Bluetooth
        default: return nil
        }
        let level = Int(r[at] & 0x0F)
        if dualSense {
            switch r[at] >> 4 {
            case 0, 1: break        // discharging, charging
            case 2: return 100      // full
            default: return nil     // charging error: temperature or voltage out of range
            }
        }
        // DualShock 4 counts to 11 while on the cable
        return min(100, min(level, 10) * 10 + 5)
    }
}
