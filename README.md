<img src="Resources/Icons/green-eyes.png" width="128" alt="Lynx Battery icon: a lynx face built from battery cells">

# Lynx Battery

A macOS menu bar app that shows what your battery and your Mac's power are doing, and stops the battery charging past a limit you set. Keeping a laptop at 80% instead of 100% most of the time slows battery wear, and Lynx Battery does it without you having to remember to unplug.

Requires macOS 14 or later on Apple silicon.

## Install

```sh
brew install --cask mansfera/tap/lynx-battery
```

Or download the DMG from [Releases](https://github.com/Mansfera/lynx-battery/releases) and drag the app to Applications. The app isn't notarized, so the first launch from the DMG needs right-click → Open.

To limit charging, open the Charge tab and click **Install helper**. macOS asks for your password once.

## What it does

- **Overview:** charge, time left, battery health, cycles, temperature, and 24-hour to 30-day history.
- **Charge limit:** stop at any level from 15% to full, with sailing mode, heat protection, discharge to the limit and a one-time top-up.
- **Power:** where the power goes, from the adapter to the battery and the Mac, energy use by app, and a live breakdown of the whole Mac.
- **Devices:** battery levels for AirPods, Magic accessories, a nearby iPhone or iPad and other Bluetooth devices. You can turn it off.
- **Alerts:** low, charged, charger and temperature alerts as a pill you can fling away, plus a full-screen alert when the battery is nearly empty.
- **Updates:** tells you when a new version is out, and can install it for you.
- **Light on energy:** choose how often it measures, or turn on Minimal energy use.

The only network request is the update check on GitHub, and you can turn it off.

## Documentation

Every setting, what the helper does as root, privacy, uninstalling, and building from source: [docs/DOCUMENTATION.md](docs/DOCUMENTATION.md).

## Credits

Designed and developed by [Etherlynx Studio](https://etherlynx.xyz/) and [Ihor Kharkholyuk](https://kharkholy.uk). Made with Claude.
