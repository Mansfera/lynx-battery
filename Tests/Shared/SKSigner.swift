import Foundation
import CryptoKit

/// A software stand-in for a YubiKey: makes sk-ssh-ed25519 keys and SSHSIG signatures encoded exactly as OpenSSH does
/// (PROTOCOL.sshsig, PROTOCOL.u2f). Tests only; the update-verify test checks its output with real `ssh-keygen -Y verify`.
struct SKSigner {
    let key = Curve25519.Signing.PrivateKey()
    var application = UpdateSignature.application

    var blob: Data {
        UpdateSignature.string(UpdateSignature.skKeyType) + UpdateSignature.string(key.publicKey.rawRepresentation)
            + UpdateSignature.string(application)
    }
    var line: String { "\(UpdateSignature.skKeyType) \(blob.base64EncodedString())" }
    func trusted(_ label: String) -> TrustedUpdateKey { TrustedUpdateKey(label: label, key: line) }

    /// An armored SSHSIG over message. The parameters break one thing at a time for the rejection tests.
    func sign(_ message: Data, namespace: String = UpdateSignature.namespace, hash: String = UpdateSignature.hashAlgorithm,
              flags: UInt8 = 0x05, counter: UInt32 = 42, keyType: String = UpdateSignature.skKeyType) -> Data {
        let signed = UpdateSignature.signedData(message, namespace: namespace)
        let sig = try! key.signature(for: UpdateSignature.skSignedData(application: application, flags: flags, counter: counter, data: signed))
        let inner = UpdateSignature.string(keyType) + UpdateSignature.string(sig) + Data([flags]) + UpdateSignature.uint32(counter)
        let s = UpdateSignature.SSHSig(publicKey: blob, namespace: namespace, reserved: Data(), hashAlgorithm: hash, signature: inner)
        return Data(UpdateSignature.armor(UpdateSignature.encode(s)).utf8)
    }

    func sign(sha256: String, version: String, bundleID: String = UpdateSignature.bundleID) -> Data {
        sign(UpdateSignature.message(sha256: sha256, version: version, bundleID: bundleID) ?? Data())
    }
}
