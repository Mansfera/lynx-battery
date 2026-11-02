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

    # Every upgrade runs the uninstall steps below, which remove the helper and mark it for restoring.
    # Also put it back if the charge limit was on. That check needs no root, so sudo only runs with
    # a helper to restore.
    run "{{appdir}}/Lynx Battery.app/Contents/Library/LaunchServices/com.mansfera.lynxbattery.helper",
        args:         ["--mark-restore", "{{temp}}/restore-helper"],
        must_succeed: false
    if_path_exists "restore-helper", base: :temp do
      run "{{appdir}}/Lynx Battery.app/Contents/Library/LaunchServices/com.mansfera.lynxbattery.helper",
          args:         ["--restore"],
          sudo:         true,
          must_succeed: false
    end
  end

  # Not `uninstall launchctl:` and `delete:`: they call sudo even when no helper is installed.
  # The helper restores normal charging when launchd stops it.
  uninstall_preflight_steps do
    if_path_exists "/Library/LaunchDaemons/com.mansfera.lynxbattery.helper.plist" do
      touch "restore-helper", base: :temp
      run "/bin/launchctl",
          args:         ["bootout", "system/com.mansfera.lynxbattery.helper"],
          sudo:         true,
          must_succeed: false
      run "/bin/rm",
          args:         [
            "-f",
            "/Library/LaunchDaemons/com.mansfera.lynxbattery.helper.plist",
            "/Library/PrivilegedHelperTools/com.mansfera.lynxbattery.helper",
          ],
          sudo:         true,
          must_succeed: false
    end
  end

  uninstall quit: "com.mansfera.lynxbattery"

  zap trash: [
    "/Library/Application Support/com.mansfera.lynxbattery",
    "~/Library/Application Support/com.mansfera.lynxbattery",
    "~/Library/Preferences/com.mansfera.lynxbattery.plist",
  ]
end
