import Foundation
import notify

/// The app writes the limit settings, the root helper enforces them and reports status.
final class ChargeControl: ObservableObject {
    @Published var config = ChargeConfig() { didSet { if config != oldValue && !loadingFromFile { scheduleSave() } } }
    @Published private(set) var status: ChargeStatus?
    @Published private(set) var installed = false
    @Published private(set) var helperOutdated = false
    @Published var busy = false
    @Published var error: String?

    private var saveWork: DispatchWorkItem?
    private var statusFollowUp: DispatchWorkItem?
    private var loadingFromFile = false
    private var previewing = false
    private var timer: Timer?
    /// Minimal energy use: in the background only model updates read the status, our own timer is redundant. The helper learns via the settings.
    var minimalEnergy = false { didSet { syncMinimalEnergy() } }

    init() {
        installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
        if let d = FileManager.default.contents(atPath: ChargePaths.config),
           let c = try? JSONDecoder().decode(ChargeConfig.self, from: d) { config = c.sanitized() }
        readStatus()
        setVisible(false)
    }

    /// The helper writes status every 15 s, but it's only visible in the popover: in the background we read rarely.
    func setVisible(_ visible: Bool) {
        guard !previewing else { return }
        timer?.invalidate(); timer = nil
        if visible || !minimalEnergy {
            timer = Timer.scheduledTimer(withTimeInterval: visible ? 5 : 45, repeats: true) { [weak self] _ in self?.readStatus() }
            timer?.tolerance = visible ? 1 : 10
        }
        if visible { readStatus(); checkHelper() }
    }

    /// The helper is alive if it wrote status no more than a minute ago.
    var helperAlive: Bool { status.map { Date().timeIntervalSince($0.updated) < ChargeStatus.aliveWindow } ?? false }
    var adapterOnly: Bool { status.map { !$0.capabilities.contains("charge-inhibit") && $0.capabilities.contains("adapter") } ?? false }
    /// The limit is holding on wall power: only this state draws the icon blue.
    var holdingOnWall: Bool { helperAlive && status?.wallHold == true }
    /// The firmware limit works in sleep too, so there's no need to stay awake up to the limit.
    var limitWorksAsleep: Bool { status?.capabilities.contains("firmware-limit") ?? false }
    /// Draining to the limit is possible only when both levers exist.
    var canDischarge: Bool { status.map { $0.capabilities.contains("charge-inhibit") && $0.capabilities.contains("adapter") } ?? false }

    /// The limit is set in the percentage the app shows: when the mode changes we convert the number, and the physical limit stays the same.
    func adoptScale(_ scale: ChargeScale, _ raw: BatterySnapshot) {
        let old = config.scale ?? .trueCharge
        if config.scale == scale { return }
        let wasTop = config.limit >= old.top(raw)
        config.limit = wasTop ? scale.top(raw) : min(scale.top(raw), old.convert(config.limit, to: scale, raw))
        config.scale = scale
    }

    /// The helper in the bundle is newer than the installed one — needs reinstalling (with the password).
    /// Reads both files in full, so not from the tab's body, but when the popover opens and after install.
    private func checkHelper() {
        helperOutdated = {
            guard installed else { return false }
            let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(ChargePaths.label)")
            guard let a = FileManager.default.contents(atPath: bundled.path),
                  let b = FileManager.default.contents(atPath: ChargePaths.helperBinary) else { return false }
            return a != b
        }()
    }

    func readStatus() {
        guard !previewing else { return }
        installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = FileManager.default.contents(atPath: ChargePaths.status),
              let s = try? dec.decode(ChargeStatus.self, from: d) else { status = nil; return }
        if s != status { status = s }
        // The file may have been changed by the helper (clears Top Up after 100 %) or another copy of the app: pick everything up and don't write back,
        // otherwise stale values from memory would overwrite the file. While there's an unsaved change, it's newer than the file.
        if saveWork == nil, let d = FileManager.default.contents(atPath: ChargePaths.config),
           let c = try? JSONDecoder().decode(ChargeConfig.self, from: d), c.sanitized() != config {
            loadingFromFile = true
            config = c.sanitized()
            loadingFromFile = false
            // The toggle lives in the app's settings: the file may have been rewritten by an older helper that doesn't know this field
            syncMinimalEnergy()
        }
    }

    /// nil instead of false: while the mode is off, the file stays as it was.
    private func syncMinimalEnergy() {
        let want: Bool? = minimalEnergy ? true : nil
        if config.minimalEnergy != want { config.minimalEnergy = want }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        saveWork = nil
        guard installed else { return }
        write()
    }

    private func write() {
        guard !previewing, let d = try? JSONEncoder().encode(config.sanitized()) else { return }
        do { try d.write(to: URL(fileURLWithPath: ChargePaths.config), options: .atomic) }
        catch { self.error = "Couldn't save the charge settings: \(error.localizedDescription)"; return }
        // Wake the helper so the new limit applies right away, not on the next tick. An older helper doesn't wait for the notification; the folder is enough for it.
        notify_post(ChargePaths.configChanged)
        // The helper responds in a moment: read its status without waiting for the timer (5 s in the popover, 45 s in the background)
        statusFollowUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusFollowUp = nil; self?.readStatus() }
        statusFollowUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// For previews and tests: inject a status without the helper.
    func setPreview(installed: Bool, status: ChargeStatus?) {
        previewing = true
        timer?.invalidate()
        self.installed = installed
        self.status = status
    }

    // MARK: - Installation

    func install() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(ChargePaths.label)")
        guard FileManager.default.fileExists(atPath: helper.path) else { error = "The helper is missing from the app bundle."; return }
        // The app lives in ~/Desktop, which is TCC-protected: a root script may not be able to read the bundle.
        // So we copy the helper to a temp folder ourselves (the app may read its own bundle).
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(ChargePaths.label)-\(UUID().uuidString)")
        do { try FileManager.default.copyItem(at: helper, to: staged) }
        catch { self.error = "Couldn't stage the helper: \(error.localizedDescription)"; return }
        runAsAdmin(ChargeInstall.script(helperPath: staged.path, uid: getuid())) { [weak self] ok in
            try? FileManager.default.removeItem(at: staged)
            guard let self else { return }
            self.installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
            self.checkHelper()
            // Pick up the migrated settings first, otherwise values from memory would overwrite them
            self.saveWork?.cancel()
            self.saveWork = nil
            self.readStatus()
            if ok && self.installed { self.config.enabled = true; self.save() }
            else if ok { self.error = "The helper didn't install — no daemon file was written." }
        }
    }

    func uninstall() {
        // bootout sends SIGTERM — the helper restores normal charging itself before exiting
        let script = """
        launchctl bootout system/\(ChargePaths.label) 2>/dev/null || true
        rm -f '\(ChargePaths.daemonPlist)' '\(ChargePaths.helperBinary)' '\(ChargePaths.status)'
        """
        runAsAdmin(script) { [weak self] ok in
            guard let self else { return }
            self.installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
            self.checkHelper()
            self.status = nil
            // Without the helper, the cask brings it back after an upgrade only if the limit is on: one removed by hand must not come back
            if ok && !self.installed {
                self.saveWork?.cancel()
                self.saveWork = nil
                self.config.enabled = false
                self.write()
            }
        }
    }

    /// osascript as a separate process: NSAppleScript off the main thread is unreliable and silently does nothing.
    private func runAsAdmin(_ script: String, done: @escaping (Bool) -> Void) {
        busy = true; error = nil
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lynx-battery-\(UUID().uuidString).sh")
        do { try script.write(to: tmp, atomically: true, encoding: .utf8) }
        catch { busy = false; self.error = "Couldn't write the install script."; done(false); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \"/bin/sh '\(tmp.path)'\" with administrator privileges with prompt \"Lynx Battery wants to install its charge-limit helper.\""]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: tmp)
            NSLog("Lynx Battery admin script exit \(proc.terminationStatus): \(msg)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                let ok = proc.terminationStatus == 0
                if !ok && !msg.contains("-128") {   // -128 — the user clicked "Cancel"
                    self.error = msg.isEmpty ? "The admin script failed." : msg
                }
                done(ok)
            }
        }
        do { try p.run() } catch { busy = false; self.error = "Couldn't start osascript."; done(false) }
    }
}
