import Foundation
import GameController

/// Game controller charge via Apple's GameController framework: DualSense, DualShock 4 and Xbox Wireless controllers.
/// They don't report charge to system_profiler, ioreg or the Battery Service, but GCDeviceBattery has it.
/// The framework names a controller the same as Bluetooth settings do, so the card merges with the one from system_profiler.
/// Nothing is polled: the framework tells us about connects and disconnects, and the level is read whenever devices refresh.
final class ControllerBattery {
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.onChange?() })
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Main thread only. Wired controllers and ones whose charge isn't known yet are left out.
    var devices: [BTDevice] {
        guard !observers.isEmpty else { return [] }
        return GCController.controllers().compactMap { c in
            guard let b = c.battery, b.batteryState != .unknown || b.batteryLevel > 0,
                  let name = c.vendorName, !name.isEmpty else { return nil }
            return BTDevice(name: name, kind: "Gamepad", main: min(100, max(0, Int((b.batteryLevel * 100).rounded()))))
        }
    }
}
