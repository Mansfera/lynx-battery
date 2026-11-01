# Etherlynx Battery

A macOS menu-bar battery app: live charge, health, cycles and temperature, a power-flow view, energy by app, Bluetooth device batteries, custom alerts — and a charge limit with Sailing mode and heat protection.

Requires macOS 14+ on Apple silicon.

## Install

```sh
brew install --cask volonehoda/tap/etherlynx-battery
```

If Homebrew asks you to trust the tap first: `brew trust --tap volonehoda/tap`. Update with `brew upgrade --cask etherlynx-battery`.

Or download the DMG from [Releases](https://github.com/VoloNehoda/etherlynx-battery/releases) and drag the app to Applications.

The app is ad-hoc signed, not notarized. The Homebrew cask clears the quarantine flag after install; with the DMG, the first launch needs right-click → Open (or System Settings → Privacy & Security → Open Anyway).

## Build

```sh
./build.sh
open "Etherlynx Battery.app"
```

To publish a new version (builds, packages the DMG, creates the GitHub release and bumps the Homebrew cask): `./release.sh 1.0.1`.

Plain `swiftc`, no Xcode project. `build.sh` compiles the app (`Sources/`) and the root helper (`Helper/`), bundles fonts and marks from `Resources/`, and signs ad-hoc.

## What's inside

- **Overview** — charge, health (full ÷ design capacity), cycles, battery temperature (SMC `TB0T/TB1T`), Mac draw, 24h/7d/30d history, Low Power Mode.
- **Charge** — charge limit 50–100 %, Sailing mode, heat protection (35° with a 5-minute hold), top up to 100 % once, stay awake until the limit, MagSafe LED.
- **Power** — Sankey power flow (adapter → battery / Mac), energy by app (live, 24h, 7d, 30d) grouped by app bundle.
- **Devices** — AirPods (L/R/case, even before they connect), Magic Mouse/Keyboard/Trackpad, paired iPhone and iPad nearby, and anything connected that exposes the Bluetooth Battery Service.
- **Alerts** — a draggable pill with jelly physics, screen glow, full-screen alert at critical levels.
- **Percent modes** — as macOS shows, true charge (remaining ÷ full), or of original capacity.
- Right-click the menu bar icon to toggle Low Power Mode.

## Charge limit helper

The limit runs in a small root LaunchDaemon (`xyz.etherlynx.battery.helper`), installed from the Charge tab with an admin prompt. Settings and status live in `/Library/Application Support/Etherlynx Battery/`, the log in `/var/log/etherlynx-battery-helper.log`.

The helper picks a lever per firmware: `CHTE` or `CH0B`+`CH0C` to pause charging, `CH0I` to cut the adapter. `CHIE` behaves differently across firmware, so its role is self-tested on first use. macOS can reset these keys, so the helper re-checks them every 3 s while something is paused. On exit, when the limit is off, or below 10 %, it restores normal charging. **Remove helper** in the Charge tab uninstalls it.

## Not supported

- Apple Watch — it only reports its battery through the iPhone. iPhone and iPad are read over Bluetooth, so they need to be paired with this Mac and nearby.
- Widgets (need an Xcode app extension).

## Fonts

Onest and Geist Mono are bundled under the SIL Open Font License 1.1 — see `Resources/Fonts/*-OFL.txt`.
