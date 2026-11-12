/// Release keys trusted for updates, one per YubiKey; add-release-key.sh appends them. Either key can sign a release.
/// Empty: the app and helper can't verify updates, so they never install them on their own.
enum UpdateKey {
    static let trusted: [TrustedUpdateKey] = [
        TrustedUpdateKey(label: "yubikey 1", key: "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIPrdt1wU9AaU8dQhM4MeMZFvgtqlYIIe4BS87cmfTIBtAAAAEHNzaDpseW54LXJlbGVhc2U="),
        TrustedUpdateKey(label: "yubikey 2", key: "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAID7kUnhLyTznHJF88vkSUTD11qVdLbpm8G7IZSUfIV8MAAAAEHNzaDpseW54LXJlbGVhc2U="),
    ]
}
