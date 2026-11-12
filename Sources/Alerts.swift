import AppKit
import SwiftUI

struct AlertSpec {
    enum Tone { case low, critical, good, neutral, saver }
    var title: String
    var subtitle: String
    var symbol: String
    var tone: Tone
    /// Кнопки-вибір праворуч від тексту; перша — основна.
    var buttons: [String] = []
    /// Хрестик праворуч: закрити, не виконуючи дію пігулки.
    var closable = false

    var color: Color {
        switch tone {
        case .low: Brand.signal
        case .critical: Brand.signal
        case .good: Brand.mist
        case .neutral: Brand.skyMid
        case .saver: Color(nsColor: .systemYellow)
        }
    }
}

/// Порівнює попередній і новий стан та вирішує, що показати.
final class AlertEngine {
    private var prev: BatterySnapshot?
    private var mode: PercentMode?
    private var firedLow: Set<Int> = []
    private var high = HighAlertTracker()
    private var firedDevices: Set<String> = []
    let presenter = AlertPresenter()
    private var s: Settings { .shared }

    func evaluate(_ b: BatterySnapshot) {
        defer { prev = b }
        evaluateHeat(b)
        // Повноекранний поріг — теж поріг: інакше на 3 % після вже пройдених 5 % нічого не спрацює
        let low = s.fullScreenAt > 0 ? s.lowAlerts.union([s.fullScreenAt]) : s.lowAlerts
        if mode != s.percentMode {
            // Старт або зміна режиму: вважаємо вже пройденими пороги, за якими ми зараз стоїмо, щоб не спамити.
            // Після перемикання число стрибає, хоча заряд той самий — це не привід сповіщати.
            mode = s.percentMode
            firedLow = Set(low.filter { b.percent <= $0 })
            high.start(s.highAlerts, b)
        }
        guard let p = prev else { return }

        if b.onAC != p.onAC {
            if b.onAC {
                presenter.dismissFullScreen()
                if s.onPlug {
                    presenter.show(AlertSpec(title: "Charging", subtitle: "\(b.percent)%" + (b.adapterWatts.map { " · \($0) W adapter" } ?? " · adapter connected"),
                                             symbol: "bolt.fill", tone: .good))
                }
            } else if s.onUnplug {
                presenter.show(AlertSpec(title: "On battery", subtitle: "\(b.percent)%" + (b.minutes.map { " · \(formatMinutes($0)) left" } ?? " · adapter disconnected"),
                                         symbol: "powerplug.fill", tone: .neutral))
            }
        }

        // Низький заряд: спрацьовує, коли рівень опускається до порогу без зарядки.
        if !b.onAC {
            for t in low.sorted() where b.percent <= t && !firedLow.contains(t) {
                firedLow.formUnion(low.filter { $0 >= t })
                if s.fullScreenAt > 0 && b.percent <= s.fullScreenAt {
                    presenter.showFullScreen(percent: b.percent)
                } else {
                    let critical = t <= 5
                    presenter.show(AlertSpec(title: "\(b.percent)% left",
                                             subtitle: b.minutes.map { "About \(formatMinutes($0)) to go" } ?? "Time to plug in",
                                             symbol: critical ? "battery.0percent" : "battery.25percent",
                                             tone: critical ? .critical : .low))
                }
                break
            }
        }
        firedLow = firedLow.filter { b.percent <= $0 + 2 }   // скидаємо, коли піднялись вище порогу

        // Високий заряд: при зарядці.
        if let t = high.update(s.highAlerts, b) {
            presenter.show(AlertSpec(title: HighAlertTracker.title(t, b),
                                     subtitle: "You can unplug now", symbol: "battery.100percent.bolt", tone: .good))
        }
    }

    private var firedFull: Set<String> = []
    private var firedHeat = false

    func evaluate(devices: [BTDevice]) {
        for d in devices {
            let r = s.rule(d.name)
            guard !r.hidden, let lvl = d.lowest else { continue }
            if r.low > 0, lvl <= r.low, !firedDevices.contains(d.name) {
                firedDevices.insert(d.name)
                presenter.show(AlertSpec(title: "\(d.name): \(lvl)%", subtitle: "Running low — charge it soon",
                                         symbol: d.symbol, tone: lvl <= 5 ? .critical : .low))
            } else if lvl > r.low + 5 {
                firedDevices.remove(d.name)
            }
            if r.full, lvl >= 100, !firedFull.contains(d.name) {
                firedFull.insert(d.name)
                presenter.show(AlertSpec(title: "\(d.name) charged", subtitle: "100% — take it off the charger",
                                         symbol: d.symbol, tone: .good))
            } else if lvl < 95 {
                firedFull.remove(d.name)
            }
        }
    }

    func evaluateHeat(_ b: BatterySnapshot) {
        guard s.heatAlert, let t = b.temperature else { return }
        if t >= 42, !firedHeat {
            firedHeat = true
            presenter.show(AlertSpec(title: String(format: "Battery hot · %.0f°", t),
                                     subtitle: "Let the Mac cool down — heat wears the battery", symbol: "thermometer.high", tone: .critical))
        } else if t < 38 { firedHeat = false }
    }

    private var firedWeak = false
    private var weakCharger = WeakChargerTracker()
    func evaluateCharger(_ b: inout BatterySnapshot) {
        b.chargerTooWeak = weakCharger.update(b)
        if b.chargerTooWeak, !firedWeak {
            firedWeak = true
            presenter.show(AlertSpec(title: "Charger can't keep up",
                                     subtitle: String(format: "The Mac draws %.0f W and the battery still drains", b.systemWatts),
                                     symbol: "exclamationmark.triangle.fill", tone: .low))
        } else if !b.chargerTooWeak { firedWeak = false }
    }

    /// Нова версія: висить, доки не клацнуть (відкриває реліз) або не закриють (тоді пропонуємо вимкнути такі сповіщення).
    func announceUpdate(_ r: ReleaseInfo) {
        presenter.show(AlertSpec(title: "Lynx Battery \(r.version)", subtitle: "A new version is out · click to download",
                                 symbol: "arrow.down", tone: .neutral, closable: true), sticky: true) { [weak self] hit in
            switch hit {
            case .body: NSWorkspace.shared.open(r.url)
            case .close:
                // Після того як пігулка відлетить
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.offerToMuteUpdates() }
            case .button: break
            }
        }
    }

    private func offerToMuteUpdates() {
        guard s.updateAlert else { return }
        presenter.show(AlertSpec(title: "Stop update alerts?", subtitle: "New versions still show in the menu",
                                 symbol: "bell.slash", tone: .neutral, buttons: ["Turn off", "Keep"]),
                       hideAfter: 8, quiet: true) { [weak self] hit in
            if hit == .button(0) { self?.s.updateAlert = false }
        }
    }
}

/// Куди клацнули на пігулці.
enum PillHit: Equatable { case body, close, button(Int) }

// MARK: - Показ

final class AlertPresenter: NSObject {
    /// Що показано: звичайна пігулка зникає сама, sticky — лише від кліку чи хрестика, хай що в «Keep alerts».
    private struct Request {
        var spec: AlertSpec
        var sticky = false
        var hideAfter: Double?
        var onHit: ((PillHit) -> Void)?
    }
    private var current: Request?
    /// Sticky-пігулка, яку на час затулила інша: повертається, щойно та зникне.
    private var parked: Request?
    private var pill: NSPanel?
    private var glow: NSWindow?
    private var full: NSWindow?
    private var hideWork: DispatchWorkItem?

    private func playSound() {
        let name = Settings.shared.sound
        guard name != "None" else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    private var interacting = false

    func show(_ spec: AlertSpec) { present(Request(spec: spec), quiet: false) }

    /// sticky: не зникає сама. hideAfter: власна затримка для звичайної. onHit: клік по тілу, хрестику чи кнопці.
    func show(_ spec: AlertSpec, sticky: Bool = false, hideAfter: Double? = nil, quiet: Bool = false, onHit: @escaping (PillHit) -> Void) {
        present(Request(spec: spec, sticky: sticky, hideAfter: hideAfter, onHit: onHit), quiet: quiet)
    }

    private func present(_ req: Request, quiet: Bool) {
        let spec = req.spec
        if !quiet { playSound() }
        guard let screen = NSScreen.main else { return }
        hideWork?.cancel()
        if req.sticky { parked = nil } else if let cur = current, cur.sticky, pill != nil { parked = cur }
        pill?.orderOut(nil)
        current = req
        interacting = false

        // Велике прозоре полотно: пігулка тягнеться за курсором і не обрізається.
        // Кліки крізь повністю прозорі пікселі macOS пропускає до вікон під ним.
        let margin: CGFloat = 130
        let probe = NSHostingView(rootView: PillBody(spec: spec))
        let pillSize = probe.fittingSize
        let size = NSSize(width: pillSize.width + margin * 2, height: pillSize.height + margin * 2)
        let vf = screen.visibleFrame
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - pillSize.height - 14 - margin)

        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = JellyPill(spec: spec,
                             onInteract: { [weak self] on in
                                 self?.interacting = on
                                 if !on { self?.scheduleHide(after: max(1.6, (req.hideAfter ?? 3.2) / 2)) }
                             },
                             onHit: { hit in req.onHit?(hit) },
                             onDismiss: { [weak self, weak panel] in
                                 guard let panel else { return }
                                 panel.orderOut(nil)
                                 guard let self, self.pill === panel else { return }
                                 self.pill = nil
                                 self.current = nil
                                 if let p = self.parked { self.parked = nil; self.present(p, quiet: true) }
                             })
        panel.contentView = FirstMouseHostingView(rootView: view.frame(width: size.width, height: size.height))
        panel.orderFrontRegardless()
        pill = panel
        if !quiet && Settings.shared.glow && !Settings.shared.minimalEnergy { flashGlow(spec.color, on: screen) }
        scheduleHide(after: req.hideAfter ?? 3.2)
    }

    private func scheduleHide(after seconds: Double) {
        guard !Settings.shared.persistent, current?.sticky != true else { return }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.interacting, let panel = self.pill else { return }
            NotificationCenter.default.post(name: .pillShouldLeave, object: panel)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func flashGlow(_ color: Color, on screen: NSScreen) {
        glow?.orderOut(nil)
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = NSHostingView(rootView: GlowView(color: color))
        w.alphaValue = 0
        w.orderFrontRegardless()
        glow = w
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; w.animator().alphaValue = 1 }) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 1.6; w.animator().alphaValue = 0 }) {
                w.orderOut(nil)
            }
        }
    }

    func showFullScreen(percent: Int) {
        playSound()
        guard full == nil, let screen = NSScreen.main else { return }
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.level = .screenSaver
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: FullScreenAlertView(percent: percent) { [weak self] in self?.dismissFullScreen() })
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; w.animator().alphaValue = 1 }
        full = w
    }

    func dismissFullScreen() {
        guard let w = full else { return }
        full = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
    }
}

private final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

// MARK: - Вигляд сповіщень

extension Notification.Name { static let pillShouldLeave = Notification.Name("pillShouldLeave") }

private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Сама пігулка: глянцева чорна капсула, тонка обвідка й світіння кольором події.
struct PillBody: View {
    let spec: AlertSpec
    var onHit: (PillHit) -> Void = { _ in }
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.white)
                Image(systemName: spec.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(spec.tone == .low || spec.tone == .critical ? Brand.signal : Brand.ink)
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title)
                    .font(Brand.display(20))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                Text(spec.subtitle)
                    .font(Brand.text(13))
                    .foregroundStyle(.white.opacity(0.6))
            }
            if !spec.buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(spec.buttons.indices, id: \.self) { i in
                        Button { onHit(.button(i)) } label: {
                            Text(spec.buttons[i])
                                .font(Brand.text(12.5, .medium))
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(i == 0 ? Color.white : Color.white.opacity(0.14), in: Capsule())
                                .foregroundStyle(i == 0 ? Brand.ink : .white)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if spec.closable {
                Button { onHit(.close) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.14), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }
        }
        .padding(.leading, 8).padding(.trailing, spec.closable || !spec.buttons.isEmpty ? 12 : 30).padding(.vertical, 8)
        .fixedSize()
        .background(Capsule().fill(Brand.ink))
        .overlay(Capsule().strokeBorder(spec.color.opacity(0.85), lineWidth: 1.5))
        .shadow(color: spec.color.opacity(0.5), radius: 18)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
        .environment(\.colorScheme, .dark)
    }
}

/// Розтяг уздовж напрямку тягнення навколо центру: желе, а не просто зсув.
private struct Stretch: GeometryEffect {
    var amount: CGFloat
    var angle: CGFloat
    var animatableData: CGFloat { get { amount } set { amount = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let t = CGAffineTransform(translationX: c.x, y: c.y)
            .rotated(by: angle)
            .scaledBy(x: amount, y: 1 / sqrt(amount))
            .rotated(by: -angle)
            .translatedBy(x: -c.x, y: -c.y)
        return ProjectionTransform(t)
    }
}

/// Пігулка як у рілсі: важка, тягнеться за курсором, а позаду біжить шлейф контурів-«відлунь»,
/// що наздоганяють її з різною затримкою (кожен шар — свій, повільніший спринг).
/// Один контур шлейфу: своя, повільніша пружина — тому відстає від пігулки.
private struct EchoLayer: View {
    let index: Int
    let size: CGSize
    let offset: CGSize
    let stretch: CGFloat
    let angle: CGFloat
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        let k = Double(index)
        let spring = Animation.interpolatingSpring(stiffness: 210 - k * 30, damping: 15 + k * 1.5)
        let line: Color = Color.white.opacity(0.55 - k * 0.08)
        return Capsule()
            .strokeBorder(line, lineWidth: 1.2)
            .background(Capsule().fill(Brand.ink.opacity(0.25)))
            .frame(width: size.width, height: size.height)
            .modifier(Stretch(amount: stretch, angle: angle))
            .scaleEffect(scale)
            .offset(offset)
            .opacity(opacity * 0.9)
            .animation(spring, value: offset)
            .animation(spring, value: stretch)
            .animation(.easeOut(duration: 0.3), value: opacity)
    }
}

struct JellyPill: View {
    let spec: AlertSpec
    let onInteract: (Bool) -> Void
    var onHit: (PillHit) -> Void = { _ in }
    let onDismiss: () -> Void

    @State private var offset: CGSize = CGSize(width: 0, height: -90)
    @State private var stretch: CGFloat = 1
    @State private var angle: CGFloat = .pi / 2
    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0
    @State private var dragging = false
    @State private var leaving = false
    @State private var pillSize: CGSize = .zero

    private let echoes = 5

    var body: some View {
        ZStack {
            // Шлейф: контури тієї ж капсули, кожен відстає сильніше за попередній
            ForEach((1...echoes).reversed(), id: \.self) { i in
                EchoLayer(index: i, size: pillSize, offset: offset, stretch: stretch, angle: angle, scale: scale, opacity: opacity)
            }

            PillBody(spec: spec, onHit: { hit in
                guard !leaving else { return }
                onHit(hit)
                leave(squash: true)
            })
                .background(GeometryReader { g in Color.clear.onAppear { pillSize = g.size } })
                .modifier(Stretch(amount: stretch, angle: angle))
                .scaleEffect(scale)
                .offset(offset)
                .opacity(opacity)
                .animation(dragging ? .interactiveSpring(response: 0.14, dampingFraction: 0.75)
                                    : .interpolatingSpring(stiffness: 260, damping: 13), value: offset)
                .animation(.interpolatingSpring(stiffness: 300, damping: 11), value: stretch)
                .animation(.interpolatingSpring(stiffness: 240, damping: 16), value: scale)
                .animation(.easeOut(duration: 0.22), value: opacity)
                .onContinuousHover { phase in
                    guard !dragging, !leaving else { return }
                    // Магніт: пігулка злегка тягнеться до курсора
                    switch phase {
                    case .active(let p):
                        let dx = p.x - pillSize.width / 2, dy = p.y - pillSize.height / 2
                        offset = CGSize(width: dx * 0.08, height: dy * 0.12)
                        angle = atan2(dy, dx)
                        stretch = 1.03
                    case .ended:
                        offset = .zero; stretch = 1
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in
                            dragging = true
                            onInteract(true)
                            let t = v.translation
                            let len = hypot(t.width, t.height)
                            // Гумова стрічка: що далі тягнеш — то тугіше
                            let k = 150 * (1 - 1 / (len / 220 + 1)) / max(len, 0.001)
                            offset = CGSize(width: t.width * k, height: t.height * k)
                            angle = atan2(t.height, t.width)
                            stretch = 1 + min(0.5, len / 420)
                        }
                        .onEnded { v in
                            dragging = false
                            let t = v.translation
                            let vel = v.predictedEndTranslation
                            if hypot(t.width, t.height) < 4 {
                                guard !leaving else { return }
                                onHit(.body)
                                leave(squash: true)
                            } else if vel.height < -260 || hypot(vel.width, vel.height) > 900 {
                                guard !leaving else { return }
                                onHit(.close)   // відкинули — те саме, що закрили
                                fling(vel)
                            } else {
                                onInteract(false)
                                offset = .zero      // пружно назад, шлейф догоняє
                                stretch = 1
                            }
                        }
                )
        }
        .onAppear {
            // Падає згори з розтягом, перелітає й погойдується; шлейф тягнеться за нею
            stretch = 1.25
            DispatchQueue.main.async {
                offset = .zero; scale = 1; opacity = 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { stretch = 0.92 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { stretch = 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pillShouldLeave)) { _ in leave(squash: false) }
    }

    private func leave(squash: Bool) {
        guard !leaving else { return }
        leaving = true
        angle = .pi / 2
        if squash { stretch = 0.85 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (squash ? 0.08 : 0)) {
            stretch = 1.2
            offset = CGSize(width: 0, height: -70)
            scale = 0.8
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onDismiss() }
    }

    private func fling(_ v: CGSize) {
        guard !leaving else { return }
        leaving = true
        angle = atan2(v.height, v.width)
        stretch = 1.35
        offset = CGSize(width: v.width * 1.2, height: v.height * 1.2)
        opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onDismiss() }
    }
}

struct GlowView: View {
    let color: Color
    var body: some View {
        GeometryReader { g in
            let r = RoundedRectangle(cornerRadius: 14)
            r.strokeBorder(color, lineWidth: 26).blur(radius: 30)
                .overlay(r.strokeBorder(color.opacity(0.6), lineWidth: 4).blur(radius: 6))
                .frame(width: g.size.width, height: g.size.height)
        }
        .ignoresSafeArea()
    }
}

struct FullScreenAlertView: View {
    let percent: Int
    let dismiss: () -> Void
    var body: some View {
        ZStack {
            LinearGradient(colors: [Brand.skyTop, Brand.skyMid, Brand.skyLow], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    LynxMark().frame(width: 22, height: 22)
                    Text("Lynx Battery").font(Brand.text(16, .semibold)).foregroundStyle(Brand.ink)
                }
                .padding(.top, 48)
                Spacer()
                Text("\(percent)%")
                    .font(Brand.display(240))
                    .tracking(-12)
                    .foregroundStyle(Brand.signal)
                Text("Your Mac is about to shut down.")
                    .font(Brand.display(44)).tracking(-1.2)
                    .foregroundStyle(Brand.ink)
                Text("Plug in the charger.")
                    .font(Brand.display(44)).tracking(-1.2)
                    .foregroundStyle(Brand.ink.opacity(0.45))
                InkPillLarge(title: "Got it", action: dismiss)
                    .keyboardShortcut(.defaultAction)
                    .padding(.top, 40)
                Spacer()
            }
            .padding(.horizontal, 96)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .ignoresSafeArea()
    }
}

private struct InkPillLarge: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(title).font(Brand.text(17, .medium))
                ZStack {
                    Circle().fill(.white)
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Brand.ink)
                }
                .frame(width: 38, height: 38)
            }
            .padding(.leading, 26).padding(.trailing, 6).padding(.vertical, 6)
            .background(Brand.ink, in: Capsule())
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
