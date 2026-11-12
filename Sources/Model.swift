import AppKit
import Combine

final class AppModel: ObservableObject {
    @Published var battery: BatterySnapshot?
    /// Mac without a battery: how much the system draws, W; nil — this Mac doesn't report it.
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
    var tabs: [Tab] {
        let all: [Tab] = battery == nil ? [.power, .devices] : Tab.allCases
        return Settings.shared.trackDevices ? all : all.filter { $0 != .devices }
    }
    private var firstTab: Tab { battery == nil ? .power : .overview }
    @Published var apps: [AppEnergy] = []
    @Published var expandedApp: String?
    /// Where the whole Mac's power goes; measured only while this breakdown is visible.
    @Published var breakdown: PowerBreakdown?
    var breakdownOnScreen = false { didSet { scheduleBreakdown() } }
    @Published var lowPowerBusy = false
    @Published var popoverShown = false { didSet { if popoverShown != oldValue { scheduleSampling(); if popoverShown { refresh() }; startBluetoothOnDevicesTab() } } }
    /// Power tab on screen: live per-app energy sample every 10 s, battery every 2 s.
    static let liveEnergyInterval: TimeInterval = 10
    static let liveRefreshInterval: TimeInterval = 2
    /// The first live sample once the popover has finished drawing: otherwise top measures the opening itself, and the app sees itself at the top.
    static let liveEnergyDelay: TimeInterval = 2
    let energy = EnergyMonitor()
    let charge = ChargeControl()
    let ble = BLEBattery()
    private var classicDevices: [BTDevice] = []
    private var energyTimer: Timer?
    private var liveEnergyTimer: Timer?
    /// nil — the Power tab isn't visible; true — frequent samples; false — one sample on open.
    private var liveEnergyMode: Bool?
    private var powerTimer: Timer?
    private var breakdownTimer: Timer?
    private let breakdownMonitor = PowerBreakdownMonitor()

    let history = HistoryStore()
    let alerts = AlertEngine()
    let updates = UpdateChecker()
    let installer = UpdateInstaller()
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
        // Percentage toggle: the number and the limit change right away, not on the next update
        percentMode = Settings.shared.$percentMode.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
        // The icon shows the helper's state, so redraw it as soon as that changes
        chargeStatus = charge.$status.map { $0?.wallHold }.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.onChange?() }
        ble.onChange = { [weak self] in self?.mergeDevices() }
        energyMode = Settings.shared.$minimalEnergy.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyEnergyMode() }
        deviceTracking = Settings.shared.$trackDevices.dropFirst().removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.applyDeviceTracking() }
        trackingMode = Settings.shared.$appTracking.combineLatest(Settings.shared.$livePowerTab).dropFirst()
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleEnergy(); self?.scheduleSampling() }
        applyEnergyMode()
        // In minimal mode don't run top at startup: the first sample follows the Eco schedule
        if !Settings.shared.minimalEnergy { sampleEnergy() }
        installer.charge = charge
        installer.onInstalled = { [weak self] v in self?.alerts.announceInstalled(v) }
        installer.onFailed = { [weak self] _ in self?.updates.announceIfNeeded() }
        updates.autoInstall = { [weak self] r in self?.autoInstallIfNeeded(r) ?? false }
        updates.onRelease = { [weak self] r in
            guard let self else { return }
            self.alerts.announceUpdate(r, onInstall: self.installer.canInstall(r) ? { [weak self] in self?.installer.install(r) } : nil)
        }
        updates.start()
    }

    private func autoInstallIfNeeded(_ r: ReleaseInfo) -> Bool {
        let s = Settings.shared
        guard UpdatePolicy.shouldAutoInstall(r, current: updates.current, checkOn: s.updateCheck, autoOn: s.autoInstall,
                                             keyPresent: installer.keyPresent, homebrew: installer.homebrew,
                                             attempted: installer.attempted), !installer.busy else { return false }
        installer.install(r)
        return true
    }

    /// Starts or stops all background work per the "Minimal energy use" toggle.
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

    /// Starts or stops device polling per "Track devices" and "Minimal energy use".
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
            // Read devices only when the popover opens; don't leave old numbers looking live
            ble.stop()
            return
        }
        // Permission already granted — read in the background too. Not yet — the Devices tab will ask for it, not the app launch
        if ble.authorized || devicesOnScreen { ble.start() }
        refreshDevices()
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 90, repeats: true) { [weak self] _ in self?.refreshDevices() }
        deviceTimer?.tolerance = 15
    }

    var energyInterval: TimeInterval { Settings.shared.effectiveAppTracking.interval }

    /// Scheduled samples are the only ones that go into history. The step doesn't depend on the popover, so the hours are even.
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

    /// Minimal mode only slows the background: an open popover shows fresh numbers, because someone is looking at them.
    private var sampleRarely: Bool { Settings.shared.minimalEnergy && !popoverShown }
    /// Frequent updates on the Power tab: can be turned off in settings, and minimal mode doesn't enable them.
    var powerTabLive: Bool { popoverShown && tab == .power && Settings.shared.livePowerTab && !Settings.shared.minimalEnergy }
    /// Charge arrives via IOPS notifications anyway; the timer is only a backup.
    /// While the popover is open, charging that just started shows within seconds.
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
        // A fresh sample already exists — don't run top a second time when switching tabs
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
        // Don't leave old numbers looking live: the interval starts over
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

    /// Scheduled sample: goes into history.
    func sampleEnergy() {
        energy.sample(record: true) { [weak self] in self?.apps = self?.energy.apps ?? [] }
    }

    /// Live sample for the open Power tab: only the current list, no history.
    private func sampleLive() {
        energy.sample(record: false) { [weak self] in self?.apps = self?.energy.apps ?? [] }
    }

    /// Right-click toggles Low Power only when that won't ask for a password; otherwise it opens the popover, like left-click.
    func rightClickTogglesLowPower() -> Bool {
        guard battery != nil, Settings.shared.rightClickLowPower else { return false }
        charge.readStatus()
        return charge.installed && charge.helperAlive
    }

    /// Low Power: via the helper (no password), otherwise pmset with the admin password.
    func toggleLowPower() {
        guard let b = battery, !lowPowerBusy else { return }
        let want = !b.lowPower
        charge.readStatus()   // check the helper against fresh status: in the background it's read less often
        if charge.installed && charge.helperAlive {
            announceLowPower(want)
            charge.config.lowPower = want
            charge.config.lowPowerRequestAt = Date()
            return
        }
        lowPowerBusy = true
        LowPowerMode.set(want) { [weak self] ok in
            self?.lowPowerBusy = false
            // Password cancelled — the mode didn't change, so there's nothing to alert about
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
            // Mac without a battery (iMac, mini, Studio): wattage, per-app energy and devices
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
        // The reading jumps every second: smooth it so the number in the menu bar can be read
        let smooth = macWatts.map { ($0 + w) / 2 } ?? w
        let changed = macWatts?.rounded() != smooth.rounded()
        macWatts = smooth
        // History assumes a sample every wattInterval: in minimal mode only the current number
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
                // Turned off while we were reading
                guard Settings.shared.trackDevices else { return }
                self?.classicDevices = list
                // Don't touch via BLE what already reports charge (AirPods)
                self?.ble.paired = paired.filter { name, _ in !list.contains { $0.name == name && $0.lowest != nil } }
                self?.mergeDevices()
                self?.ble.poll()
            }
        }
    }

    /// Classic Bluetooth (system_profiler) + BLE Battery Service; duplicates by name are merged.
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
