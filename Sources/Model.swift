import AppKit
import Combine

final class AppModel: ObservableObject {
    @Published var battery: BatterySnapshot?
    /// Mac без батареї: скільки споживає система, Вт; nil — цей Mac такого не повідомляє.
    @Published var macWatts: Double?
    @Published var wattHistory: [Double] = []
    static let wattInterval: TimeInterval = 3
    @Published var devices: [BTDevice] = []
    @Published var range: HistoryRange = .day
    @Published private(set) var historyTick = 0

    enum Tab: String, CaseIterable, Identifiable { case overview = "Overview", charge = "Charge", power = "Power", devices = "Devices"; var id: String { rawValue } }
    @Published var tab: Tab = .overview
    @Published var apps: [AppEnergy] = []
    @Published var expandedApp: String?
    @Published var lowPowerBusy = false
    @Published var popoverShown = false { didSet { if popoverShown != oldValue { scheduleSampling() } } }
    let energy = EnergyMonitor()
    let charge = ChargeControl()
    let ble = BLEBattery()
    private var classicDevices: [BTDevice] = []
    private var energyTimer: Timer?
    private var powerTimer: Timer?

    let history = HistoryStore()
    let alerts = AlertEngine()
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var deviceTimer: Timer?
    private var percentMode: AnyCancellable?
    private var chargeStatus: AnyCancellable?
    private var energyMode: AnyCancellable?
    private let deviceQueue = DispatchQueue(label: "sik.devices", qos: .utility)

    func start() {
        refresh()
        BatteryReader.observe { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // Перемикач відсотка: число й ліміт міняються одразу, а не за наступним оновленням
        percentMode = Settings.shared.$percentMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        // Іконка показує стан хелпера, тож малюємо її одразу, щойно він змінився
        chargeStatus = charge.$status.map { $0?.wallHold }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.onChange?() }
        ble.onChange = { [weak self] in self?.mergeDevices() }
        energyMode = Settings.shared.$minimalEnergy.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyEnergyMode() }
        applyEnergyMode()
    }

    /// Запускає або зупиняє все фонове під перемикач «Minimal energy use».
    private func applyEnergyMode() {
        let minimal = Settings.shared.minimalEnergy
        deviceTimer?.invalidate(); deviceTimer = nil
        energyTimer?.invalidate(); energyTimer = nil
        charge.minimalEnergy = minimal
        charge.setVisible(popoverShown)
        if minimal {
            // Пристрої читаємо лише при відкритті поповера; старих чисел під виглядом живих не лишаємо
            ble.stop()
            apps = []
            wattHistory = []
        } else {
            ble.start()
            refreshDevices()
            deviceTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.refreshDevices() }
            deviceTimer?.tolerance = 15
            // Енергію по апках пишемо раз на 2 хв у фоні; поки поповер відкритий — частіше.
            sampleEnergy()
            energyTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in self?.sampleEnergy() }
            energyTimer?.tolerance = 20
        }
        scheduleSampling()
    }

    /// Мінімальний режим пригальмовує лише фон: відкритий поповер показує свіжі числа, бо на них дивляться.
    private var sampleRarely: Bool { Settings.shared.minimalEnergy && !popoverShown }
    /// Заряд і так приходить сповіщенням IOPS, таймер лише страхує.
    var refreshInterval: TimeInterval { sampleRarely ? 300 : 20 }
    var powerInterval: TimeInterval { sampleRarely ? 60 : Self.wattInterval }

    private func scheduleSampling() {
        if timer?.timeInterval != refreshInterval {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
            timer?.tolerance = refreshInterval / 4
        }
        if let t = powerTimer, t.timeInterval != powerInterval { t.invalidate(); startPowerTimer() }
    }

    private func startPowerTimer() {
        powerTimer = Timer.scheduledTimer(withTimeInterval: powerInterval, repeats: true) { [weak self] _ in self?.samplePower() }
    }

    func sampleEnergy() {
        guard !Settings.shared.minimalEnergy else { return }
        energy.sample { [weak self] in self?.apps = self?.energy.apps ?? [] }
    }

    /// Енергозбереження: через хелпер (без пароля), інакше — pmset з паролем адміністратора.
    func toggleLowPower() {
        guard let b = battery, !lowPowerBusy else { return }
        let want = !b.lowPower
        charge.readStatus()   // хелпер перевіряємо за свіжим станом: у фоні він читається рідше
        if charge.installed && charge.helperAlive {
            announceLowPower(want)
            charge.config.lowPower = want
            charge.config.lowPowerRequestAt = Date()
            return
        }
        lowPowerBusy = true
        LowPowerMode.set(want) { [weak self] ok in
            self?.lowPowerBusy = false
            // Пароль скасували — режим не змінився, тож і сповіщати нема про що
            if ok { self?.announceLowPower(want) }
            self?.refresh()
        }
    }

    private func announceLowPower(_ on: Bool) {
        alerts.presenter.show(AlertSpec(title: on ? "Low Power Mode on" : "Low Power Mode off",
                                        subtitle: on ? "Dimmer, quieter, longer on battery" : "Back to full performance",
                                        symbol: on ? "leaf.fill" : "leaf", tone: on ? .saver : .neutral))
    }

    func refresh() {
        guard SystemPower.hasInternalBattery(), var b = BatteryReader.read() else {
            // Mac без батареї (iMac, mini, Studio): потужність, енергія по апках і пристрої
            if battery != nil { battery = nil }
            if tab == .overview || tab == .charge { tab = .power }
            if powerTimer == nil {
                samplePower()
                startPowerTimer()
            }
            onChange?()
            return
        }
        powerTimer?.invalidate(); powerTimer = nil
        SystemPower.dropStaleDrain(&b)
        charge.readStatus()
        charge.adoptScale(Settings.shared.limitScale, b)
        b.percentTop = Settings.shared.percentMode.chargeScale.top(b)
        b.percent = Settings.shared.percentMode.pick(b)
        alerts.evaluate(b)
        alerts.evaluateCharger(b)
        history.record(b)
        historyTick += 1
        battery = b
        onChange?()
    }

    private func samplePower() {
        guard let w = SystemPower.readWatts() else {
            if macWatts != nil { macWatts = nil; onChange?() }
            return
        }
        // Показник стрибає щосекунди: згладжуємо, щоб число в меню-барі встигали прочитати
        let smooth = macWatts.map { ($0 + w) / 2 } ?? w
        let changed = macWatts?.rounded() != smooth.rounded()
        macWatts = smooth
        // Історія розрахована на заміри раз на wattInterval: у мінімальному режимі лише поточне число
        if !Settings.shared.minimalEnergy {
            wattHistory.append(smooth)
            if wattHistory.count > Int(300 / Self.wattInterval) { wattHistory.removeFirst() }
        }
        if changed { onChange?() }
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
}
