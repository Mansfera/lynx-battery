import Foundation
import CryptoKit

/// A release key: an OpenSSH FIDO2 key (`sk-ssh-ed25519@openssh.com`) living on a YubiKey.
/// `key` is the type and base64 blob from the key's .pub file; the blob includes the application string.
struct TrustedUpdateKey: Equatable {
    let label: String
    let key: String
}

/// Release signature: an SSHSIG (`ssh-keygen -Y sign`) over a line with the bundle id, version and DMG sha256.
/// The version stops an old signed DMG from passing as a newer one; the sha256 ties the signature to the file itself.
/// Formats: OpenSSH PROTOCOL.sshsig and PROTOCOL.u2f.
enum UpdateSignature {
    static let bundleID = "com.mansfera.lynxbattery"
    static let namespace = "lynx-battery-update"
    static let application = "ssh:lynx-release"
    static let skKeyType = "sk-ssh-ed25519@openssh.com"
    static let hashAlgorithm = "sha512"
    static let flagUserPresent: UInt8 = 0x01
    static let flagUserVerified: UInt8 = 0x04
    static let maxSignatureFile = 4096

    static func isSHA256(_ s: String) -> Bool { UpdatePolicy.isSHA256(s) }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// nil when the version is a prerelease or unparseable, or the sha256 isn't in the right format.
    static func message(sha256: String, version: String, bundleID: String = bundleID) -> Data? {
        guard let v = AppVersion(version), !v.prerelease, isSHA256(sha256) else { return nil }
        return Data("lynx-battery-update/1\n\(bundleID)\n\(v.description)\n\(sha256.lowercased())\n".utf8)
    }

    // MARK: SSH wire format

    struct Reader {
        private let d: [UInt8]
        private var i = 0
        init(_ data: Data) { d = [UInt8](data) }
        var atEnd: Bool { i == d.count }

        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, n <= d.count - i else { return nil }
            defer { i += n }
            return Data(d[i..<i + n])
        }
        mutating func byte() -> UInt8? { bytes(1)?.first }
        mutating func uint32() -> UInt32? {
            guard let b = bytes(4) else { return nil }
            return b.reduce(UInt32(0)) { acc, x in acc << 8 | UInt32(x) }
        }
        mutating func string() -> Data? {
            guard let n = uint32(), n <= 1 << 16 else { return nil }
            return bytes(Int(n))
        }
        mutating func text() -> String? { string().flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func uint32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
    static func string(_ d: Data) -> Data { uint32(UInt32(d.count)) + d }
    static func string(_ s: String) -> Data { string(Data(s.utf8)) }

    // MARK: Keys

    struct SKPublicKey: Equatable {
        let blob: Data
        let key: Data
        let application: String
    }

    /// Public key blob: string type, string ed25519 key (32 bytes), string application. Only sk-ed25519 is accepted.
    static func parseSKKey(blob: Data) -> SKPublicKey? {
        var r = Reader(blob)
        guard r.text() == skKeyType, let k = r.string(), k.count == 32, let app = r.text(), r.atEnd,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: k)) != nil else { return nil }
        return SKPublicKey(blob: blob, key: k, application: app)
    }

    /// A .pub line: "sk-ssh-ed25519@openssh.com AAAA... [comment]".
    static func parseSKKey(line: String) -> SKPublicKey? {
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
        guard f.count >= 2, f[0] == skKeyType, let blob = Data(base64Encoded: String(f[1])),
              let k = parseSKKey(blob: blob) else { return nil }
        return k
    }

    /// A trusted key must be an sk-ed25519 key made for releases, not some other key on the same YubiKey.
    static func isUsable(_ t: TrustedUpdateKey) -> Bool { parseSKKey(line: t.key)?.application == application }

    static func hasUsableKey(_ trusted: [TrustedUpdateKey]) -> Bool { trusted.contains(where: isUsable) }

    // MARK: SSHSIG

    struct SSHSig {
        let publicKey: Data
        let namespace: String
        let reserved: Data
        let hashAlgorithm: String
        let signature: Data
    }

    static let armorBegin = "-----BEGIN SSH SIGNATURE-----"
    static let armorEnd = "-----END SSH SIGNATURE-----"

    static func dearmor(_ d: Data) -> Data? {
        guard d.count <= maxSignatureFile, let s = String(data: d, encoding: .utf8) else { return nil }
        let lines = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count >= 3, lines.first == armorBegin, lines.last == armorEnd else { return nil }
        return Data(base64Encoded: lines.dropFirst().dropLast().joined())
    }

    static func armor(_ blob: Data) -> String {
        let b = blob.base64EncodedString()
        let lines = stride(from: 0, to: b.count, by: 70).map { i -> String in
            let s = b.index(b.startIndex, offsetBy: i)
            return String(b[s..<(b.index(s, offsetBy: 70, limitedBy: b.endIndex) ?? b.endIndex)])
        }
        return ([armorBegin] + lines + [armorEnd]).joined(separator: "\n") + "\n"
    }

    /// byte[6] "SSHSIG", uint32 version 1, string publickey, string namespace, string reserved, string hash_algorithm, string signature.
    static func parse(_ file: Data) -> SSHSig? {
        guard let blob = dearmor(file) else { return nil }
        var r = Reader(blob)
        guard r.bytes(6) == Data("SSHSIG".utf8), r.uint32() == 1,
              let pk = r.string(), let ns = r.text(), let reserved = r.string(), let hash = r.text(), let sig = r.string(), r.atEnd
        else { return nil }
        return SSHSig(publicKey: pk, namespace: ns, reserved: reserved, hashAlgorithm: hash, signature: sig)
    }

    static func encode(_ s: SSHSig) -> Data {
        Data("SSHSIG".utf8) + uint32(1) + string(s.publicKey) + string(s.namespace) + string(s.reserved) + string(s.hashAlgorithm) + string(s.signature)
    }

    /// What the key signs: "SSHSIG", string namespace, string reserved, string hash_algorithm, string H(message).
    static func signedData(_ message: Data, namespace: String = namespace, reserved: Data = Data()) -> Data {
        Data("SSHSIG".utf8) + string(namespace) + string(reserved) + string(hashAlgorithm) + string(Data(SHA512.hash(data: message)))
    }

    /// What the authenticator signs: SHA256(application) || flags || uint32 counter || SHA256(signed data).
    static func skSignedData(application: String, flags: UInt8, counter: UInt32, data: Data) -> Data {
        Data(SHA256.hash(data: Data(application.utf8))) + Data([flags]) + uint32(counter) + Data(SHA256.hash(data: data))
    }

    /// The trusted key that signed this release, or nil. The signature must be an sk-ed25519 SSHSIG in our namespace,
    /// from a trusted key (same blob, so same application), with the touch and PIN flags set.
    static func verify(signatureFile: Data, sha256: String, version: String, bundleID: String = bundleID,
                       trusted: [TrustedUpdateKey]) -> TrustedUpdateKey? {
        guard let msg = message(sha256: sha256, version: version, bundleID: bundleID), let s = parse(signatureFile),
              s.namespace == namespace, s.reserved.isEmpty, s.hashAlgorithm == hashAlgorithm,
              let pk = parseSKKey(blob: s.publicKey), pk.application == application,
              let match = trusted.first(where: { isUsable($0) && parseSKKey(line: $0.key)?.blob == s.publicKey })
        else { return nil }
        var r = Reader(s.signature)
        guard r.text() == skKeyType, let sig = r.string(), sig.count == 64, let flags = r.byte(), let counter = r.uint32(), r.atEnd,
              flags & flagUserPresent != 0, flags & flagUserVerified != 0,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk.key)
        else { return nil }
        let data = skSignedData(application: pk.application, flags: flags, counter: counter, data: signedData(msg))
        return key.isValidSignature(sig, for: data) ? match : nil
    }
}
