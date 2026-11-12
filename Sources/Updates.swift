import AppKit
import Combine

/// Раз на кілька годин питає GitHub про останній реліз. Без токена й без жодних даних про користувача:
/// лише User-Agent з версією апки та ETag, щоб незмінна відповідь не рахувалась у ліміт.
final class UpdateChecker: ObservableObject {
    /// Останній відомий реліз (з мережі або з кешу). Чи він новіший — вирішує UpdatePolicy.
    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var dismissed: String? { didSet { d.set(dismissed, forKey: Keys.dismissed) } }
    /// Новий реліз, про який ще не сповіщали. Викликається на головному потоці.
    var onRelease: ((ReleaseInfo) -> Void)?
    /// Почати автовстановлення; true — почали, тоді сповіщення про нову версію не треба.
    var autoInstall: ((ReleaseInfo) -> Bool)?

    let current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let d = UserDefaults.standard
    private var timer: Timer?
    private var inFlight = false
    private var bag = Set<AnyCancellable>()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // без куків і дискового кешу: ETag ведемо самі
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private enum Keys {
        static let etag = "updateETag", release = "updateRelease", checkedAt = "updateCheckedAt"
        static let dismissed = "updateDismissed", alerted = "updateAlerted"
    }

    init() {
        latest = d.data(forKey: Keys.release).flatMap { try? JSONDecoder().decode(ReleaseInfo.self, from: $0) }
        dismissed = d.string(forKey: Keys.dismissed)
    }

    /// Банер у поповері.
    var available: ReleaseInfo? {
        UpdatePolicy.showBanner(latest, current: current, checkOn: Settings.shared.updateCheck, dismissed: dismissed) ? latest : nil
    }

    func dismissBanner() { dismissed = latest?.version }

    func markAlerted(_ r: ReleaseInfo) { d.set(r.version, forKey: Keys.alerted) }
    var alerted: String? { d.string(forKey: Keys.alerted) }

    func start() {
        Settings.shared.$updateCheck.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.apply(on) }.store(in: &bag)
        Settings.shared.$updateAlert.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in if on { self?.announceIfNeeded() } }.store(in: &bag)
        Settings.shared.$autoInstall.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] on in if on { self?.announceIfNeeded() } }.store(in: &bag)
        // Після сну таймер міг проспати строк — перевіряємо одразу, якщо пора
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.checkIfDue() }
        }
    }

    private func apply(_ on: Bool) {
        timer?.invalidate(); timer = nil
        objectWillChange.send()   // банер з'являється або зникає разом із перемикачем
        guard on else { return }
        // Не в момент старту. Кеш з минулого запуску сповіщає й без мережі
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.announceIfNeeded()
            self?.checkIfDue()
        }
        // Таймер лише будить перевірку строку: так 8 годин рахуються й через сон
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer?.tolerance = 300
    }

    private func checkIfDue() {
        guard Settings.shared.updateCheck else { return }
        let last = d.object(forKey: Keys.checkedAt) as? Date
        // Перезапуск апки не скидає строк: не частіше ніж раз на годину, навіть якщо кеш порожній
        guard UpdatePolicy.isDue(lastCheck: last, now: Date(), interval: latest == nil ? UpdatePolicy.minInterval : UpdatePolicy.interval) else { return }
        check()
    }

    /// Запит до GitHub. Офлайн, ліміт, будь-яка помилка — тихо чекаємо наступного разу.
    func check() {
        guard !inFlight, Settings.shared.updateCheck else { return }
        inFlight = true
        var req = URLRequest(url: UpdatePolicy.latestURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("LynxBattery/\(current)", forHTTPHeaderField: "User-Agent")
        if latest != nil, let etag = d.string(forKey: Keys.etag) { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        session.dataTask(with: req) { [weak self] data, resp, _ in
            DispatchQueue.main.async { self?.handle(data, resp as? HTTPURLResponse) }
        }.resume()
    }

    private func handle(_ data: Data?, _ resp: HTTPURLResponse?) {
        inFlight = false
        guard let resp else { return }   // офлайн: строк не зсуваємо, спробуємо за пів години
        d.set(Date(), forKey: Keys.checkedAt)
        switch resp.statusCode {
        case 304:
            break   // нічого нового, кеш актуальний
        case 200:
            guard let data, let r = UpdatePolicy.parse(data) else { return }
            d.set(resp.value(forHTTPHeaderField: "ETag"), forKey: Keys.etag)
            d.set(try? JSONEncoder().encode(r), forKey: Keys.release)
            if r != latest { latest = r }
        case 404:
            // Жодного релізу (або всі — пререлізи): забуваємо старий
            d.removeObject(forKey: Keys.etag); d.removeObject(forKey: Keys.release)
            latest = nil
        default:
            return   // 403/429 — ліміт; чекаємо звичайного строку
        }
        announceIfNeeded()
    }

    func announceIfNeeded() {
        let s = Settings.shared
        if let r = latest, autoInstall?(r) == true { return }
        guard let r = latest, UpdatePolicy.shouldAlert(r, current: current, checkOn: s.updateCheck, alertsOn: s.updateAlert, alerted: alerted) else { return }
        markAlerted(r)
        onRelease?(r)
    }
}
