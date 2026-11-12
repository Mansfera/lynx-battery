import Foundation

/// Запит на встановлення: апка кладе його й DMG у теку хелпера. Хелпер нічому тут не вірить і все перевіряє сам.
struct UpdateRequest: Codable, Equatable {
    var id: String
    var version: String
    var dmg: String          // лише ім'я файлу в теці запиту
    var sha256: String
    var signature: String    // base64
    var app: String          // яку копію апки замінити
    var requestedAt: Date
}

struct UpdateResult: Codable, Equatable {
    var id: String
    var version: String
    var ok: Bool
    var message: String
    var finishedAt = Date()
}

struct UpdateFailure: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

/// Перевірка й заміна апки. Спільне для root-хелпера, апки (без хелпера) і тестів; тека призначення — параметр.
enum UpdateInstall {
    static let requestName = "update-request.json"
    static let resultName = "update-result.json"
    static let appName = "Lynx Battery.app"
    static let maxDMG = 200 << 20
    static let maxRequest = 16 << 10
    static let maxAge: TimeInterval = 600

    /// Куди хелпер може ставити апку: /Applications або ~/Applications будь-якого користувача.
    static func helperAllowedParent(_ parent: String) -> Bool {
        if parent == "/Applications" { return true }
        let c = parent.split(separator: "/", omittingEmptySubsequences: false)
        return c.count == 4 && c[0].isEmpty && c[1] == "Users" && !c[2].isEmpty && c[2] != "." && c[2] != ".." && c[3] == "Applications"
    }

    static func isValidDMGName(_ name: String) -> Bool {
        guard name.hasPrefix("Lynx-Battery-"), name.hasSuffix(".dmg") else { return false }
        let v = name.dropFirst("Lynx-Battery-".count).dropLast(".dmg".count)
        return !v.isEmpty && v.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } && AppVersion(String(v)) != nil
    }

    static func encode(_ v: some Encodable) -> Data? {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        return try? e.encode(v)
    }

    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) -> T? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(t, from: d)
    }

    /// Читає звичайний файл, не йдучи за символьним посиланням, і не більше max байтів.
    static func readFile(_ path: String, max: Int) throws -> Data {
        let name = (path as NSString).lastPathComponent
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            throw UpdateFailure(errno == ELOOP ? "\(name) is a symlink" : "can't open \(name): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw UpdateFailure("\(name) isn't a regular file") }
        guard st.st_size <= max else { throw UpdateFailure("\(name) is too large") }
        let d = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: max + 1) ?? Data()
        guard d.count <= max else { throw UpdateFailure("\(name) is too large") }
        return d
    }

    /// Запит читаємо один раз: файл зникає, хай що в ньому.
    static func takeRequest(dir: String) throws -> UpdateRequest {
        let path = dir + "/" + requestName
        defer { unlink(path) }
        guard let r = decode(UpdateRequest.self, try readFile(path, max: maxRequest)) else { throw UpdateFailure("the request isn't valid") }
        return r
    }

    static func bundleInfo(_ app: String) throws -> (id: String, version: String) {
        let d = try readFile(app + "/Contents/Info.plist", max: 1 << 20)
        guard let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let id = p["CFBundleIdentifier"] as? String, let v = p["CFBundleShortVersionString"] as? String
        else { throw UpdateFailure("\((app as NSString).lastPathComponent) has no readable Info.plist") }
        return (id, v)
    }

    /// Шлях, який замінюємо: абсолютний, без «..» і символьних посилань, у дозволеній теці, і там справді Lynx Battery.
    static func validateTarget(_ path: String, allowedParent: (String) -> Bool) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), path.utf8.count < 1024, !path.contains("\0"), path.hasSuffix(".app"),
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw UpdateFailure("the app path isn't valid") }
        guard let real = realpath(path, nil) else { throw UpdateFailure("the app isn't there") }
        defer { free(real) }
        guard String(cString: real) == path else { throw UpdateFailure("the app path goes through a symlink") }
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw UpdateFailure("the app isn't a folder") }
        guard allowedParent((path as NSString).deletingLastPathComponent) else { throw UpdateFailure("the app isn't in an Applications folder") }
        guard try bundleInfo(path).id == UpdateSignature.bundleID else { throw UpdateFailure("the app at that path isn't Lynx Battery") }
    }

    /// Бандл — лише теки й звичайні файли; посилання тільки відносні й лише всередину. Без setuid.
    static func checkBundleTree(_ root: String) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { throw UpdateFailure("can't read the new app") }
        var count = 0
        while let rel = e.nextObject() as? String {
            count += 1
            guard count < 20000 else { throw UpdateFailure("the new app has too many files") }
            let full = root + "/" + rel
            var st = stat()
            guard lstat(full, &st) == 0 else { throw UpdateFailure("can't read \(rel)") }
            guard st.st_mode & (S_ISUID | S_ISGID) == 0 else { throw UpdateFailure("\(rel) is setuid") }
            switch st.st_mode & S_IFMT {
            case S_IFREG, S_IFDIR: continue
            case S_IFLNK:
                let dest = (try? fm.destinationOfSymbolicLink(atPath: full)) ?? "/"
                guard symlinkStaysInside(rel: rel, dest: dest) else { throw UpdateFailure("\(rel) links outside the app") }
            default:
                throw UpdateFailure("\(rel) isn't a file or folder")
            }
        }
    }

    /// Ціль посилання: спершу лише «..», далі лише звичайні імена — тоді фізичний шлях збігається з лексичним.
    static func symlinkStaysInside(rel: String, dest: String) -> Bool {
        guard !dest.isEmpty, !dest.hasPrefix("/") else { return false }
        var depth = rel.split(separator: "/").count - 1
        var descending = false
        for c in dest.split(separator: "/", omittingEmptySubsequences: false) {
            if c == ".." {
                guard !descending, depth > 0 else { return false }
                depth -= 1
            } else {
                guard !c.isEmpty, c != "." else { return false }
                descending = true
            }
        }
        return true
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: e, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateFailure("\((exe as NSString).lastPathComponent) failed: \(msg.isEmpty ? "exit \(p.terminationStatus)" : msg)")
        }
        return o
    }

    /// Повна установка. requestDir — звідки брати DMG, workRoot — приватна тека для копії й точки монтування.
    static func install(_ r: UpdateRequest, requestDir: String, workRoot: String, publicKey: String,
                        allowedParent: (String) -> Bool, now: Date = Date(), log: (String) -> Void) throws {
        let dmgPath = requestDir + "/" + r.dmg
        defer { if isValidDMGName(r.dmg) { unlink(dmgPath) } }
        log("update \(r.version): request \(r.id) for \(r.app)")

        guard r.requestedAt > now - maxAge, r.requestedAt < now + 60 else { throw UpdateFailure("the request is stale") }
        guard !publicKey.isEmpty, UpdateSignature.publicKey(publicKey) != nil else { throw UpdateFailure("this build has no update key") }
        guard isValidDMGName(r.dmg) else { throw UpdateFailure("the DMG name isn't valid") }
        guard let v = AppVersion(r.version), !v.prerelease else { throw UpdateFailure("the version isn't valid") }
        guard UpdateSignature.isSHA256(r.sha256), let sig = Data(base64Encoded: r.signature), sig.count == UpdateSignature.signatureSize
        else { throw UpdateFailure("the checksum or signature isn't valid") }

        try validateTarget(r.app, allowedParent: allowedParent)
        let installed = try bundleInfo(r.app).version
        guard UpdatePolicy.isNewer(r.version, than: installed) else { throw UpdateFailure("\(r.version) isn't newer than the installed \(installed)") }
        log("update \(r.version): target ok, installed \(installed)")

        var tmpl = Array((workRoot + "/lynx-update.XXXXXX").utf8CString)
        guard let wp = mkdtemp(&tmpl) else { throw UpdateFailure("can't make a work folder") }
        let work = String(cString: wp)
        defer { try? FileManager.default.removeItem(atPath: work) }

        // Своя копія в приватній теці: файл у теці запиту можна підмінити між перевіркою й монтуванням
        let data = try readFile(dmgPath, max: maxDMG)
        let dmg = work + "/update.dmg"
        guard FileManager.default.createFile(atPath: dmg, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw UpdateFailure("can't copy the DMG")
        }
        let sha = UpdateSignature.sha256(data)
        guard sha == r.sha256.lowercased() else { throw UpdateFailure("the DMG checksum doesn't match") }
        guard UpdateSignature.verify(signature: sig, sha256: sha, version: r.version, publicKey: publicKey) else {
            throw UpdateFailure("the DMG signature isn't valid")
        }
        log("update \(r.version): checksum and signature ok")

        let mounts = work + "/mnt"
        try FileManager.default.createDirectory(atPath: mounts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let plist = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mounts, "-plist", dmg])
        guard let p = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let mount = (p["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first
        else { throw UpdateFailure("the DMG didn't mount") }
        defer {
            if (try? run("/usr/bin/hdiutil", ["detach", mount, "-force"])) == nil { log("update \(r.version): couldn't detach \(mount)") }
        }
        log("update \(r.version): mounted read-only")

        let src = mount + "/" + appName
        var st = stat()
        guard lstat(src, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { throw UpdateFailure("the DMG has no \(appName)") }
        try checkBundleTree(src)
        let info = try bundleInfo(src)
        guard info.id == UpdateSignature.bundleID else { throw UpdateFailure("the new app is \(info.id), not Lynx Battery") }
        guard AppVersion(info.version) == v else { throw UpdateFailure("the new app is \(info.version), the release says \(r.version)") }
        guard UpdatePolicy.isNewer(info.version, than: installed) else { throw UpdateFailure("\(info.version) isn't newer than \(installed)") }
        log("update \(r.version): bundle ok")

        // Поруч зі старою, на тому ж томі: тоді заміна — один атомарний обмін
        let parent = (r.app as NSString).deletingLastPathComponent
        let staged = parent + "/." + (r.app as NSString).lastPathComponent + ".update-" + UUID().uuidString.prefix(8)
        try? FileManager.default.removeItem(atPath: staged)
        defer { try? FileManager.default.removeItem(atPath: staged) }
        try run("/usr/bin/ditto", [src, staged])
        if getuid() == 0 {
            var old = stat()
            guard lstat(r.app, &old) == 0 else { throw UpdateFailure("the app vanished") }
            try run("/usr/sbin/chown", ["-R", "-h", "\(old.st_uid):\(old.st_gid)", staged])
        }
        _ = try? run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", staged])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged])
        let copied = try bundleInfo(staged)
        guard copied.id == info.id, copied.version == info.version else { throw UpdateFailure("the copy doesn't match the DMG") }
        log("update \(r.version): copied and code signature intact")

        guard renamex_np(staged, r.app, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure("couldn't swap the app: \(String(cString: strerror(errno)))")
        }
        log("update \(r.version): installed at \(r.app)")
        // Стара версія тепер на місці staged — її прибирає defer
    }

    /// Те, що робить хелпер на сповіщення: забрати запит, встановити, записати відповідь.
    @discardableResult
    static func handleRequest(dir: String, workRoot: String, publicKey: String,
                              allowedParent: (String) -> Bool, log: (String) -> Void) -> UpdateResult? {
        let r: UpdateRequest
        do { r = try takeRequest(dir: dir) } catch { log("update: \(error)"); return nil }
        var result = UpdateResult(id: r.id, version: r.version, ok: true, message: "Updated to \(r.version)")
        do {
            try install(r, requestDir: dir, workRoot: workRoot, publicKey: publicKey, allowedParent: allowedParent, log: log)
        } catch {
            log("update \(r.version): refused — \(error)")
            result.ok = false
            result.message = "\(error)"
        }
        let path = dir + "/" + resultName
        unlink(path)
        if let d = encode(result) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        return result
    }
}
