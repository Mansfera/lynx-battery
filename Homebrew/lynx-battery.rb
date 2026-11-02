# Homebrew cask for Lynx Battery. release.sh fills in the version and checksum
# and pushes the result to the tap repository as Casks/lynx-battery.rb.
cask "lynx-battery" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/Mansfera/lynx-battery/releases/download/v#{version}/Lynx-Battery-#{version}.dmg"
  name "Lynx Battery"
  desc "Menu bar battery monitor with charge limit, power flow and alerts"
  homepage "https://github.com/Mansfera/lynx-battery"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Lynx Battery.app"

  # Lynx Battery is ad-hoc signed, not notarized, so macOS would refuse to open a quarantined
  # download. Clearing the quarantine flag is what "Open Anyway" does.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Lynx Battery.app"]
  end

  # The charge-limit helper restores normal charging when launchd stops it.
  uninstall launchctl: "com.mansfera.lynxbattery.helper",
            quit:      "com.mansfera.lynxbattery",
            delete:    [
              "/Library/LaunchDaemons/com.mansfera.lynxbattery.helper.plist",
              "/Library/PrivilegedHelperTools/com.mansfera.lynxbattery.helper",
            ]

  zap trash: [
    "/Library/Application Support/com.mansfera.lynxbattery",
    "~/Library/Application Support/com.mansfera.lynxbattery",
    "~/Library/Preferences/com.mansfera.lynxbattery.plist",
  ]
end
