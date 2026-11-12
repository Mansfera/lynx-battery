import Foundation
import CryptoKit

/// Підпис релізу: Ed25519 над рядком з bundle id, версією й sha256 DMG.
/// Версія в підписі не дає видати старий підписаний DMG за новий, а sha256 прив'язує підпис до самого файлу.
enum UpdateSignature {
    static let bundleID = "com.mansfera.lynxbattery"
    static let signatureSize = 64

    static func isSHA256(_ s: String) -> Bool { UpdatePolicy.isSHA256(s) }

    static func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// nil — версія пререліз чи нерозбірна, або sha256 не того формату.
    static func message(sha256: String, version: String, bundleID: String = bundleID) -> Data? {
        guard let v = AppVersion(version), !v.prerelease, isSHA256(sha256) else { return nil }
        return Data("lynx-battery-update/1\n\(bundleID)\n\(v.description)\n\(sha256.lowercased())\n".utf8)
    }

    static func publicKey(_ base64: String) -> Curve25519.Signing.PublicKey? {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    static func privateKey(_ base64: String) -> Curve25519.Signing.PrivateKey? {
        guard let raw = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32 else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    static func verify(signature: Data, sha256: String, version: String, bundleID: String = bundleID, publicKey: String) -> Bool {
        guard signature.count == signatureSize, let key = Self.publicKey(publicKey),
              let msg = message(sha256: sha256, version: version, bundleID: bundleID) else { return false }
        return key.isValidSignature(signature, for: msg)
    }

    static func sign(sha256: String, version: String, bundleID: String = bundleID, with key: Curve25519.Signing.PrivateKey) -> Data? {
        guard let msg = message(sha256: sha256, version: version, bundleID: bundleID) else { return nil }
        return try? key.signature(for: msg)
    }

    /// Файл .sig — base64 підпису одним рядком.
    static func parseSignatureFile(_ d: Data) -> Data? {
        guard d.count < 1024, let s = String(data: d, encoding: .utf8),
              let sig = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)), sig.count == signatureSize else { return nil }
        return sig
    }
}
