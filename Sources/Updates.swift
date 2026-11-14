import AppKit
import Combine

/// Every few hours asks GitHub for the latest release. No token and no user data whatsoever:
/// only a User-Agent with the app version and an ETag, so an unchanged response doesn't count against the limit.
final class UpdateChecker: ObservableObject {
    /// The last known release (from the network or the cache). Whether it's newer is decided by UpdatePolicy.
    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var dismissed: String? { didSet { d.set(dismissed, forKey: Keys.dismissed) } }
    /// A new release not yet alerted about. Called on the main thread.
    var onRelease: ((ReleaseInfo) -> Void)?
    /// Start auto-install; true — started, then no new-version alert is needed.
    var autoInstall: ((ReleaseInfo) -> Bool)?

    let current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private let d = UserDefaults.standard
    private var timer: Timer?
    private var inFlight = false
    private var bag = Set<AnyCancellable>()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral   // no cookies and no disk cache: we handle the ETag ourselves
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

    /// Banner in the popover.
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
        // After sleep the timer may have missed the deadline — check right away if it's due
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self?.checkIfDue() }
        }
    }

    private func apply(_ on: Bool) {
        timer?.invalidate(); timer = nil
        objectWillChange.send()   // the banner appears or disappears along with the toggle
        guard on else { return }
        // Every launch (and turning checks on) asks GitHub right away, whenever the last check was: a quit and reopen
        // is how people look for an update. A few seconds in, not at the moment of launch, so the network is up.
        // The cache from the previous run alerts even without a network. With the ETag an unchanged release costs a 304.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.announceIfNeeded()
            self?.check()
        }
        // The timer only wakes the deadline check: that way the 8 hours count through sleep too
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer?.tolerance = 300
    }

    private func checkIfDue() {
        guard Settings.shared.updateCheck else { return }
        let last = d.object(forKey: Keys.checkedAt) as? Date
        // An app restart doesn't reset the deadline: no more than once an hour, even if the cache is empty
        guard UpdatePolicy.isDue(lastCheck: last, now: Date(), interval: latest == nil ? UpdatePolicy.minInterval : UpdatePolicy.interval) else { return }
        check()
    }

    /// Request to GitHub. Offline, rate limit, any error — quietly wait for next time.
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
        guard let resp else { return }   // offline: don't move the deadline, try again in half an hour
        d.set(Date(), forKey: Keys.checkedAt)
        switch resp.statusCode {
        case 304:
            break   // nothing new, the cache is current
        case 200:
            guard let data, let r = UpdatePolicy.parse(data) else { return }
            d.set(resp.value(forHTTPHeaderField: "ETag"), forKey: Keys.etag)
            d.set(try? JSONEncoder().encode(r), forKey: Keys.release)
            if r != latest { latest = r }
        case 404:
            // No release at all (or all are prereleases): forget the old one
            d.removeObject(forKey: Keys.etag); d.removeObject(forKey: Keys.release)
            latest = nil
        default:
            return   // 403/429 — rate limit; wait for the regular deadline
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
