import AppKit
import Combine

final class AppModel: ObservableObject {
    @Published var battery: BatterySnapshot?
    @Published var devices: [BTDevice] = []
    @Published var range: HistoryRange = .day
    @Published var page: Page = .main
    @Published private(set) var historyTick = 0

    enum Page { case main, settings }
    enum Tab: String, CaseIterable, Identifiable { case overview = "Overview", charge = "Charge", power = "Power", devices = "Devices"; var id: String { rawValue } }
    @Published var tab: Tab = .overview
    @Published var apps: [AppEnergy] = []
    @Published var expandedApp: String?
    @Published var lowPowerBusy = false
    let energy = EnergyMonitor()
    let charge = ChargeControl()
    let ble = BLEBattery()
    private var classicDevices: [BTDevice] = []
    private var energyTimer: Timer?

    let history = HistoryStore()
    let alerts = AlertEngine()
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var deviceTimer: Timer?
    private let deviceQueue = DispatchQueue(label: "sik.devices", qos: .utility)

    func start() {
        refresh()
        BatteryReader.observe { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.refresh() }
        ble.onChange = { [weak self] in self?.mergeDevices() }
        ble.start()
        refreshDevices()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.refreshDevices() }
        // Енергію по апках пишемо раз на 2 хв у фоні; поки поповер відкритий — частіше.
        sampleEnergy()
        energyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.sampleEnergy() }
    }

    func sampleEnergy() {
        energy.sample { [weak self] in self?.apps = self?.energy.apps ?? [] }
    }

    /// Енергозбереження: через хелпер (без пароля), інакше — pmset з паролем адміністратора.
    func toggleLowPower() {
        guard let b = battery else { return }
        let want = !b.lowPower
        alerts.presenter.show(AlertSpec(title: want ? "Low Power Mode on" : "Low Power Mode off",
                                        subtitle: want ? "Dimmer, quieter, longer on battery" : "Back to full performance",
                                        symbol: want ? "leaf.fill" : "leaf", tone: want ? .saver : .neutral))
        if charge.installed && charge.helperAlive {
            charge.config.lowPower = want
            charge.config.lowPowerRequestAt = Date()
            return
        }
        lowPowerBusy = true
        LowPowerMode.set(want) { [weak self] in
            self?.lowPowerBusy = false
            self?.refresh()
        }
    }

    func refresh() {
        guard var b = BatteryReader.read() else {
            // Mac без батареї (iMac, mini, Studio): живемо пристроями
            if battery != nil { battery = nil }
            if tab != .devices { tab = .devices }
            onChange?()
            return
        }
        b.percent = Settings.shared.percentMode.pick(b)
        alerts.evaluate(b)
        alerts.evaluateCharger(b)
        history.record(b)
        historyTick += 1
        battery = b
        onChange?()
    }

    func refreshDevices() {
        deviceQueue.async { [weak self] in
            let (list, paired) = DeviceReader.read()
            DispatchQueue.main.async {
                self?.classicDevices = list
                // Те, що вже звітує заряд (AirPods), через BLE не чіпаємо
                self?.ble.paired = paired.filter { name, _ in !list.contains { $0.name == name && $0.lowest != nil } }
                self?.mergeDevices()
                self?.ble.poll()
            }
        }
    }

    /// Класичний Bluetooth (system_profiler) + BLE Battery Service; дублікати за назвою зливаємо.
    private func mergeDevices() {
        var list = classicDevices
        for d in ble.devices { DeviceReader.absorb(d, into: &list) }
        list.sort { ($0.lowest ?? 101) < ($1.lowest ?? 101) }
        devices = list
        alerts.evaluate(devices: list)
        onChange?()
    }

    func testAlert() {
        let p = battery?.percent ?? 15
        alerts.presenter.show(AlertSpec(title: "\(p)% left", subtitle: "This is how alerts look",
                                        symbol: "battery.25percent", tone: .low))
    }

    func testFullScreen() { alerts.presenter.showFullScreen(percent: 2) }
}
