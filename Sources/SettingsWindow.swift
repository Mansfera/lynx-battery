import AppKit
import SwiftUI

// Settings is a separate system window, not a page in the popover: the popover closes on a click nearby,
// and here it's convenient to change the icon style and see it in the menu bar right away.

/// The action goes up the responder chain to AppDelegate; it lives in main.swift, which isn't in the test builds.
@objc protocol SettingsOpener { func openSettings() }

enum AppMenu {
    /// An LSUIElement app doesn't show the main menu, but ⌘, ⌘W ⌘Q and ⌘C ⌘V in text fields only work through it.
    /// Actions without a target go up the responder chain to NSApp and AppDelegate.
    static func installMainMenu() {
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = m
            return item
        }
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let main = NSMenu()
        main.addItem(submenu("Lynx Battery", [
            NSMenuItem(title: "Settings…", action: #selector(SettingsOpener.openSettings), keyEquivalent: ","),
            .separator(),
            NSMenuItem(title: "Quit Lynx Battery", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]))
        main.addItem(submenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            redo,
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        main.addItem(submenu("Window", [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ]))
        NSApp.mainMenu = main
    }
}

final class SettingsWindow: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) { self.model = model }

    func show() {
        Settings.shared.syncLaunchAtLogin()
        let w = window ?? make()
        window = w
        // An LSUIElement app doesn't activate itself: without this the window opens behind others
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)   // don't put the cursor in the thresholds field on every open
    }

    func make() -> NSWindow {
        // Tabs in the toolbar, like system apps: all together it's over 1000 pt, the bottom sections would be hidden past the edge
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralSettings(model: model)))
        tabs.addTabViewItem(tab("Alerts", symbol: "bell", AlertSettings(model: model)))
        tabs.addTabViewItem(tab("Sounds", symbol: "speaker.wave.2", SoundSettings(model: model)))
        tabs.addTabViewItem(tab("Updates", symbol: "arrow.down.circle", UpdateSettings(model: model)))
        tabs.addTabViewItem(tab("About", symbol: "info.circle", AboutSettings(model: model)))
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("Settings")
        return w
    }

    private func tab<V: View>(_ label: String, symbol: String, _ view: V) -> NSTabViewItem {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize   // the window follows the tab's height
        host.title = label                           // window title is the tab name, like system apps
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    /// Closing takes focus from the thresholds field, so the typed value is added rather than lost.
    func windowWillClose(_ n: Notification) { window?.makeFirstResponder(nil) }
}

/// Shared tab styling. The height is set: Form has none of its own, and on a small screen it will scroll.
private struct SettingsPane<Content: View>: View {
    let height: CGFloat
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pal = Palette(scheme: scheme)
        Form { content }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            .toggleStyle(.switch)
            .tint(pal.toggleTint)
            .font(Brand.text(13))
            .environment(\.palette, pal)
            .frame(width: 480, height: min(height, (NSScreen.main?.visibleFrame.height ?? 800) - 100))
    }
}

private struct SectionHead: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(Brand.text(13, .semibold)) }
}

/// Without the helper the toggle is disabled and shows "off", but the choice is kept in case the helper comes back.
struct RightClickLowPowerToggle: View {
    @ObservedObject var control: ChargeControl
    @ObservedObject var s: Settings

    var body: some View {
        Toggle(isOn: Binding(get: { control.installed && s.rightClickLowPower }, set: { s.rightClickLowPower = $0 })) {
            Text("Right-click for Low Power Mode")
            Text(control.installed
                 ? "Right-clicking the icon switches Low Power Mode instead of opening the menu."
                 : "Needs the charge-limit helper. Install it from the Charge tab.")
        }
        .disabled(!control.installed)
        .onAppear { control.readStatus() }
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var s = Settings.shared

    var body: some View {
        let hasBattery = model.battery != nil
        SettingsPane(height: hasBattery ? 772 : 562) {
            Section {
                Toggle("Open at login", isOn: $s.launchAtLogin)
                if hasBattery {
                    Picker(selection: $s.percentMode) {
                        ForEach(PercentMode.allCases) { Text($0.rawValue).tag($0) }
                    } label: {
                        Text("Battery percentage")
                        Text(s.percentMode.detail)
                    }
                }
            }
            Section {
                // Without a battery the menu bar has only the device icon — style and animation change nothing
                if hasBattery {
                    Picker("Icon", selection: $s.iconStyle) {
                        ForEach(IconStyle.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Toggle(isOn: $s.smartColors) {
                    Text("Colour by level")
                    Text(hasBattery ? "Green when charging, blue when holding the limit, red when low, yellow in Low Power Mode." : "Red when a device is low.")
                }
                if hasBattery {
                    Toggle(isOn: $s.animateCharging) {
                        Text("Animate while charging")
                        if s.minimalEnergy { Text("Off while Minimal energy use is on.") }
                    }
                    .disabled(s.minimalEnergy)
                    RightClickLowPowerToggle(control: model.charge, s: s)
                }
            } header: { SectionHead("Menu bar") }
            Section {
                Picker(selection: Binding(get: { s.effectiveAppTracking }, set: { s.appTracking = $0 })) {
                    ForEach(AppTracking.allCases) { Text($0.rawValue).tag($0) }
                } label: {
                    Text("Energy by app")
                    Text(s.minimalEnergy ? "Eco while Minimal energy use is on." : s.appTracking.detail)
                }
                .disabled(s.minimalEnergy)
                Toggle(isOn: Binding(get: { s.livePowerTab && !s.minimalEnergy }, set: { s.livePowerTab = $0 })) {
                    Text("Live Power tab")
                    Text(s.minimalEnergy ? "Off while Minimal energy use is on."
                         : hasBattery ? "While the Power tab is open, the power flow updates every 2 seconds and energy by app every 10 seconds."
                         : "While the Power tab is open, energy by app updates every 10 seconds.")
                }
                .disabled(s.minimalEnergy)
            } header: { SectionHead("Power tracking") }
            Section {
                AppIconPicker(selection: $s.appIcon)
            } header: {
                SectionHead("App icon")
            } footer: {
                if #available(macOS 26, *) {
                    Text("Only \(AppIconVariant.standard.title) follows the Dark, Clear and Tinted icon styles.")
                        .font(Brand.text(11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Icons in a row, to choose by look rather than by name.
private struct AppIconPicker: View {
    @Binding var selection: AppIconVariant
    @Environment(\.palette) private var pal

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppIconVariant.allCases) { variant in
                let selected = variant == selection
                Button { selection = variant } label: {
                    VStack(spacing: 4) {
                        if let image = variant.image {
                            Image(nsImage: image).resizable().frame(width: 64, height: 64)
                        }
                        Text(variant.title).font(Brand.text(11, selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .overlay {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(pal.toggleTint, lineWidth: 1.5).opacity(selected ? 1 : 0)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(variant.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct AlertSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var s = Settings.shared

    var body: some View {
        let hasBattery = model.battery != nil
        SettingsPane(height: hasBattery ? 760 : 380) {
            if hasBattery {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When it drops to")
                        ThresholdInput(values: $s.lowAlerts, range: 1...99)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("When it's charged to")
                        ThresholdInput(values: $s.highAlerts, range: 50...100)
                    }
                    Picker(selection: $s.fullScreenAt) {
                        Text("Off").tag(0)
                        ForEach([1, 2, 3, 5], id: \.self) { Text("\($0)%").tag($0) }
                    } label: {
                        Text("Full-screen alert at")
                        Text("Covers the screen until you dismiss it or plug in.")
                    }
                    Toggle("Charger connected", isOn: $s.onPlug)
                    Toggle("Charger disconnected", isOn: $s.onUnplug)
                    Toggle("Battery too hot", isOn: $s.heatAlert)
                } header: { SectionHead("Battery") }
            }
            Section {
                Toggle(isOn: $s.trackDevices) {
                    Text("Track devices")
                    Text("Off hides the Devices tab and stops reading AirPods, mice, keyboards and phones, Bluetooth included.")
                }
                Picker(selection: $s.deviceLowAt) {
                    Text("Off").tag(0)
                    ForEach([5, 10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                } label: {
                    Text("Low battery alert")
                    Text("For devices you haven't set up one by one. To change one device, click its row in Devices.")
                }
                .disabled(!s.trackDevices)
            } header: { SectionHead("Devices") }
            Section {
                Toggle(isOn: $s.glow) {
                    Text("Screen glow")
                    Text(s.minimalEnergy ? "Off while Minimal energy use is on." : "Flashes the screen edges in the alert's colour.")
                }
                .disabled(s.minimalEnergy)
                Toggle("Keep alerts until clicked", isOn: $s.persistent)
            } header: { SectionHead("Style") }
        }
    }
}

struct SoundSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var s = Settings.shared

    private func pickers(_ kinds: [AlertSound], off: Bool = false) -> some View {
        ForEach(kinds) { SoundPicker(kind: $0, presenter: model.alerts.presenter).disabled(!s.soundsOn || off) }
    }

    var body: some View {
        let hasBattery = model.battery != nil
        SettingsPane(height: hasBattery ? 840 : 540) {
            Section {
                Toggle(isOn: $s.soundsOn) {
                    Text("Play sounds")
                    Text("Each alert has its own sound, so you can tell them apart without looking. Picking one plays it; Option-click an alert's name, or Option-pick a sound, to also see a test alert.")
                }
                Button("Restore default sounds") { s.alertSounds = [:] }
                    .disabled(s.alertSounds.isEmpty)
            }
            if hasBattery {
                Section { pickers([.plug, .charged, .unplug, .low, .critical, .warning]) } header: { SectionHead("Battery") }
            }
            Section {
                pickers([.deviceLow, .deviceFull], off: !s.trackDevices)
            } header: { SectionHead("Devices") } footer: {
                if !s.trackDevices { Text("Track devices is off in Alerts.").font(Brand.text(11)).foregroundStyle(.secondary) }
            }
            Section { pickers([.lowPower, .update, .installed]) } header: { SectionHead("Other") }
        }
    }
}

struct UpdateSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var s = Settings.shared

    var body: some View {
        SettingsPane(height: 300) {
            Section {
                Toggle(isOn: $s.updateCheck) {
                    Text("Check for new versions")
                    Text("Asks GitHub a few times a day. A new version shows as a banner in the menu.")
                }
                Toggle(isOn: Binding(get: { s.updateCheck && s.updateAlert }, set: { s.updateAlert = $0 })) {
                    Text("Alert about new versions")
                    Text("Once per version. Stays until you click or close it, even with Keep alerts off.")
                }
                .disabled(!s.updateCheck)
                let installer = model.installer
                let canAuto = installer.keyPresent && !installer.homebrew
                Toggle(isOn: Binding(get: { s.updateCheck && canAuto && s.autoInstall }, set: { s.autoInstall = $0 })) {
                    Text("Install updates automatically")
                    Text(installer.homebrew ? "Installed with Homebrew, so brew updates it: \(UpdateInstaller.brewCommand)."
                         : !installer.keyPresent ? "Not available in this build: it has no update signing key, so it can't verify downloads."
                         : "Checks the release's signature, replaces the app and relaunches it. With the charge-limit helper, no password.")
                }
                .disabled(!s.updateCheck || !canAuto)
            } header: { SectionHead("New versions") }
        }
    }
}

/// One alert's sound. Picking one plays it, so you hear what you chose.
/// With Option held, a click on the name or a pick from the menu also shows a test alert of that kind, which plays the sound itself.
private struct SoundPicker: View {
    let kind: AlertSound
    let presenter: AlertPresenter
    @ObservedObject var s = Settings.shared

    private func preview() { presenter.show(AlertSpec.sample(kind)) }

    var body: some View {
        Picker(selection: Binding(get: { s.sound(for: kind) }, set: { v in
            s.setSound(v, for: kind)
            if NSEvent.modifierFlags.contains(.option) { preview() } else { NSSound(named: NSSound.Name(v))?.play() }
        })) {
            Text(Settings.noSound).tag(Settings.noSound)
            Divider()
            ForEach(Settings.sounds, id: \.self) { name in
                Text(name).tag(name)
            }
        } label: {
            Text(kind.title).onOptionClick(preview)
            if let detail = kind.detail { Text(detail).onOptionClick(preview) }
        }
        .help("Option-click to try this alert")
    }
}

private extension View {
    func onOptionClick(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture { if NSEvent.modifierFlags.contains(.option) { action() } }
    }
}

struct AboutSettings: View {
    @ObservedObject var model: AppModel

    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }

    /// Underline: in secondary text, color alone isn't enough for a link to read as a link.
    private func link(_ title: String, _ url: String) -> AttributedString {
        var text = AttributedString(title)
        text.link = URL(string: url)
        text.underlineStyle = .single
        return text
    }

    var body: some View {
        SettingsPane(height: 322) {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lynx Battery").font(Brand.text(15, .semibold))
                        Text("Version \(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))").foregroundStyle(.secondary)
                        Text("© 2026 Designed & developed by")
                            .foregroundStyle(.secondary)
                        Text("\(link("Etherlynx Studio", "https://etherlynx.xyz/")) & \(link("Ihor Kharkholyuk", "https://kharkholy.uk"))")
                            .foregroundStyle(.secondary)
                        Text("Made with Claude").font(Brand.text(11)).foregroundStyle(.secondary).padding(.top, 2)
                    }
                }
            }
            Section {
                LabeledContent {
                    Button("Quit") { NSApp.terminate(nil) }
                } label: {
                    Text("Quit Lynx Battery")
                    // The limit is held by the root helper, it doesn't need the app
                    Text(model.charge.installed
                         ? "Alerts and the menu bar icon stop until you open it again. The charge limit keeps working."
                         : "Alerts and the menu bar icon stop until you open it again.")
                }
            }
        }
    }
}

/// Thresholds — selected values as chips with a cross, plus an input field: "15" or "15, 25".
struct ThresholdInput: View {
    @Binding var values: Set<Int>
    let range: ClosedRange<Int>
    @State private var text = ""
    @State private var bad = false
    @FocusState private var focused: Bool
    @Environment(\.palette) private var pal

    var body: some View {
        FlowRow(spacing: 6) {
            ForEach(values.sorted(), id: \.self) { v in
                Button { values.remove(v) } label: {
                    HStack(spacing: 5) {
                        Text("\(v)%").font(Brand.text(11.5, .medium)).monospacedDigit()
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).opacity(0.6)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(pal.fg, in: Capsule())
                    .foregroundStyle(pal.bg)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(v)%")
            }
            HStack(spacing: 2) {
                // In a Form the field title becomes a label, so the hint is only the prompt
                TextField("", text: $text, prompt: Text("Add %"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(Brand.text(11.5, .medium))
                    .frame(width: 56)
                    .focused($focused)
                    .onSubmit(add)
                    .onChange(of: text) { bad = false }
                    .onChange(of: focused) { _, on in if !on { add() } }
                Text("\(range.lowerBound)–\(range.upperBound)").font(Brand.text(9.5)).foregroundStyle(bad ? Brand.signal : pal.muted)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(pal.fg.opacity(0.07), in: Capsule())   // pal.sunk blends into the form card
            .overlay(Capsule().strokeBorder(bad ? Brand.signal : .clear))
        }
    }

    private func add() {
        let nums = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !nums.isEmpty || !text.isEmpty else { return }   // an empty field isn't an error
        let ok = nums.filter { range.contains($0) }
        values.formUnion(ok)
        if ok.count == nums.count && !nums.isEmpty { text = "" } else { bad = true }
    }
}

/// Simple line wrapping for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: maxW, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}
