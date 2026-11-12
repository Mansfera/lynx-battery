import AppKit
import SwiftUI

// Налаштування — окреме системне вікно, а не сторінка в поповері: поповер закривається від кліку поруч,
// а тут зручно міняти стиль іконки й одразу бачити її в меню-барі.

/// Дія йде ланцюжком відповідачів до AppDelegate; він у main.swift, якого немає в тестових збірках.
@objc protocol SettingsOpener { func openSettings() }

enum AppMenu {
    /// Головне меню LSUIElement-апка не показує, але лише через нього працюють ⌘, ⌘W ⌘Q і ⌘C ⌘V у полях вводу.
    /// Дії без target ідуть ланцюжком відповідачів до NSApp і AppDelegate.
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
        // LSUIElement-апка сама не активується: без цього вікно відкриється за чужими
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(nil)   // не вмикати курсор у полі порогів при кожному відкритті
    }

    func make() -> NSWindow {
        // Вкладки в тулбарі, як у системних апок: усе разом — понад 1000 pt, нижні секції ховались би за краєм
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(tab("General", symbol: "gearshape", GeneralSettings(model: model)))
        tabs.addTabViewItem(tab("Alerts", symbol: "bell", AlertSettings(model: model)))
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
        host.sizingOptions = .preferredContentSize   // вікно йде за висотою вкладки
        host.title = label                           // заголовок вікна — назва вкладки, як у системних апок
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    /// Закриття забирає фокус із поля порогів, і введене значення додається, а не губиться.
    func windowWillClose(_ n: Notification) { window?.makeFirstResponder(nil) }
}

/// Спільне оформлення вкладки. Висота задана: у Form немає власної, а на малому екрані вона прокрутиться.
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

/// Без хелпера перемикач вимкнений і показує «вимкнено», але вибір зберігається на випадок, якщо хелпер повернеться.
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
        SettingsPane(height: hasBattery ? 612 : 402) {
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
                // Без батареї в меню-барі лише значок пристрою — стиль і анімація нічого не змінять
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

/// Значки в ряд, щоб вибирати за виглядом, а не за назвою.
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
        SettingsPane(height: hasBattery ? 1000 : 582) {
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
                Picker("Sound", selection: $s.sound) {
                    ForEach(Settings.sounds, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: s.sound) { _, v in NSSound(named: NSSound.Name(v))?.play() }
                Toggle(isOn: $s.glow) {
                    Text("Screen glow")
                    Text(s.minimalEnergy ? "Off while Minimal energy use is on." : "Flashes the screen edges in the alert's colour.")
                }
                .disabled(s.minimalEnergy)
                Toggle("Keep alerts until clicked", isOn: $s.persistent)
            } header: { SectionHead("Style") }
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
            } header: { SectionHead("Updates") }
        }
    }
}

struct AboutSettings: View {
    @ObservedObject var model: AppModel

    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }

    /// Підкреслення: у вторинному тексті самого кольору замало, щоб посилання читалось як посилання.
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
                    // Ліміт тримає root-хелпер, йому апка не потрібна
                    Text(model.charge.installed
                         ? "Alerts and the menu bar icon stop until you open it again. The charge limit keeps working."
                         : "Alerts and the menu bar icon stop until you open it again.")
                }
            }
        }
    }
}

/// Пороги — вибрані значення чипами з хрестиком і поле вводу: «15» або «15, 25».
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
                // У Form заголовок поля стає підписом, тож підказка — лише prompt
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
            .background(pal.fg.opacity(0.07), in: Capsule())   // pal.sunk зливається з карткою форми
            .overlay(Capsule().strokeBorder(bad ? Brand.signal : .clear))
        }
    }

    private func add() {
        let nums = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !nums.isEmpty || !text.isEmpty else { return }   // порожнє поле — не помилка
        let ok = nums.filter { range.contains($0) }
        values.formUnion(ok)
        if ok.count == nums.count && !nums.isEmpty { text = "" } else { bad = true }
    }
}

/// Простий перенос рядків для чипів.
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
