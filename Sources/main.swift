import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, SettingsOpener {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private let model = AppModel()
    private var bag = Set<AnyCancellable>()
    private var monitor: Any?

    private var animTimer: Timer?
    private var phase = 0
    private var sweepFrames = 0
    private var wasCharging = false
    private lazy var settingsWindow = SettingsWindow(model: model)

    func applicationDidFinishLaunching(_ n: Notification) {
        Brand.registerFonts()
        AppMenu.installMainMenu()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize   // поповер іде за висотою вмісту при зміні вкладок
        popover.contentViewController = host

        model.onChange = { [weak self] in self?.updateIcon() }
        Settings.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.model.refresh() } }
            .store(in: &bag)
        model.start()

        // Відкрити поповер ззовні (для перевірки розміру без кліку по меню-бару)
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("xyz.etherlynx.battery.open"), object: nil, queue: .main) { [weak self] n in
            if let tab = (n.object as? String).flatMap(AppModel.Tab.init(rawValue:)) { self?.model.tab = tab }
            if self?.popover.isShown == false { self?.toggle() }
        }
    }

    func applicationWillTerminate(_ n: Notification) { model.history.save() }

    @objc func openSettings() {
        popover.performClose(nil)
        settingsWindow.show()
    }

    func popoverWillShow(_ n: Notification) { setPopoverShown(true) }
    func popoverDidClose(_ n: Notification) { setPopoverShown(false) }

    private func setPopoverShown(_ shown: Bool) {
        model.popoverShown = shown
        model.charge.setVisible(shown)
    }

    private func updateIcon() {
        guard let button = item.button else { return }
        guard let b = model.battery else {
            let (img, title) = MenuIcon.desktop(devices: model.devices, watts: model.macWatts)
            button.image = img
            button.attributedTitle = title
            let tip = [model.macWatts.map { "Mac draw: \(Int($0.rounded())) W" },
                       model.devices.first(where: { $0.lowest != nil }).map { "\($0.name): \($0.lowest!)%" }].compactMap { $0 }
            button.toolTip = tip.isEmpty ? "No battery · on power" : tip.joined(separator: "\n")
            return
        }
        let style = Settings.shared.iconStyle
        // Смуга біжить по іконці три проходи після підключення, далі — статична блискавка.
        // Постійна анімація коштувала 2–3 % CPU: менюбар-апка не має так їсти батарею, яку стереже.
        if b.isCharging && !wasCharging && Settings.shared.animateCharging && animTimer == nil {
            sweepFrames = 30
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] t in
                guard let self else { return }
                self.sweepFrames -= 1
                self.phase = (self.phase + 1) % 10
                if self.sweepFrames <= 0 { t.invalidate(); self.animTimer = nil }
                self.updateIcon()
            }
        }
        if !b.isCharging { animTimer?.invalidate(); animTimer = nil }
        wasCharging = b.isCharging
        let animating = animTimer != nil
        let onWall = b.onAC && model.charge.holdingOnWall
        button.image = MenuIcon.withStatus(MenuIcon.image(for: b, style: style, phase: animating ? phase : -1, holdingOnWall: onWall), for: b)
        if style == .beside {
            button.attributedTitle = NSAttributedString(string: " \(b.percent)%", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: MenuIcon.color(for: b, holdingOnWall: onWall) ?? NSColor.labelColor,
            ])
        } else {
            button.title = ""
        }
        button.toolTip = onWall ? "\(b.percent)% · Holding the limit on wall power" : "\(b.percent)% · \(b.statusLine)"
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        // ПКМ — швидкий перемикач енергозбереження; без батареї просто відкриває поповер
        if NSApp.currentEvent?.type == .rightMouseUp, model.battery != nil {
            model.toggleLowPower()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            model.refreshDevices()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
