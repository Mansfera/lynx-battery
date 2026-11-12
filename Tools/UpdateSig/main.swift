import Foundation

// Release-signing helper for add-release-key.sh and release.sh. Signing itself is ssh-keygen with the YubiKey; this only
// builds the message and checks keys and signatures with the same verifier the app and helper use.
//   message <dmg> <version>         the exact bytes to sign, to stdout
//   verify <dmg> <version> <sig>    the .sig verifies with a key in Sources/UpdateKey.swift; prints its label
//   key <pub>                       the .pub file is an sk-ed25519 release key (application ssh:lynx-release)
//   trusted <pub>                   the .pub file's key is in Sources/UpdateKey.swift; prints its label

func fail(_ s: String) -> Never {
    FileHandle.standardError.write(Data("update-sig: \(s)\n".utf8))
    exit(1)
}

func read(_ path: String) -> Data {
    guard let d = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return d
}

func releaseKey(_ path: String) -> UpdateSignature.SKPublicKey {
    guard let line = String(data: read(path), encoding: .utf8), let k = UpdateSignature.parseSKKey(line: line) else {
        fail("\(path) isn't an sk-ssh-ed25519 (YubiKey) public key")
    }
    guard k.application == UpdateSignature.application else {
        fail("\(path) is for application \(k.application), not \(UpdateSignature.application)")
    }
    return k
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "message" where args.count == 3:
    guard let msg = UpdateSignature.message(sha256: UpdateSignature.sha256(read(args[1])), version: args[2]) else {
        fail("\(args[2]) isn't a release version like 1.2.3")
    }
    FileHandle.standardOutput.write(msg)
case "verify" where args.count == 4:
    guard UpdateSignature.hasUsableKey(UpdateKey.trusted) else { fail("Sources/UpdateKey.swift has no release keys: run ./add-release-key.sh") }
    guard let k = UpdateSignature.verify(signatureFile: read(args[3]), sha256: UpdateSignature.sha256(read(args[1])),
                                         version: args[2], trusted: UpdateKey.trusted)
    else { fail("\(args[3]) doesn't verify with any key in Sources/UpdateKey.swift") }
    print(k.label)
case "key" where args.count == 2:
    _ = releaseKey(args[1])
case "trusted" where args.count == 2:
    let k = releaseKey(args[1])
    guard let t = UpdateKey.trusted.first(where: { UpdateSignature.parseSKKey(line: $0.key)?.blob == k.blob }) else {
        fail("\(args[1]) isn't in Sources/UpdateKey.swift")
    }
    print(t.label)
default:
    fail("usage: update-sig message <dmg> <version> | verify <dmg> <version> <sig> | key <pub> | trusted <pub>")
}
