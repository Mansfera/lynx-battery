import Foundation

// Коли cask повертає хелпер після оновлення. Лише чиста логіка: нічого не встановлює.

var failures = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    let ok = got == want
    if !ok { failures += 1 }
    print("\(ok ? "ok  " : "FAIL") \(name)")
}
func restore(_ json: String?) -> Bool { ChargeInstall.shouldRestore(config: json?.data(using: .utf8)) }

check("limit on: comes back", restore(#"{"enabled":true,"limit":80}"#), true)
check("spaces in the file don't matter", restore(#"{"enabled": true, "limit": 90}"#), true)
check("an older file with few fields still counts", restore(#"{"enabled":true}"#), true)
check("limit off: stays away", restore(#"{"enabled":false,"limit":80}"#), false)
check("no config: fresh install", restore(nil), false)
check("broken config", restore("{not json"), false)
check("no enabled field", restore(#"{"limit":80}"#), false)
check("enabled is not a real true", restore(#"{"enabled":"true"}"#), false)

let script = ChargeInstall.script(helperPath: "/Applications/Lynx Battery.app/Contents/Library/LaunchServices/helper", uid: 501)
check("the path with a space stays quoted", script.contains("cp '/Applications/Lynx Battery.app/Contents/Library/LaunchServices/helper' "), true)
check("the folder goes back to the user", script.contains("chown -R 501 "), true)
check("the daemon is started", script.contains("launchctl bootstrap system "), true)

print(failures == 0 ? "All passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
