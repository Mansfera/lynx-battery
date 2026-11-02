import CoreBluetooth
import Foundation

/// Заряд пристроїв через стандартний Bluetooth Battery Service (GATT 0x180F / рівень 0x2A19).
/// Так iPhone, iPad і багато навушників (Sony, Bose, Logitech…) віддають заряд спареному Mac.
/// Потрібен дозвіл на Bluetooth — macOS спитає один раз.
/// iPhone та iPad не тримають з'єднання з Mac, тож їх шукаємо коротким скануванням раз на кілька хвилин.
/// До чужих телефонів не підключаємось: macOS показує назву лише своїх пристроїв, і ми беремо тільки ті,
/// чия назва точно збігається зі списком спарених у system_profiler.
final class BLEBattery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var levels: [UUID: (name: String, level: Int, seen: Date)] = [:]
    private var timer: Timer?
    /// Підключені нами зі сканування: прочитали заряд — відключаємось, щоб не тримати зайве з'єднання.
    private var scanned: Set<UUID> = []
    /// Один пристрій — одна спроба за сканування: після відключення він рекламує себе знову.
    private var tried: Set<UUID> = []
    /// Показали, що Battery Service немає (Apple Watch, AirPods) — більше не турбуємо.
    private var noBattery: Set<UUID> = []
    private var lastScan = Date.distantPast
    private var lastConnected = -1
    private let scanEvery: TimeInterval = 300
    private let scanFor: TimeInterval = 8
    /// Спарені пристрої (назва → тип) із DeviceReader.
    var paired: [String: String] = [:]
    var onChange: (() -> Void)?

    var devices: [BTDevice] {
        levels.values
            .filter { Date().timeIntervalSince($0.seen) < 900 }
            .map { BTDevice(name: $0.name, kind: paired[$0.name].flatMap { $0.isEmpty ? nil : $0 } ?? Self.kind(for: $0.name), main: $0.level) }
    }

    var state: CBManagerState { central?.state ?? .unknown }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }
        timer?.tolerance = 10
    }

    func poll() {
        guard let c = central, c.state == .poweredOn else { return }
        // Пристрої, які вже тримає система (iPhone через Continuity, навушники) і які мають Battery Service
        let connected = c.retrieveConnectedPeripherals(withServices: [batteryService])
        // У лог — лише зміни: інакше запис на диск кожні 30 с і файл, що росте без меж
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
        // Не відповів — забуваємо спробу, інакше телефон поза зоною висів би в черзі з'єднань вічно
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.finish(p) }
    }

    /// Закінчили зі сканованим пристроєм. Те, що тримає сама система, не чіпаємо.
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

    /// Короткий лог у ~/Library/Application Support/com.mansfera.lynxbattery/ble.log — щоб бачити, що знайшлось.
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
