import Foundation
import notify

/// Апка пише налаштування ліміту, root-хелпер їх виконує й звітує стан.
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
    /// Мінімальне споживання: у фоні стан читає лише оновлення моделі, власний таймер зайвий. Хелпер дізнається через налаштування.
    var minimalEnergy = false { didSet { syncMinimalEnergy() } }

    init() {
        installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
        if let d = FileManager.default.contents(atPath: ChargePaths.config),
           let c = try? JSONDecoder().decode(ChargeConfig.self, from: d) { config = c.sanitized() }
        readStatus()
        setVisible(false)
    }

    /// Хелпер пише стан раз на 15 с, а бачити його можна лише в поповері: у фоні читаємо рідко.
    func setVisible(_ visible: Bool) {
        guard !previewing else { return }
        timer?.invalidate(); timer = nil
        if visible || !minimalEnergy {
            timer = Timer.scheduledTimer(withTimeInterval: visible ? 5 : 45, repeats: true) { [weak self] _ in self?.readStatus() }
            timer?.tolerance = visible ? 1 : 10
        }
        if visible { readStatus(); checkHelper() }
    }

    /// Хелпер живий, якщо писав стан не пізніше хвилини тому.
    var helperAlive: Bool { status.map { Date().timeIntervalSince($0.updated) < ChargeStatus.aliveWindow } ?? false }
    var adapterOnly: Bool { status.map { !$0.capabilities.contains("charge-inhibit") && $0.capabilities.contains("adapter") } ?? false }
    /// Ліміт тримається від розетки: лише цей стан малює іконку синім.
    var holdingOnWall: Bool { helperAlive && status?.wallHold == true }
    /// Межа в прошивці діє й уві сні, тож не спати до ліміту не потрібно.
    var limitWorksAsleep: Bool { status?.capabilities.contains("firmware-limit") ?? false }
    /// Розряд до ліміту можливий, лише коли є обидва важелі.
    var canDischarge: Bool { status.map { $0.capabilities.contains("charge-inhibit") && $0.capabilities.contains("adapter") } ?? false }

    /// Ліміт задано у відсотку, який показує апка: при зміні режиму переводимо число, а фізична межа лишається та сама.
    func adoptScale(_ scale: ChargeScale, _ raw: BatterySnapshot) {
        let old = config.scale ?? .trueCharge
        if config.scale == scale { return }
        let wasTop = config.limit >= old.top(raw)
        config.limit = wasTop ? scale.top(raw) : min(scale.top(raw), old.convert(config.limit, to: scale, raw))
        config.scale = scale
    }

    /// Хелпер у бандлі новіший за встановлений — треба перевстановити (з паролем).
    /// Читає обидва файли цілком, тож не з body вкладки, а при відкритті поповера й після встановлення.
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
        // Файл міг змінити хелпер (скидає Top Up після 100 %) чи інша копія апки: підхоплюємо все й не пишемо назад,
        // інакше застарілі значення з пам'яті затруть файл. Поки є незбережена зміна, вона новіша за файл.
        if saveWork == nil, let d = FileManager.default.contents(atPath: ChargePaths.config),
           let c = try? JSONDecoder().decode(ChargeConfig.self, from: d), c.sanitized() != config {
            loadingFromFile = true
            config = c.sanitized()
            loadingFromFile = false
            // Перемикач живе в налаштуваннях апки: файл міг переписати старіший хелпер, який цього поля не знає
            syncMinimalEnergy()
        }
    }

    /// nil замість false: поки режим вимкнено, файл лишається таким, як був.
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
        // Будимо хелпер, щоб новий ліміт діяв одразу, а не за наступним tick. Старіший хелпер сповіщення не чекає, йому вистачає теки.
        notify_post(ChargePaths.configChanged)
        // Хелпер відповідає за мить: читаємо його стан, не чекаючи таймера (5 с у поповері, 45 с у фоні)
        statusFollowUp?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusFollowUp = nil; self?.readStatus() }
        statusFollowUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Для прев'ю й тестів: підставити стан без хелпера.
    func setPreview(installed: Bool, status: ChargeStatus?) {
        previewing = true
        timer?.invalidate()
        self.installed = installed
        self.status = status
    }

    // MARK: - Встановлення

    func install() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/\(ChargePaths.label)")
        guard FileManager.default.fileExists(atPath: helper.path) else { error = "The helper is missing from the app bundle."; return }
        // Апка лежить у ~/Desktop, а він під захистом TCC: root-скрипт може не прочитати бандл.
        // Тож копіюємо хелпер у тимчасову теку самі (свій бандл апці читати можна).
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(ChargePaths.label)-\(UUID().uuidString)")
        do { try FileManager.default.copyItem(at: helper, to: staged) }
        catch { self.error = "Couldn't stage the helper: \(error.localizedDescription)"; return }
        runAsAdmin(ChargeInstall.script(helperPath: staged.path, uid: getuid())) { [weak self] ok in
            try? FileManager.default.removeItem(at: staged)
            guard let self else { return }
            self.installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
            self.checkHelper()
            // Спершу підхоплюємо перенесені налаштування, інакше значення з пам'яті затруть їх
            self.saveWork?.cancel()
            self.saveWork = nil
            self.readStatus()
            if ok && self.installed { self.config.enabled = true; self.save() }
            else if ok { self.error = "The helper didn't install — no daemon file was written." }
        }
    }

    func uninstall() {
        // bootout шле SIGTERM — хелпер сам повертає звичайну зарядку перед виходом
        let script = """
        launchctl bootout system/\(ChargePaths.label) 2>/dev/null || true
        rm -f '\(ChargePaths.daemonPlist)' '\(ChargePaths.helperBinary)' '\(ChargePaths.status)'
        """
        runAsAdmin(script) { [weak self] ok in
            guard let self else { return }
            self.installed = FileManager.default.fileExists(atPath: ChargePaths.daemonPlist)
            self.checkHelper()
            self.status = nil
            // Без хелпера cask повертає його після оновлення, лише якщо ліміт увімкнений: знятий вручну не має повернутись
            if ok && !self.installed {
                self.saveWork?.cancel()
                self.saveWork = nil
                self.config.enabled = false
                self.write()
            }
        }
    }

    /// osascript окремим процесом: NSAppleScript поза головним потоком ненадійний і мовчки нічого не робить.
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
                if !ok && !msg.contains("-128") {   // -128 — користувач натиснув «Скасувати»
                    self.error = msg.isEmpty ? "The admin script failed." : msg
                }
                done(ok)
            }
        }
        do { try p.run() } catch { busy = false; self.error = "Couldn't start osascript."; done(false) }
    }
}
