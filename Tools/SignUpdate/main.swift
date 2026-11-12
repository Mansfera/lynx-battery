import Foundation
import CryptoKit

// Підпис релізів для make-update-key.sh і release.sh. Приватний ключ приходить лише через stdin (з Keychain), не з аргументів.
//   generate               — новий приватний ключ (base64) у stdout
//   public                 — публічний ключ до приватного з stdin
//   check                  — ключ з stdin пасує до вкомпільованого UpdateKey.publicKey
//   sign <dmg> <version>   — підпис DMG (base64) у stdout; перед виводом перевіряє його вкомпільованим ключем

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(s)\n".utf8))
    exit(1)
}

func stdinKey() -> Curve25519.Signing.PrivateKey {
    let d = FileHandle.standardInput.readDataToEndOfFile()
    guard let s = String(data: d, encoding: .utf8), let k = UpdateSignature.privateKey(s) else { fail("no valid private key on stdin") }
    return k
}

func checkCompiled(_ k: Curve25519.Signing.PrivateKey) {
    guard !UpdateKey.publicKey.isEmpty else { fail("Sources/UpdateKey.swift has no public key: run ./make-update-key.sh") }
    guard UpdateSignature.publicKey(UpdateKey.publicKey)?.rawRepresentation == k.publicKey.rawRepresentation else {
        fail("the Keychain key doesn't match Sources/UpdateKey.swift")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "generate":
    print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())
case "public":
    print(stdinKey().publicKey.rawRepresentation.base64EncodedString())
case "check":
    checkCompiled(stdinKey())
case "sign" where args.count == 3:
    let k = stdinKey()
    checkCompiled(k)
    guard let dmg = FileManager.default.contents(atPath: args[1]) else { fail("can't read \(args[1])") }
    let sha = UpdateSignature.sha256(dmg)
    guard let sig = UpdateSignature.sign(sha256: sha, version: args[2], with: k),
          UpdateSignature.verify(signature: sig, sha256: sha, version: args[2], publicKey: UpdateKey.publicKey)
    else { fail("couldn't sign \(args[2]): is it a release version like 1.2.3?") }
    print(sig.base64EncodedString())
default:
    fail("usage: sign-update generate | public | check | sign <dmg> <version>")
}
