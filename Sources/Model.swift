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
    @Published var tab: Tab = .overview {
        didSet {
            if tab == .devices, !Settings.shared.trackDevices { tab = firstTab }
            startBluetoothOnDevicesTab()
            scheduleSampling()
        }
    }
    /// Вкладки, які показує верхня панель.
    var tabs: [Tab] {
        let all: [Tab] = battery == nil ? [.power, .devices] : Tab.allCases
        return Settings.shared.trackDevices ? all : all.filter { $0 != .devices }
    }
    private var firstTab: Tab { battery == nil ? .power : .overview }
    @Published var apps: [AppEnergy] = []
    @Published var expandedApp: String?
    /// Куди йде потужність усього Mac; міряємо лише поки цю розбивку видно.
    @Published var breakdown: PowerBreakdown?
    var breakdownOnScreen = false { didSet { scheduleBreakdown() } }
    @Published var lowPowerBusy = false
    @Published var popoverShown = false { didSet { if popoverShown != oldValue { scheduleSampling(); if popoverShown { refresh() }; startBluetoothOnDevicesTab() } } }
    /// Вкладка Power на екрані: живий замір енергії по апках кожні 10 с, батарея — кожні 2 с.
    static let liveEnergyInterval: TimeInterval = 10
    static let liveRefreshInterval: TimeInterval = 2
    /// Перший живий замір — коли поповер уже домалювався: інакше top міряє саме відкриття, і апка бачить себе в топі.
    static let liveEnergyDelay: TimeInterval = 2
    let energy = EnergyMonitor()
    let charge = ChargeControl()
    let ble = BLEBattery()
    private var classicDevices: [BTDevice] = []
    private var energyTimer: Timer?
    private var liveEnergyTimer: Timer?
    /// nil — вкладку Power не видно; true — часті заміри; false — один замір при відкритті.
    private var liveEnergyMode: Bool?
    private var powerTimer: Timer?
    private var breakdownTimer: Timer?
    private let breakdownMonitor = PowerBreakdownMonitor()

    let history = HistoryStore()
    let alerts = AlertEngine()
    let updates = UpdateChecker()
    var onChange: (() -> Void)?
    private var timer: Timer?
    private var deviceTimer: Timer?
    private var percentMode: AnyCancellable?
    private var chargeStatus: AnyCancellable?
    private var energyMode: AnyCancellable?
    private var deviceTracking: AnyCancellable?
    private var trackingMode: AnyCancellable?
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
        deviceTracking = Settings.shared.$trackDevices.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyDeviceTracking() }
        trackingMode = Settings.shared.$appTracking.combineLatest(Settings.shared.$livePowerTab).dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleEnergy(); self?.scheduleSampling() }
        applyEnergyMode()
        // У мінімальному режимі top на старті не запускаємо: перший замір — за розкладом Eco
        if !Settings.shared.minimalEnergy { sampleEnergy() }
        updates.onRelease = { [weak self] r in self?.alerts.announceUpdate(r) }
        updates.start()
    }

    /// Запускає або зупиняє все фонове під перемикач «Minimal energy use».
    private func applyEnergyMode() {
        let minimal = Settings.shared.minimalEnergy
        charge.minimalEnergy = minimal
        charge.setVisible(popoverShown)
        applyDeviceTracking()
        if minimal {
            wattHistory = []
        }
        scheduleEnergy()
        scheduleSampling()
    }

    /// Запускає або зупиняє опитування пристроїв під «Track devices» і «Minimal energy use».
    private func applyDeviceTracking() {
        deviceTimer?.invalidate(); deviceTimer = nil
        guard Settings.shared.trackDevices else {
            ble.stop()
            classicDevices = []
            if tab == .devices { tab = firstTab }
            if !devices.isEmpty { devices = []; onChange?() }
            return
        }
        if Settings.shared.minimalEnergy {
            // Пристрої читаємо лише при відкритті поповера; старих чисел під виглядом живих не лишаємо
            ble.stop()
            return
        }
        // Дозвіл уже є — читаємо й у фоні. Ще немає — про нього спитає вкладка Devices, а не запуск апки
        if ble.authorized || devicesOnScreen { ble.start() }
        refreshDevices()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.refreshDevices() }
        deviceTimer?.tolerance = 15
    }

    var energyInterval: TimeInterval { Settings.shared.effectiveAppTracking.interval }

    /// Заміри за розкладом — єдині, що йдуть в історію. Крок не залежить від поповера, тож години рівномірні.
    private func scheduleEnergy() {
        guard energyTimer?.timeInterval != energyInterval else { return }
        energyTimer?.invalidate()
        energyTimer = Timer.scheduledTimer(withTimeInterval: energyInterval, repeats: true) { [weak self] _ in self?.sampleEnergy() }
        energyTimer?.tolerance = energyInterval / 6
    }

    private var devicesOnScreen: Bool { popoverShown && tab == .devices }

    private func startBluetoothOnDevicesTab() {
        if devicesOnScreen, Settings.shared.trackDevices, !Settings.shared.minimalEnergy { ble.start() }
    }

    /// Мінімальний режим пригальмовує лише фон: відкритий поповер показує свіжі числа, бо на них дивляться.
    private var sampleRarely: Bool { Settings.shared.minimalEnergy && !popoverShown }
    /// Часті оновлення на вкладці Power: можна вимкнути в налаштуваннях, а мінімальний режим їх не вмикає.
    var powerTabLive: Bool { popoverShown && tab == .power && Settings.shared.livePowerTab && !Settings.shared.minimalEnergy }
    /// Заряд і так приходить сповіщенням IOPS, таймер лише страхує.
    /// Поки поповер відкритий, заряд, що щойно почався, видно за секунди.
    var refreshInterval: TimeInterval { sampleRarely ? 300 : powerTabLive ? Self.liveRefreshInterval : (popoverShown ? 5 : 20) }
    var powerInterval: TimeInterval { sampleRarely ? 60 : Self.wattInterval }

    private func scheduleSampling() {
        if timer?.timeInterval != refreshInterval {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
            timer?.tolerance = refreshInterval / 4
        }
        if let t = powerTimer, t.timeInterval != powerInterval { t.invalidate(); startPowerTimer() }
        scheduleBreakdown()
        scheduleLiveEnergy()
    }

    private func scheduleLiveEnergy() {
        let mode: Bool? = popoverShown && tab == .power ? powerTabLive : nil
        guard mode != liveEnergyMode else { return }
        liveEnergyMode = mode
        liveEnergyTimer?.invalidate(); liveEnergyTimer = nil
        guard let mode else { return }
        // Свіжий замір уже є — на перемиканні вкладок top удруге не запускаємо
        let fresh = energy.lastSample.map { Date().timeIntervalSince($0) < Self.liveEnergyInterval } ?? false
        if fresh && !mode { return }
        liveEnergyTimer = Timer.scheduledTimer(withTimeInterval: fresh ? Self.liveEnergyInterval : Self.liveEnergyDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.sampleLive()
            guard mode else { self.liveEnergyTimer = nil; return }
            self.liveEnergyTimer = Timer.scheduledTimer(withTimeInterval: Self.liveEnergyInterval, repeats: true) { [weak self] _ in self?.sampleLive() }
            self.liveEnergyTimer?.tolerance = 1
        }
    }

    private func scheduleBreakdown() {
        let wanted = breakdownOnScreen && popoverShown && !Settings.shared.minimalEnergy
        guard wanted != (breakdownTimer != nil) else { return }
        breakdownTimer?.invalidate(); breakdownTimer = nil
        guard wanted else { return }
        // Старих чисел під виглядом живих не лишаємо: проміжок починається заново
        breakdown = nil
        breakdownMonitor.reset()
        tickBreakdown()
        breakdownTimer = Timer.scheduledTimer(withTimeInterval: PowerBreakdownMonitor.tickInterval, repeats: true) { [weak self] _ in self?.tickBreakdown() }
    }

    private func tickBreakdown() {
        breakdownMonitor.tick { [weak self] b in
            guard let self, self.breakdownTimer != nil else { return }
            self.breakdown = b
        }
    }

    private func startPowerTimer() {
        powerTimer = Timer.scheduledTimer(withTimeInterval: powerInterval, repeats: true) { [weak self] _ in self?.samplePower() }
    }

    /// Замір за розкладом: іде в історію.
    func sampleEnergy() {
        energy.sample(record: true) { [weak self] in self?.apps = self?.energy.apps ?? [] }
    }

    /// Живий замір для відкритої вкладки Power: лише список зараз, без історії.
    private func sampleLive() {
        energy.sample(record: false) { [weak self] in self?.apps = self?.energy.apps ?? [] }
    }

    /// ПКМ перемикає енергозбереження, лише коли це не спитає пароль; інакше відкриває поповер, як і ЛКМ.
    func rightClickTogglesLowPower() -> Bool {
        guard battery != nil, Settings.shared.rightClickLowPower else { return false }
        charge.readStatus()
        return charge.installed && charge.helperAlive
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
        SystemPower.liveDraw(&b)
        charge.readStatus()
        charge.adoptScale(Settings.shared.limitScale, b)
        b.percentTop = Settings.shared.percentMode.chargeScale.top(b)
        b.percent = Settings.shared.percentMode.pick(b)
        alerts.evaluate(b)
        alerts.evaluateCharger(&b)
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
        guard Settings.shared.trackDevices else { return }
        deviceQueue.async { [weak self] in
            let (list, paired) = DeviceReader.read()
            DispatchQueue.main.async {
                // Вимкнули, поки читали
                guard Settings.shared.trackDevices else { return }
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
        guard Settings.shared.trackDevices else { return }
        var list = classicDevices
        for d in ble.devices { DeviceReader.absorb(d, into: &list) }
        list.sort { ($0.lowest ?? 101) < ($1.lowest ?? 101) }
        devices = list
        alerts.evaluate(devices: list)
        onChange?()
    }
}
