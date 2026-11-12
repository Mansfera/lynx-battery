import AppKit
import notify

/// Installing an update: download the DMG and signature, verify them, hand them to the helper (no password) or replace the app itself.
/// The helper checks everything again: it doesn't trust the app.
final class UpdateInstaller: ObservableObject {
    enum Phase: Equatable { case idle, working(String), done(String), failed(String) }
    @Published private(set) var phase: Phase = .idle
    /// Versions already tried this launch: automatic install happens only once per version.
    private(set) var attempted: Set<String> = []
    weak var charge: ChargeControl?
    var onInstalled: ((String) -> Void)?
    var onFailed: ((ReleaseInfo) -> Void)?

    let keyPresent = UpdateSignature.hasUsableKey(UpdateKey.trusted)
    let homebrew = UpdatePolicy.isHomebrewInstall()
    static let brewCommand = "brew upgrade --cask mansfera/tap/lynx-battery"

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        return URLSession(configuration: c)
    }()

    var busy: Bool {
        switch phase {
        case .working, .done: true
        default: false
        }
    }

    func canInstall(_ r: ReleaseInfo?) -> Bool { UpdatePolicy.canInstall(r, keyPresent: keyPresent, homebrew: homebrew) }

    func install(_ r: ReleaseInfo) {
        guard !busy else { return }
        guard canInstall(r) else { NSWorkspace.shared.open(r.url); return }
        attempted.insert(r.version)
        phase = .working("Downloading \(r.version)…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.run(r)
                self.phase = .done(r.version)
                self.onInstalled?(r.version)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.relaunch() }
            } catch {
                let msg = "\(error)"
                self.phase = .failed(msg.prefix(1).uppercased() + msg.dropFirst())
                NSLog("Lynx Battery: update \(r.version) failed — \(msg)")
                self.onFailed?(r)
            }
        }
    }

    private enum Route { case helper, inProcess, none(String) }

    private func route(_ app: String) -> Route {
        let parent = (app as NSString).deletingLastPathComponent
        if let c = charge, c.helperAlive, c.status?.capabilities.contains("app-update") == true, UpdateInstall.helperAllowedParent(parent) {
            return .helper
        }
        let fm = FileManager.default
        if fm.isWritableFile(atPath: parent) && fm.isWritableFile(atPath: app) { return .inProcess }
        return .none("can't replace the app in \(parent) without the charge-limit helper. Install it from the Charge tab, or download the update")
    }

    @MainActor
    private func run(_ r: ReleaseInfo) async throws {
        guard let dmgURL = r.dmgURL, let sigURL = r.sigURL, let digest = r.dmgSHA256 else { throw UpdateFailure("the release has no signed DMG") }
        let dmg = try await fetch(dmgURL, max: UpdateInstall.maxDMG)
        let sigFile = try await fetch(sigURL, max: UpdateSignature.maxSignatureFile)
        let sha = UpdateSignature.sha256(dmg)
        guard sha == digest.lowercased() else { throw UpdateFailure("the download doesn't match GitHub's checksum") }
        guard UpdateSignature.verify(signatureFile: sigFile, sha256: sha, version: r.version, trusted: UpdateKey.trusted) != nil,
              let sig = String(data: sigFile, encoding: .utf8)
        else { throw UpdateFailure("the update's signature isn't valid") }

        let app = Bundle.main.bundleURL.standardizedFileURL.path
        let req = UpdateRequest(id: UUID().uuidString, version: r.version, dmg: "Lynx-Battery-\(r.version).dmg", sha256: sha,
                                signature: sig, app: app, requestedAt: Date())
        phase = .working("Installing \(r.version)…")
        switch route(app) {
        case .helper: try await viaHelper(req, dmg)
        case .inProcess: try await inProcess(req, dmg)
        case .none(let why): throw UpdateFailure(why)
        }
    }

    private func fetch(_ url: URL, max: Int) async throws -> Data {
        guard url.scheme == "https" else { throw UpdateFailure("the download link isn't HTTPS") }
        var req = URLRequest(url: url)
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        req.setValue("LynxBattery/\(v)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateFailure("GitHub answered \(code) for \(url.lastPathComponent)") }
        guard data.count <= max else { throw UpdateFailure("\(url.lastPathComponent) is too large") }
        return data
    }

    /// Put the DMG and request in the helper's folder and wake it. The answer is a file with the same id.
    @MainActor
    private func viaHelper(_ req: UpdateRequest, _ dmg: Data) async throws {
        let dir = ChargePaths.dir
        let dmgPath = dir + "/" + req.dmg, reqPath = dir + "/" + UpdateInstall.requestName, resPath = dir + "/" + UpdateInstall.resultName
        try? FileManager.default.removeItem(atPath: resPath)
        guard let body = UpdateInstall.encode(req) else { throw UpdateFailure("couldn't write the request") }
        try dmg.write(to: URL(fileURLWithPath: dmgPath), options: .atomic)
        try body.write(to: URL(fileURLWithPath: reqPath), options: .atomic)
        notify_post(ChargePaths.updateRequested)
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let d = FileManager.default.contents(atPath: resPath),
                  let res = UpdateInstall.decode(UpdateResult.self, d), res.id == req.id else { continue }
            try? FileManager.default.removeItem(atPath: resPath)
            guard res.ok else { throw UpdateFailure("the helper refused: \(res.message)") }
            return
        }
        try? FileManager.default.removeItem(atPath: reqPath)
        try? FileManager.default.removeItem(atPath: dmgPath)
        throw UpdateFailure("the helper didn't answer")
    }

    /// The app's folder is ours: the same checks, just without root.
    private func inProcess(_ req: UpdateRequest, _ dmg: Data) async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lynx-update-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try dmg.write(to: URL(fileURLWithPath: tmp + "/" + req.dmg))
        try await Task.detached {
            try UpdateInstall.install(req, requestDir: tmp, workRoot: tmp, trusted: UpdateKey.trusted,
                                      allowedParent: { _ in true }, log: { NSLog("Lynx Battery: \($0)") })
        }.value
    }

    /// The app won't launch while this copy is alive (one instance per bundle), so a separate process waits for it to exit and opens it as the user.
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
