import CoreBluetooth
import Foundation

/// Device charge via the standard Bluetooth Battery Service (GATT 0x180F / level 0x2A19).
/// This is how iPhone, iPad and many headphones (Sony, Bose, Logitech…) report charge to a paired Mac.
/// Needs Bluetooth permission — macOS asks once, when we first create the central, so only the Devices tab calls start() without permission.
/// iPhone and iPad don't stay connected to the Mac, so we find them with a short scan every few minutes.
/// We don't connect to other people's phones: macOS shows names only for your own devices, and we take only those
/// whose name exactly matches the paired list in system_profiler.
final class BLEBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var levels: [UUID: (name: String, level: Int, seen: Date)] = [:]
    private var timer: Timer?
    /// Connected by us from a scan: once the charge is read, disconnect so we don't hold an extra connection.
    private var scanned: Set<UUID> = []
    /// One device — one attempt per scan: after disconnecting it advertises itself again.
    private var tried: Set<UUID> = []
    /// Showed it has no Battery Service (Apple Watch, AirPods) — don't bother it again.
    private var noBattery: Set<UUID> = []
    private var lastScan = Date.distantPast
    private var lastConnected = -1
    private let scanEvery: TimeInterval = 300
    private let scanFor: TimeInterval = 8
    /// Paired devices (name → type) from DeviceReader.
    var paired: [String: String] = [:]
    var onChange: (() -> Void)?

    var devices: [BTDevice] {
        levels.values
            .filter { Date().timeIntervalSince($0.seen) < 900 }
            .map { BTDevice(name: $0.name, kind: paired[$0.name].flatMap { $0.isEmpty ? nil : $0 } ?? Self.kind(for: $0.name), main: $0.level) }
    }

    var state: CBManagerState { central?.state ?? .unknown }
    var authorized: Bool { CBManager.authorization == .allowedAlways }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 10
    }

    /// Minimal energy use: no scans and no connections. Our connections go away with the central; charge already read ages on its own.
    func stop() {
        timer?.invalidate(); timer = nil
        central?.stopScan()
        central = nil
        peripherals = [:]
        scanned = []
        lastConnected = -1
    }

    func poll() {
        guard let c = central, c.state == .poweredOn else { return }
        // Devices the system already holds (iPhone via Continuity, headphones) that have a Battery Service
        let connected = c.retrieveConnectedPeripherals(withServices: [batteryService])
        // Log only changes: otherwise a disk write every 30 s and a file that grows without bound
        if connected.count != lastConnected {
            lastConnected = connected.count
            Self.trace("poll: \(connected.count) connected with Battery Service")
        }
        for p in connected {
            if peripherals[p.identifier] == nil {
                peripherals[p.identifier] = p
                p.delegate = self
                Self.trace("found \(p.name ?? p.identifier.uuidString)")
            }
            if p.state == .connected { p.discoverServices([batteryService]) }
            else { c.connect(p) }
        }
        scan(c)
    }

    private func scan(_ c: CBCentralManager) {
        guard !paired.isEmpty, !c.isScanning, Date().timeIntervalSince(lastScan) >= scanEvery else { return }
        lastScan = Date()
        tried = []
        c.scanForPeripherals(withServices: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + scanFor) { c.stopScan() }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard let name = p.name, paired[name] != nil, !noBattery.contains(p.identifier),
              tried.insert(p.identifier).inserted else { return }
        Self.trace("nearby \(name)")
        scanned.insert(p.identifier)
        peripherals[p.identifier] = p
        p.delegate = self
        c.connect(p)
        // No response — forget the attempt, otherwise a phone out of range would sit in the connection queue forever
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(p) }
    }

    /// Done with a scanned device. Don't touch what the system itself holds.
    private func finish(_ p: CBPeripheral) {
        guard scanned.remove(p.identifier) != nil else { return }
        central?.cancelPeripheralConnection(p)
        peripherals[p.identifier] = nil
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        Self.trace("disconnected \(p.name ?? "?")")
        scanned.remove(p.identifier)
        peripherals[p.identifier] = nil
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        Self.trace("connect failed \(p.name ?? "?"): \(error?.localizedDescription ?? "-")")
        scanned.remove(p.identifier)
        peripherals[p.identifier] = nil
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        Self.trace("state \(c.state.rawValue) (5 = on, 3 = unauthorized), auth \(CBManager.authorization.rawValue)")
        poll()
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([batteryService])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        Self.trace("services \(p.name ?? "?"): \(p.services?.map(\.uuid.uuidString) ?? []) \(error?.localizedDescription ?? "")")
        guard p.services?.contains(where: { $0.uuid == batteryService }) == true else {
            if error == nil, scanned.contains(p.identifier) { noBattery.insert(p.identifier) }
            finish(p)
            return
        }
        for s in p.services ?? [] where s.uuid == batteryService {
            p.discoverCharacteristics([batteryLevel], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == batteryLevel {
            p.readValue(for: ch)
            if ch.properties.contains(.notify), !scanned.contains(p.identifier) { p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == batteryLevel else { return }
        guard error == nil, let v = ch.value?.first else {
            Self.trace("read failed \(p.name ?? "?"): \(error?.localizedDescription ?? "empty")")
            finish(p)
            return
        }
        levels[p.identifier] = (p.name ?? "Bluetooth device", Int(min(v, 100)), Date())
        Self.trace("\(p.name ?? "?") \(v)%")
        finish(p)
        onChange?()
    }

    /// Short log in ~/Library/Application Support/com.mansfera.lynxbattery/ble.log — to see what was found.
    static func trace(_ s: String) {
        let dir = AppData.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ble.log")
        let line = "[\(Date())] \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    static func kind(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("iphone") { return "Phone" }
        if n.contains("ipad") { return "Tablet" }
        if n.contains("watch") { return "Watch" }
        return "Headphones"
    }
}
