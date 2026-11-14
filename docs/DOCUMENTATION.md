# Lynx Battery documentation

The full reference: every feature and setting, what the helper does as root, privacy, and how to build and release. For a quick overview, see the [README](../README.md).

## Install and update

With Homebrew:

```sh
brew install --cask mansfera/tap/lynx-battery
```

If Homebrew asks you to trust the tap first, run `brew trust --tap mansfera/tap`. To update, run `brew upgrade --cask lynx-battery`. If the charge-limit helper is installed, the upgrade asks for your password to put it back, and charging runs as normal for the few seconds that takes.

Or download the DMG from [Releases](https://github.com/Mansfera/lynx-battery/releases) and drag the app to Applications.

The app is ad-hoc signed and not notarized. The Homebrew cask clears the quarantine flag for you. With the DMG, the first launch needs right-click → Open, or System Settings → Privacy & Security → Open Anyway.

## The menu

Click the menu bar icon to open the menu. It has four tabs and a Settings button. Right-click opens the same menu, unless you set it to toggle Low Power Mode (see [Settings](#settings)).

### Overview

- Charge in big numbers, with what it's doing: charging to the limit, holding, on battery and time left.
- Health: what the battery holds now as a share of its design capacity, with the mAh under it.
- Cycle count, battery temperature, and how much power the Mac is drawing.
- Charge history for 24 hours, 7 days and 30 days.
- A Low Power Mode switch. It asks for your password unless the helper is installed.
- A "Service recommended" note when health drops below 80% or the cycle count reaches what Apple rates the battery for.

### Charge

The charge limit and its options. See [Charge limit](#charge-limit).

### Power

- A power-flow diagram from the adapter to the battery and the Mac. The bands always add up to what the adapter delivers: the battery's charge and the input are read at the same moment (SMC `CHBI` and `PDTR`), and the Mac gets the rest, including charging losses. On battery, the band is the Mac's live draw (SMC `PSTR`).
- Energy by app: live, 24 hours, 7 days and 30 days, with helper processes grouped under their app. Click an app to see its processes, its 30-day average and recent peak. Apps using more than usual are marked.
- Click the **macOS** row to see where the whole Mac's power goes right now, in watts: display, CPU, GPU, memory, Neural Engine, video and camera, the rest of the chip, and everything else. Wi-Fi, the SSD and audio have no power sensors, so they show activity instead of watts. Display watts are an estimate from brightness, marked `~`, and only on the MacBook Air M3 (Mac15,12), where they were measured. This breakdown is only measured while the row is open.
- The **Minimal energy use** switch. See [Energy tracking](#energy-tracking).

### Devices

Battery levels for AirPods (left, right and case, even before they connect), Magic Mouse, Keyboard and Trackpad, a paired iPhone or iPad nearby, and other connected devices that expose the Bluetooth Battery Service. Click a device to set its own low alert, get an alert when it's full, or hide it.

macOS asks for Bluetooth access the first time you open this tab. Until you allow it, iPhone, iPad and other Battery Service devices don't show up or send alerts. Apple Watch only reports its battery through the iPhone, so it isn't shown.

## Charge limit

Charge limiting needs a small helper that runs as root, because only root can write the SMC keys that pause charging. Install it from the Charge tab with **Install helper**; macOS asks for your admin password once. **Remove helper** at the bottom of the same tab uninstalls it and puts charging back to normal.

Once it's installed, the Charge tab has:

- **Limit:** a switch and a slider from 15% up to full. The Mac always charges below 10%, so 15% is the lowest limit.
- **Top up to max once:** charges to full one time, then goes back to the limit.
- **Sailing mode:** once at the limit, charge again only after the battery drops by a set amount (2–20%, default 5%), instead of every time it dips under the limit.
- **Heat protection:** pauses charging when the battery reaches a set temperature (30–45°, default 35°) and holds the pause for at least 5 minutes, until it has cooled down.
- **Discharge to the limit:** when you plug in above the limit, the Mac runs on battery down to it. A monitor or dock on the same cable would lose power too, so with one attached the Mac only stops charging and runs down as you use it. Shown only on Macs whose firmware can both pause charging and cut the adapter.
- **Stay awake until the limit:** on Macs where the limit can't hold during sleep, keeps the Mac awake until it reaches the limit, so it doesn't charge to full while asleep.
- **MagSafe light:** green while holding the limit, amber while charging to it.
- **Limit in true charge:** only in the "Of original capacity" percent mode, to set the limit from 0 to 100% of what the battery holds now.

A change applies within a second: the app saves the settings and pings the helper.

### What the helper does as root

The helper is a LaunchDaemon (`com.mansfera.lynxbattery.helper`). It:

- Reads the battery and the limit settings the app writes to `/Library/Application Support/com.mansfera.lynxbattery/`, and writes its status back there.
- Writes SMC keys to pause charging, cut the adapter for discharging, and set the MagSafe light. Which keys depends on the firmware: a firmware charge limit (`bfF0`, `bfD0`, `bfE0`) where the firmware accepts it, otherwise `CHTE` or `CH0B`+`CH0C` to pause charging and `CH0I` to cut the adapter. `CHIE` behaves differently across firmware, so its role is tested on first use. The MagSafe light is `ACLC`.
- Turns Low Power Mode on or off for the right-click shortcut, so it doesn't ask for a password.
- Restores normal charging when it stops, when the limit is off, and whenever the battery is at 10% or below.

macOS can reset the charging keys, so while charging is paused the helper re-checks them every 3 seconds. It re-checks everything every 15 seconds, or every 40 with Minimal energy use on, and also wakes on power changes and settings changes. Its log is `/var/log/lynx-battery-helper.log`.

A Homebrew upgrade removes the helper with the old app and puts it back if it was installed or the limit was on. If an app update ships a newer helper, the Charge tab shows **Update**, which asks for your password once.

## Alerts

Alerts appear as a pill at the top of the screen that you can drag or fling away, with an optional glow around the screen edges. Most of them are set in Settings → Alerts:

- **Battery low:** at any levels you choose (default 20%, 10% and 5%).
- **Battery charged:** at any levels from 50% to 100% (default 80%).
- **Full-screen alert:** covers the screen at 1, 2, 3 (default) or 5% until you dismiss it or plug in.
- **Charger connected** and **Charger disconnected.**
- **Battery too hot:** at 42°.
- **Charger can't keep up:** when the Mac draws more than the adapter delivers and the battery still drains. Always on.
- **Devices:** a low alert for devices (default 15%), which you can override per device in the Devices tab, plus an optional alert when a device is fully charged.
- **New version:** see [Updates](#updates).

Each alert has its own sound, so you can tell them apart without looking. Settings → Sounds sets them one by one, with **None** to mute one, and **Play sounds** to mute them all. Picking a sound plays it. Hold Option and click an alert's name, or pick a sound with Option held, to also see a test alert of that kind with its sound. The defaults:

| Alert | Sound |
| --- | --- |
| Charger connected, Charged | Glass |
| Charger disconnected | Pop |
| Battery low | Submarine |
| Battery critical (5% or below, and the full-screen alert) | Sosumi |
| Warnings (battery too hot, charger can't keep up) | Funk |
| Device low | Bottle |
| Device charged | Hero |
| Low Power Mode | Purr |
| New version | Ping |

Under Style you pick the screen glow and **Keep alerts until clicked**.

## Energy tracking

Energy by app comes from `top`, which runs for about a second per sample. Settings → General → Power tracking sets how often it runs in the background:

- **Frequent:** every 2 minutes.
- **Normal:** every 5 minutes (default).
- **Eco:** every 15 minutes, which still gives each hour enough samples for the 24-hour, 7-day and 30-day averages.

Only these scheduled samples go into the history, so it stays even over time and isn't skewed by whatever runs while the menu is open, including this app.

**Live Power tab** (on by default): while the Power tab is open, the power flow refreshes every 2 seconds and energy by app every 10 seconds. The first live sample waits 2 seconds so it doesn't measure the menu opening. With it off, the tab takes one energy sample when it opens.

**Minimal energy use**, in the Power tab, cuts the app's own draw. It switches energy by app to Eco, turns off the live Power tab, animations, the screen glow and Bluetooth scans, and reads the battery less often while the menu is closed. Devices refresh only when you open the menu, so their alerts can come late. The charge limit and battery alerts keep working, and the helper checks in every 40 seconds instead of 15.

## Track devices

Settings → Alerts → Devices → **Track devices** is on by default. Turn it off and the Devices tab disappears, and the app stops reading devices altogether: no Bluetooth scans or connections, no `system_profiler` or `ioreg` reads, no device alerts. It doesn't ask for Bluetooth access while it's off. Turning it back on picks up right away, no relaunch needed.

## Updates

Settings → Updates has three switches:

- **Check for new versions** (on by default): asks GitHub for the latest release 15 seconds after launch, then every 8 hours, and shortly after waking if a check is due. A newer version shows as a banner at the top of the menu with **Download**, which opens the release page, and a close button that hides the banner until the next version. Drafts and pre-releases are skipped.
- **Alert about new versions** (on by default): an alert pill, once per version. It stays until you click it, which opens the release page, or close it, whatever **Keep alerts until clicked** says. Closing it offers to turn these alerts off. If a battery or device alert comes in meanwhile, the update alert steps aside and comes back after.
- **Install updates automatically** (off by default): when a new version shows up, the app downloads it, checks it, replaces itself and relaunches, with a short "Updated to X — relaunching" alert. With it off, the banner and the alert get an **Install** button that does the same once. If an install fails, the banner says why and offers Download instead.

Checks happen at most once an hour, even across restarts. Offline or rate-limited, the app tries again later without telling you. The request itself is described under [Privacy](#privacy).

### How updates are verified

Every release is signed with a hardware key on one of the developer's two YubiKeys: an OpenSSH FIDO2 key (`sk-ssh-ed25519@openssh.com`, application `ssh:lynx-release`) that never leaves the YubiKey and needs its PIN and a touch for every signature. Both public keys are built into the app and the helper (`Sources/UpdateKey.swift`), so either YubiKey can sign. The signature (`Lynx-Battery-<v>.dmg.sig`) is an `ssh-keygen -Y sign` signature in the `lynx-battery-update` namespace over the bundle ID, the version and the DMG's sha256. The app and the helper verify it themselves with CryptoKit, without ssh-keygen: the key must be one of the built-in ones (application included), the hash SHA-512, and the YubiKey's touch and PIN flags must both be set. Before anything is replaced, the app checks the DMG against GitHub's sha256 and the signature. Then:

- **With the charge-limit helper**, no password is needed. The app drops the DMG and a request into the helper's folder and pings it. The helper trusts none of it and checks everything again on its own copy: the signature with its built-in keys, the sha256, a request under 10 minutes old, a DMG file name with no path in it, and a target that is a real Lynx Battery app in `/Applications` or `~/Applications` with no symlinks on the way. It mounts the DMG read-only, accepts only `com.mansfera.lynxbattery` at exactly the signed version and newer than the installed one, and rejects symlinks pointing out of the bundle, setuid files and broken code signatures. The new app is copied next to the old one with the same owner and swapped in with one atomic rename; the old copy is deleted only after the swap. Each step goes to the helper log. The app then quits and opens itself again as you.
- **Without the helper**, the app runs the same checks itself if it can write to its own folder (usual for an admin user in `/Applications`). Otherwise it can't replace itself without a password, so the banner offers Download.
- **Installed with Homebrew** (a `Caskroom/lynx-battery` folder exists), it never replaces itself, so Homebrew keeps knowing which version is installed. The banner says to run `brew upgrade --cask mansfera/tap/lynx-battery` and copies the command.

A build without release keys (the list in `Sources/UpdateKey.swift` empty) can't verify anything, so automatic install is greyed out in Settings and the banner and alert only offer Download.

## Settings

Open Settings with the gear button in the menu.

- **General:** open at login, which percentage to show, the menu bar icon (percent inside, beside, icon only or percent only), colour by level, animate while charging, right-click for Low Power Mode (needs the helper), power tracking, and the app icon.
- **Alerts:** battery alerts, devices and alert style, as above.
- **Sounds:** a sound for each alert, as above.
- **Updates:** update checks, alerts and automatic installs, as above.
- **About:** version, credits and **Quit Lynx Battery**. Quitting stops alerts and the menu bar icon, but not the charge limit: the helper keeps it without the app.

### Percentage

- **As macOS shows:** the smoothed number from the battery controller, the same as `pmset`.
- **True charge** (default): remaining ÷ full capacity.
- **Of original capacity:** true charge × health, so a full battery shows its health.

### App icon

Green eyes (default), White eyes, Plain or Green cells. Green eyes is a Liquid Glass icon, so on macOS 26 and later it follows the Dark, Clear and Tinted icon styles. macOS can't swap a glass icon while an app runs, so the other three are set as a custom Finder icon and keep one look in every style. A custom icon makes `codesign --verify` report the bundle as modified, like any icon pasted through Get Info. The app still runs, and choosing Green eyes removes it.

## Macs without a battery

On an iMac, Mac mini, Mac Studio or Mac Pro, Overview, Charge and the battery settings are hidden. A UPS doesn't count as a battery. The menu bar shows the Mac's live power draw instead, Power shows it above energy by app, and Devices works as usual.

The draw comes from the SMC key `PSTR`, falling back to `PDTR`, with no root needed. If a Mac reports neither, the app says so instead of showing a number. It's the power used by the Mac itself, so it's lower than a meter at the wall would show.

## Privacy

Lynx Battery reads, all locally:

- Battery and power-source data from IOKit, and SMC keys for temperature and power.
- Energy per process from `top`, and the chip's energy counters (IOReport) while the macOS breakdown is open.
- Paired Bluetooth devices from `system_profiler` and `ioreg`, and battery levels over the Bluetooth Battery Service from devices whose name matches one paired with this Mac.

It stores history and energy data in `~/Library/Application Support/com.mansfera.lynxbattery/`, its settings in `~/Library/Preferences/com.mansfera.lynxbattery.plist`, and the charge-limit settings and helper status in `/Library/Application Support/com.mansfera.lynxbattery/`.

The only network request is the update check: `GET https://api.github.com/repos/Mansfera/lynx-battery/releases/latest`, with a `LynxBattery/<version>` User-Agent, no cookies, and the cached ETag so an unchanged answer doesn't count toward GitHub's rate limit. Nothing about you or your Mac is sent. When you install an update, the app also downloads the release's DMG and its `.sig` from GitHub. Turn off **Check for new versions** and the app makes no network requests at all.

## Uninstall

With Homebrew:

```sh
brew uninstall --cask lynx-battery          # removes the app and the helper
brew uninstall --zap --cask lynx-battery    # also removes settings, history and energy data
```

With the DMG: click **Remove helper** in the Charge tab, quit the app and move it to the Trash. To remove its data too, delete the folders listed under [Privacy](#privacy).

## Coming from Etherlynx Battery

Settings and history move over on first launch. The old helper keeps running until you install the new one from the Charge tab, which brings the limit settings across and removes the old helper. Open at login needs turning on again, and macOS asks for Bluetooth access again when you open the Devices tab.

## Development

Plain `swiftc`, no Xcode project. `build.sh` compiles the app (`Sources/`) and the root helper (`Helper/`), bundles the fonts, marks and icons from `Resources/`, and signs ad-hoc:

```sh
./build.sh
open "Lynx Battery.app"
```

| What | Where |
|---|---|
| Bundle ID | `com.mansfera.lynxbattery` |
| Helper | `com.mansfera.lynxbattery.helper` |
| Limit settings and helper status | `/Library/Application Support/com.mansfera.lynxbattery/` |
| History and energy data | `~/Library/Application Support/com.mansfera.lynxbattery/` |
| Helper log | `/var/log/lynx-battery-helper.log` |
| Update request, DMG and result (briefly) | `/Library/Application Support/com.mansfera.lynxbattery/` (`update-request.json`, `Lynx-Battery-<v>.dmg`, `update-result.json`) |

### Build flags

- `SIMULATE_NO_BATTERY=1 ./build.sh` builds the app as if the Mac had no battery. `SIMULATE_NO_BATTERY=no-watts` also hides the power keys. These are compile flags, so normal builds don't contain them.
- `SIMULATE_VERSION=1.0.0 ./build.sh` builds an app that reports itself as 1.0.0, to try the update banner and alert. It only changes the built bundle's `Info.plist`, and `release.sh` unsets it. The alert shows once per version, so to see it again run `defaults delete com.mansfera.lynxbattery updateAlerted` (and `updateDismissed` for the banner, `updateCheckedAt` to check again right away) before relaunching.

### Tests

Each script builds a small test binary and runs it. None of them touch the installed app's settings, history, charge limit or the app in `/Applications`, and none need root. Scripts marked with a folder argument also render screens to PNG.

```sh
Tests/charge-limit.sh       # limit bounds, scale conversion, heat protection
Tests/charge-start.sh       # charging starts after a limit change, live charge state
Tests/helper-restore.sh     # when the cask puts the helper back after an upgrade
Tests/helper-pace.sh        # the real helper's timing, without writing the SMC (about 3 minutes)
Tests/high-alerts.sh        # alert thresholds in every percent mode
Tests/energy-history.sh     # impossible readings stay out of energy by app
Tests/tracking-cadence.sh   # how often energy by app is sampled, and the live Power tab
Tests/minimal-energy.sh     # what Minimal energy use slows down [png folder]
Tests/power-breakdown.sh    # the macOS row's power breakdown [png folder]
Tests/desktop-mode.sh       # Macs without a battery [png folder]
Tests/right-click.sh        # right-click only toggles Low Power Mode without a password [png folder]
Tests/device-tracking.sh    # Track devices off stops device reads and Bluetooth [png folder]
Tests/update-check.sh       # version comparison, GitHub release parsing, banner and alert rules
Tests/update-verify.sh      # update signatures (throwaway keys, checked against ssh-keygen), request paths, Homebrew detection
Tests/update-install.sh     # the helper's install end to end with real DMGs, into a temp folder
```

### Releasing

Releases are signed with a FIDO2 key on each of two YubiKeys, so either one can sign and a lost one isn't the end. You need Homebrew's OpenSSH (`brew install openssh`; macOS's own `ssh-keygen` can't talk to a YubiKey) and a FIDO2 PIN on each YubiKey (`ykman fido access change-pin`).

Once per YubiKey, insert just that one and run `./add-release-key.sh 1`, then with the other `./add-release-key.sh 2`. Each run makes a resident, PIN-protected key (`ssh-keygen -t ed25519-sk -O resident -O verify-required -O application=ssh:lynx-release`), saves the key handle as `~/.ssh/lynx_release_<n>` and adds its public key to `Sources/UpdateKey.swift`, which you commit. Running it again with a key that's already there changes nothing. The key handle files aren't secret without the YubiKey and its PIN, but back them up; because the key is resident, you can also get them back on any Mac with `ssh-keygen -K` and the YubiKey. These keys are separate from any key you use for git. After the keys change, reinstall the helper from the Charge tab, since the helper has them built in.

`./release.sh 1.0.1` first checks that a `~/.ssh/lynx_release_*` key it trusts exists, and stops otherwise. Then it sets the version, builds the app and packages the DMG, and signs it with whichever YubiKey is plugged in (enter the PIN and touch it). It checks the `.sig` with the same verifier the app uses before it creates the GitHub release with the DMG and its `.sig`, and updates the cask in [Mansfera/homebrew-tap](https://github.com/Mansfera/homebrew-tap) from `Homebrew/lynx-battery.rb`.

### Icons

The icons are generated by `Resources/Icons/generate.py`. To rebuild them, run `Resources/Icons/build-icons.sh`, which needs Xcode 26 or later, ImageMagick and `shapely`. The results are committed, so `build.sh` needs none of this.

## Credits

Designed and developed by [Etherlynx Studio](https://etherlynx.xyz/) and [Ihor Kharkholyuk](https://kharkholy.uk). Made with Claude.

The app was started by Volo Nehoda as Etherlynx Battery, and that work is kept in this repository's history.

Onest and Geist Mono are bundled under the SIL Open Font License 1.1. See `Resources/Fonts/*-OFL.txt`.
