import SwiftUI

// Система etherlynx.xyz: біле тло, небесна сцена для головного, білі панелі з волосяною рамкою,
// рядок статистики з роздільниками, Ink-пігулки. Поповер ніколи не вищий за екран — вміст прокручується.

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let pal = Palette(scheme: scheme)
        MainPage(model: model)
            .frame(width: 372)
            .background(pal.bg)
            .foregroundStyle(pal.fg)
            .environment(\.palette, pal)
            .font(Brand.text(12))
    }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette(scheme: .light) }
extension EnvironmentValues {
    var palette: Palette { get { self[PaletteKey.self] } set { self[PaletteKey.self] = newValue } }
}

/// Прокрутка, що стискається до висоти вмісту, але не більша за екран.
/// ScrollView + maxHeight + fixedSize дає попoверу справжню висоту: коротке — як є, довге — до межі й прокрутка.
/// (ViewThatFits тут не годиться: sizeThatFits віддає максимум навіть для короткого вмісту.)
struct FitScroll<Content: View>: View {
    @ViewBuilder var content: Content
    /// Увесь екран під меню-баром мінус хром поповера (вкладки, підвал, відступи, стрілка).
    static var maxHeight: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 170) }
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) { content }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Поверхні

/// Біла панель із волосяною рамкою (r 20), як картки на сайті.
struct Panel<Content: View>: View {
    @Environment(\.palette) private var pal
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(pal.panel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(pal.line))
    }
}

/// Сцена (r 28): небесний градієнт — лише для головного блока екрана.
struct Stage<Content: View>: View {
    @Environment(\.palette) private var pal
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(pal.stage.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
    }
}

// MARK: - Головна

struct MainPage: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TopBar(model: model).fixedSize(horizontal: false, vertical: true).layoutPriority(2)
            FitScroll {
                Group {
                    if let b = model.battery {
                        switch model.tab {
                        case .overview: OverviewTab(model: model, b: b)
                        case .charge: ChargeTab(control: model.charge, b: b)
                        case .power: PowerTab(model: model, b: b)
                        case .devices: DevicesTab(model: model)
                        }
                    } else if model.tab == .devices {
                        DevicesTab(model: model)
                    } else {
                        PowerTab(model: model, b: nil)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .padding(12)
    }
}

struct TopBar: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 2) {
            // Без батареї лишаються потужність і пристрої
            ForEach(model.battery == nil ? [AppModel.Tab.power, .devices] : AppModel.Tab.allCases) { t in
                let on = model.tab == t
                Button { model.tab = t; if t == .power { model.sampleEnergy() } } label: {
                    Text(t.rawValue)
                        .font(Brand.text(12.5, .medium))
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(on ? pal.fg : .clear, in: Capsule())
                        .foregroundStyle(on ? pal.bg : pal.muted)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button { NSApp.sendAction(#selector(SettingsOpener.openSettings), to: nil, from: nil) } label: {
                ZStack {
                    Circle().fill(pal.fg)
                    Image(systemName: "gearshape.fill").font(.system(size: 13)).foregroundStyle(pal.bg)
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
    }
}

// MARK: Overview

struct OverviewTab: View {
    @ObservedObject var model: AppModel
    let b: BatterySnapshot

    var body: some View {
        VStack(spacing: 10) {
            HeroStage(b: b)
            StatsRow(b: b, drain: model.history.drainPerHour(.day))
            if b.needsService { ServicePanel(b: b) }
            DotHistoryPanel(model: model)
            LowPowerRow(model: model, b: b)
        }
    }
}

struct HeroStage: View {
    let b: BatterySnapshot
    @Environment(\.palette) private var pal
    var body: some View {
        Stage {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(b.percent)")
                        .font(Brand.display(84))
                        .tracking(-4)
                        .monospacedDigit()
                        .foregroundStyle(b.percent <= 20 && !b.onAC ? Brand.signal : pal.fg)
                        .contentTransition(.numericText())
                    Text("%").font(Brand.display(30)).foregroundStyle(pal.fg.opacity(0.55))
                    Spacer()
                    if b.isCharging || b.lowPower || b.onAC {
                        Image(systemName: b.isCharging ? "bolt.fill" : (b.lowPower ? "leaf.fill" : "powerplug.fill"))
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(pal.state(b))
                    }
                }
                .frame(height: 78)
                TickRuler(percent: b.percent, color: pal.state(b), top: Settings.shared.percentMode == .ofDesign ? b.designTop : 100)
                Text(b.statusLine).font(Brand.text(13, .medium))
                    .foregroundStyle(b.chargerTooWeak ? Brand.signal : pal.fg.opacity(0.7))
                if Settings.shared.percentMode != .macOS && b.macPercent != b.percent {
                    Text("\(Settings.shared.percentMode.rawValue) · macOS shows \(b.macPercent)%")
                        .font(Brand.text(11)).foregroundStyle(pal.fg.opacity(0.5))
                }
            }
        }
    }
}

/// Лінійка з рисками: пройдене — лінією, поточний рівень — крапкою.
/// top < 100 — стеля зношеної батареї: вище неї шкала приглушена, бо туди заряд уже не дійде.
struct TickRuler: View {
    let percent: Int
    var color: Color
    var top = 100
    @Environment(\.palette) private var pal
    var body: some View {
        Canvas { ctx, size in
            let n = 41
            let topX = size.width * CGFloat(top) / 100
            if top < 100 {
                ctx.fill(Path(CGRect(x: topX, y: size.height - 8, width: size.width - topX, height: 8)), with: .color(pal.fg.opacity(0.1)))
            }
            for i in 0..<n {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let major = i % 10 == 0
                let h: CGFloat = major ? 8 : 4
                ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)),
                         with: .color(pal.fg.opacity(x > topX ? 0.12 : (major ? 0.45 : 0.2))))
            }
            if top < 100 {
                ctx.fill(Path(CGRect(x: topX - 0.75, y: size.height - 12, width: 1.5, height: 12)), with: .color(pal.fg.opacity(0.75)))
            }
            let mx = size.width * CGFloat(percent) / 100
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1.5, width: mx, height: 1.5)), with: .color(color))
            ctx.fill(Path(ellipseIn: CGRect(x: mx - 4, y: 0, width: 8, height: 8)), with: .color(color))
        }
        .frame(height: 16)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            // Підпис стелі стоїть у тому ж рядку, тож сусідні числа поступаються йому місцем
            HStack {
                Text("0"); Spacer()
                Text("50").opacity(top < 100 && (43...57).contains(top) ? 0 : 1); Spacer()
                Text("100").opacity(top < 100 && top > 90 ? 0 : 1)
            }
            .font(Brand.mono(8, .regular)).foregroundStyle(pal.fg.opacity(0.5)).offset(y: 12)
        }
        .overlay {
            if top < 100 {
                GeometryReader { g in
                    Text("max \(top)").font(Brand.mono(8, .medium)).foregroundStyle(pal.fg.opacity(0.85)).fixedSize()
                        .position(x: min(4 + (g.size.width - 8) * CGFloat(top) / 100, g.size.width - 15), y: g.size.height + 7)
                }
            }
        }
        .padding(.bottom, 10)
    }
}

/// Рядок цифр із волосяними роздільниками — як статистика на volodymyr.buzz.
struct StatsRow: View {
    let b: BatterySnapshot
    let drain: Double?
    @Environment(\.palette) private var pal

    var body: some View {
        Panel(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Stat(value: "\(b.health)%", caption: "Health · \(b.fullCapacity) of \(b.designCapacity) mAh",
                         alert: b.health < 80)
                    Divider().overlay(pal.line)
                    Stat(value: "\(b.cycles)", caption: "Cycles · Apple rates it for \(b.designCycles)", alert: false)
                }
                Divider().overlay(pal.line)
                HStack(spacing: 0) {
                    Stat(value: b.temperature.map { String(format: "%.0f°", $0) } ?? "—", caption: tempNote,
                         alert: (b.temperature ?? 0) >= 40)
                    Divider().overlay(pal.line)
                    Stat(value: String(format: "%.1f W", b.isCharging ? b.watts : b.systemWatts),
                         caption: b.isCharging ? "Into the battery" : (drain.map { String(format: "Mac draw · ≈ %.0f%% an hour", $0) } ?? "Mac draw right now"),
                         alert: false)
                }
            }
        }
    }

    private var tempNote: String {
        guard let t = b.temperature else { return "Temperature · no sensor" }
        if t >= 40 { return "Hot — let it cool down" }
        if t < 10 { return "Temperature · cold" }
        return "Temperature · normal"
    }

    struct Stat: View {
        let value: String, caption: String, alert: Bool
        @Environment(\.palette) private var pal
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(Brand.display(28)).tracking(-0.8).monospacedDigit()
                    .foregroundStyle(alert ? Brand.signal : pal.fg)
                Text(caption).font(Brand.text(10.5)).foregroundStyle(pal.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}

struct ServicePanel: View {
    let b: BatterySnapshot
    @Environment(\.palette) private var pal
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 3) {
                Text("Service recommended").font(Brand.text(13, .semibold)).foregroundStyle(Brand.signal)
                Text(b.health < 80
                     ? "Capacity is down to \(b.health)% of new. Apple replaces batteries below 80%."
                     : "\(b.cycles) cycles — past the \(b.designCycles) Apple designs for.")
                    .font(Brand.text(11)).foregroundStyle(pal.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Історія як точкова матриця: стовпець — відрізок часу, висота — рівень.
struct DotHistoryPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal
    private let cols = 30, rows = 10

    var body: some View {
        let data = model.history.buckets(model.range, count: cols)
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Charge history").font(Brand.text(11, .medium)).foregroundStyle(pal.muted)
                    Spacer()
                    RangeSwitch(range: $model.range)
                }
                Canvas { ctx, size in
                    let step = size.width / CGFloat(cols)
                    let d = min(step, size.height / CGFloat(rows)) * 0.6
                    for c in 0..<cols {
                        let cell = data[c]
                        let lit = cell.map { Int((Double($0.level) / 10).rounded()) } ?? 0
                        for r in 0..<rows {
                            let x = CGFloat(c) * step + (step - d) / 2
                            let y = size.height - CGFloat(r + 1) * (size.height / CGFloat(rows)) + (size.height / CGFloat(rows) - d) / 2
                            var color = pal.fg.opacity(0.07)
                            if r < lit, let cell {
                                color = cell.charging ? pal.charging : (cell.level <= 20 ? Brand.signal : pal.fg.opacity(0.3 + 0.7 * Double(r + 1) / Double(rows)))
                            }
                            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: d, height: d)), with: .color(color))
                        }
                    }
                }
                .frame(height: 84)
                HStack {
                    Text(axisLeft); Spacer(); Text(axisMid); Spacer(); Text("now")
                }
                .font(Brand.mono(9, .regular)).foregroundStyle(pal.muted)
                if data.allSatisfy({ $0 == nil }) {
                    Text("Fills in as you use the Mac — one point every 5 minutes.").font(Brand.text(10.5)).foregroundStyle(pal.muted)
                } else {
                    HStack(spacing: 12) {
                        Legend(color: pal.fg, text: "On battery")
                        Legend(color: pal.charging, text: "Charging")
                        if data.contains(where: { ($0?.level ?? 100) <= 20 && !($0?.charging ?? true) }) {
                            Legend(color: Brand.signal, text: "Below 20%")
                        }
                    }
                }
            }
        }
    }
    private var axisLeft: String { switch model.range { case .day: "−24h"; case .week: "−7d"; case .month: "−30d" } }
    private var axisMid: String { switch model.range { case .day: "−12h"; case .week: "−3.5d"; case .month: "−15d" } }
}

struct RangeSwitch: View {
    @Binding var range: HistoryRange
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRange.allCases) { r in
                Button { range = r } label: {
                    Text(r.rawValue).font(Brand.text(10.5, .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(range == r ? pal.fg : .clear, in: Capsule())
                        .foregroundStyle(range == r ? pal.bg : pal.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

enum EnergyRange: String, CaseIterable, Identifiable {
    case live = "Live", day = "24H", week = "7D", month = "30D"
    var id: String { rawValue }
    var history: HistoryRange? {
        switch self { case .live: nil; case .day: .day; case .week: .week; case .month: .month }
    }
}

struct EnergySwitch: View {
    @Binding var range: EnergyRange
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 2) {
            ForEach(EnergyRange.allCases) { r in
                Button { range = r } label: {
                    Text(r.rawValue).font(Brand.text(10.5, .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(range == r ? pal.fg : .clear, in: Capsule())
                        .foregroundStyle(range == r ? pal.bg : pal.muted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct Legend: View {
    let color: Color, text: String
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Brand.text(10.5)).foregroundStyle(pal.muted)
        }
    }
}

struct LowPowerRow: View {
    @ObservedObject var model: AppModel
    let b: BatterySnapshot
    @Environment(\.palette) private var pal
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Low Power Mode").font(Brand.text(12.5, .medium))
                Text(model.charge.installed ? "Or right-click the menu bar icon" : "Or right-click the menu bar icon · asks for your password")
                    .font(Brand.text(10.5)).foregroundStyle(pal.muted)
            }
            Spacer()
            if model.lowPowerBusy { ProgressView().controlSize(.small) }
            Toggle("", isOn: Binding(get: { b.lowPower }, set: { _ in model.toggleLowPower() }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(pal.toggleTint)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(pal.sunk, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: Charge

struct ChargeTab: View {
    @ObservedObject var control: ChargeControl
    let b: BatterySnapshot
    @Environment(\.palette) private var pal

    var body: some View {
        VStack(spacing: 10) {
            if !control.installed {
                InstallStage(control: control)
            } else {
                if control.helperOutdated {
                    Panel {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Helper update").font(Brand.text(12.5, .medium))
                                Text("A newer helper ships with this build. macOS asks for your password once.")
                                    .font(Brand.text(10.5)).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            InkPill(title: control.busy ? "Updating…" : "Update") { control.install() }.disabled(control.busy)
                        }
                    }
                }
                LimitStage(control: control, b: b)
                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle2("Sailing mode", detail: "Charge again only below \(control.config.limit - control.config.sailRange)%, not every time it dips under the limit.",
                                isOn: $control.config.sailing) {
                            Stepper2(value: $control.config.sailRange, range: 2...20, step: 1, suffix: "%")
                        }
                        Divider().overlay(pal.line)
                        Toggle2("Heat protection", detail: String(format: "Pause charging above %.0f° and hold for 5 minutes once it trips.", control.config.heatMax),
                                isOn: $control.config.heatProtection) {
                            Stepper2(value: Binding(get: { Int(control.config.heatMax) }, set: { control.config.heatMax = Double($0) }),
                                     range: 30...45, step: 1, suffix: "°")
                        }
                        if control.canDischarge {
                            // Розряд до ліміту — лише коли є і заборона заряду, і вимкнення адаптера
                            Divider().overlay(pal.line)
                            Toggle2("Discharge to the limit", detail: "If the battery is above the limit when you plug in, run on battery down to it.",
                                    isOn: $control.config.discharge) { EmptyView() }
                        }
                        if !control.limitWorksAsleep {
                            Divider().overlay(pal.line)
                            Toggle2("Stay awake until the limit", detail: "A sleeping Mac would charge past the limit to full.",
                                    isOn: $control.config.sleepUntilLimit) { EmptyView() }
                        }
                        if control.status?.capabilities.contains("led") ?? true {
                            Divider().overlay(pal.line)
                            Toggle2("MagSafe light", detail: "Green while holding the limit, amber while charging to it.",
                                    isOn: $control.config.magsafeLED) { EmptyView() }
                        }
                    }
                }
                if control.adapterOnly {
                    Text("This Mac's firmware can't pause charging directly, so the limit pauses the adapter: the Mac runs on battery until it drops to the sailing point, then charges back up.")
                        .font(Brand.text(10.5)).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                HStack {
                    Button("Remove helper") { control.uninstall() }
                        .buttonStyle(.plain).font(Brand.text(11, .medium)).foregroundStyle(pal.muted)
                    Spacer()
                    if let e = control.error { Text(e).font(Brand.text(10.5)).foregroundStyle(Brand.signal).lineLimit(2) }
                }
                .padding(.horizontal, 4)
            }
        }
        .onAppear { control.readStatus() }
    }
}

struct InstallStage: View {
    @ObservedObject var control: ChargeControl
    @Environment(\.palette) private var pal
    var body: some View {
        Stage {
            VStack(alignment: .leading, spacing: 12) {
                Text("Charge limit").font(Brand.display(30)).tracking(-0.8)
                Text("Keep the battery at 80% instead of 100%, pause charging when it's hot, sail between charges. A small helper does the switching in the background — macOS asks for your admin password once.")
                    .font(Brand.text(12)).foregroundStyle(pal.fg.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Text("Removing the helper puts charging back to normal.")
                    .font(Brand.text(11)).foregroundStyle(pal.fg.opacity(0.55))
                HStack {
                    InkPill(title: control.busy ? "Installing…" : "Install helper") { control.install() }
                        .disabled(control.busy)
                    if let e = control.error { Text(e).font(Brand.text(10.5)).foregroundStyle(Brand.signal).lineLimit(2) }
                }
                .padding(.top, 4)
            }
        }
    }
}

struct LimitStage: View {
    @ObservedObject var control: ChargeControl
    let b: BatterySnapshot
    @Environment(\.palette) private var pal

    var body: some View {
        Stage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Limit").font(Brand.text(11, .medium)).foregroundStyle(pal.fg.opacity(0.6))
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text("\(control.config.limit)").font(Brand.display(64)).tracking(-3).monospacedDigit()
                                .contentTransition(.numericText())
                            Text("%").font(Brand.display(24)).foregroundStyle(pal.fg.opacity(0.55))
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $control.config.enabled).labelsHidden().toggleStyle(.switch).tint(pal.toggleTint)
                }
                Slider(value: Binding(get: { Double(control.config.limit) },
                                      set: { control.config.limit = Int($0.rounded()) }),
                       in: limitRange)
                    .tint(pal.fg)
                    .disabled(!control.config.enabled)
                Text(stateLine).font(Brand.text(12.5, .medium))
                    .foregroundStyle(control.status?.mode == .heat || control.status?.mode == .unsupported ? Brand.signal : pal.fg.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                if control.config.enabled && control.config.limit < Int(limitRange.upperBound) {
                    InkPill(title: control.config.topUp ? "Topping up — tap to cancel" : "Top up to max once",
                            symbol: control.config.topUp ? "xmark" : "bolt.fill") {
                        control.config.topUp.toggle()
                    }
                }
            }
        }
        .opacity(control.config.enabled ? 1 : 0.85)
    }

    /// Межі повзунка у відсотку, який бачить користувач: нижня — 50 % справжнього заряду, верхня — повний заряд у цьому режимі.
    private var limitRange: ClosedRange<Double> {
        let scale = control.config.scale ?? .trueCharge
        let top = scale == .ofDesign ? b.designTop : 100
        let low = scale == .ofDesign ? 50 * b.designTop / 100 : 50
        return Double(min(low, top - 1))...Double(top)
    }

    private var stateLine: String {
        guard control.helperAlive, let s = control.status else {
            return control.installed ? "Waiting for the helper to report…" : "Helper not installed"
        }
        if let n = s.note { return n }
        let c = control.config
        switch s.mode {
        case .off: return c.enabled ? "On battery — the limit applies when you plug in" : "Limit off — charging normally to full"
        case .charging: return c.limit >= Int(limitRange.upperBound) ? "Charging to full" : "Charging to \(c.limit)%"
        case .holding:
            if s.percent > c.limit + 1 {
                return "Not charging — \(s.percent)% is above the \(c.limit)% limit. Use it down; charging resumes at \(c.sailing ? c.limit - c.sailRange : c.limit - 1)%."
            }
            let wall = s.wallHold == true ? " on wall power" : ""
            return c.sailing ? "Holding \(c.limit)%\(wall) · charges again at \(c.limit - c.sailRange)%" : "Holding at \(c.limit)%\(wall)"
        case .discharging: return "Above the limit — running on battery down to \(c.limit)%"
        case .heat: return String(format: "Paused — battery is %.0f°, waiting for it to cool", s.temperature ?? 0)
        case .topUp: return "Topping up to max, then back to \(c.limit)%"
        case .lowSafety: return "Below 10% — charging normally"
        case .unsupported: return "Charge control isn't supported on this Mac"
        }
    }
}

/// Рядок налаштування: назва, пояснення одним реченням, додатковий контрол і перемикач.
struct Toggle2<Extra: View>: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @ViewBuilder var extra: Extra
    @Environment(\.palette) private var pal
    init(_ title: String, detail: String, isOn: Binding<Bool>, @ViewBuilder extra: () -> Extra) {
        self.title = title; self.detail = detail; self._isOn = isOn; self.extra = extra()
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.text(12.5, .medium))
                Text(detail).font(Brand.text(10.5)).foregroundStyle(pal.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if isOn { extra }
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(pal.toggleTint)
        }
    }
}

struct Stepper2: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus").frame(width: 20, height: 20) }
            Text("\(value)\(suffix)").font(Brand.mono(10.5, .semibold)).frame(minWidth: 30)
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 2)
        .background(pal.sunk, in: Capsule())
    }
}

// MARK: Power

struct PowerTab: View {
    @ObservedObject var model: AppModel
    let b: BatterySnapshot?
    @Environment(\.palette) private var pal
    @State private var energyRange: EnergyRange = .live

    var body: some View {
        VStack(spacing: 10) {
            if let b { PowerFlowStage(b: b, animating: model.popoverShown, holdingOnWall: b.onAC && model.charge.holdingOnWall) } else { MacPowerStage(model: model) }
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Energy by app").font(Brand.text(11, .medium)).foregroundStyle(pal.muted)
                        Spacer()
                        EnergySwitch(range: $energyRange)
                    }
                    if energyRange == .live {
                        if model.apps.isEmpty {
                            Text("Sampling…").font(Brand.text(11)).foregroundStyle(pal.muted)
                        }
                        ForEach(model.apps.prefix(7)) { a in AppRow(model: model, app: a) }
                    } else {
                        let top = model.energy.top(energyRange.history!, limit: 7)
                        if top.isEmpty {
                            Text("Builds up as the app runs — sampled every 2 minutes.").font(Brand.text(11)).foregroundStyle(pal.muted)
                        }
                        ForEach(top, id: \.name) { t in
                            HStack(spacing: 8) {
                                AppIcon(path: t.path).frame(width: 20, height: 20)
                                Text(t.name).font(Brand.text(12.5, .medium)).lineLimit(1)
                                Spacer()
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(pal.fg.opacity(0.08))
                                        Capsule().fill(pal.fg).frame(width: g.size.width * t.share)
                                    }
                                }
                                .frame(width: 80, height: 4)
                                Text("\(Int((t.share * 100).rounded()))%").font(Brand.mono(10.5, .semibold)).frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { model.sampleEnergy() }
    }
}

struct AppIcon: View {
    let path: String?
    var body: some View {
        if let p = path { Image(nsImage: NSWorkspace.shared.icon(forFile: p)).resizable() }
        else { Image(systemName: "gearshape").resizable().scaledToFit().foregroundStyle(Brand.muted).padding(2) }
    }
}

struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AppEnergy
    @Environment(\.palette) private var pal

    var body: some View {
        let open = model.expandedApp == app.name
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.snappy) { model.expandedApp = open ? nil : app.name } } label: {
                HStack(spacing: 8) {
                    AppIcon(path: app.bundlePath).frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).font(Brand.text(12.5, .medium)).lineLimit(1)
                        if app.hot {
                            Text("Using more than usual").font(Brand.text(10.5, .medium)).foregroundStyle(Brand.signal)
                        }
                    }
                    Spacer()
                    // Спарклайн лише з 5+ замірів: дві точки — не тренд, а випадкова похила
                    Sparkline(values: app.history.count >= 5 ? app.history : [], color: app.hot ? Brand.signal : pal.fg)
                        .frame(width: 64, height: 18)
                    Text(String(format: "%.0f", app.impact)).font(Brand.mono(11, .semibold)).frame(width: 30, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(String(format: "30-day avg %.0f · recent peak %.0f", app.average, max(app.impact, app.history.max() ?? 0)))
                        Spacer()
                        Text("\(app.processes.count) process\(app.processes.count == 1 ? "" : "es")")
                    }
                    .font(Brand.text(10.5)).foregroundStyle(pal.muted)
                    ForEach(Array(app.processes.prefix(6).enumerated()), id: \.offset) { _, p in
                        HStack {
                            Text(p.name).font(Brand.mono(10, .regular)).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1f", p.impact)).font(Brand.mono(10, .regular))
                        }
                        .foregroundStyle(pal.fg.opacity(0.75))
                    }
                }
                .padding(.leading, 12).padding(.vertical, 2)
                .overlay(alignment: .leading) { Rectangle().fill(pal.line).frame(width: 1) }
                .padding(.leading, 9)
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let mx = values.max(), mx > 0 else { return }
            var p = Path()
            for (i, v) in values.enumerated() {
                let pt = CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1), y: size.height * (1 - CGFloat(v / mx)))
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Mac без батареї: скільки споживає система зараз і як це мінялося за останні хвилини.
struct MacPowerStage: View {
    @ObservedObject var model: AppModel
    @Environment(\.palette) private var pal

    var body: some View {
        Stage {
            if let w = model.macWatts {
                let h = model.wattHistory
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int(w.rounded()))")
                            .font(Brand.display(84))
                            .tracking(-4)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("W").font(Brand.display(30)).foregroundStyle(pal.fg.opacity(0.55))
                        Spacer()
                        Image(systemName: "powerplug.fill")
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(pal.fg.opacity(0.7))
                    }
                    .frame(height: 78)
                    // Спарклайн лише з 5+ замірів, як і в енергії по апках
                    Sparkline(values: h.count >= 5 ? h : [], color: pal.fg).frame(height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac draw right now").font(Brand.text(13, .medium)).foregroundStyle(pal.fg.opacity(0.7))
                        if h.count >= 5, let lo = h.min(), let hi = h.max() {
                            let minutes = Int((Double(h.count) * AppModel.wattInterval / 60).rounded(.up))
                            Text("\(Int(lo.rounded()))–\(Int(hi.rounded())) W over the last \(minutes) min")
                                .font(Brand.text(11)).foregroundStyle(pal.fg.opacity(0.5))
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Power draw isn't available").font(Brand.display(20))
                    Text("This Mac doesn't report its total power to apps. Energy by app still works.")
                        .font(Brand.text(11.5)).foregroundStyle(pal.fg.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Розподіл живлення як Sankey: джерела ліворуч, споживачі праворуч,
/// товщина стрічки — вати, що йдуть цим шляхом. Ширини анімуються пружиною.
struct PowerFlowStage: View {
    let b: BatterySnapshot
    let animating: Bool
    var holdingOnWall = false
    @Environment(\.palette) private var pal

    var body: some View {
        let warn = b.chargerTooWeak
        Stage {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Power flow").font(Brand.text(11, .medium)).foregroundStyle(pal.fg.opacity(0.6))
                    Spacer()
                    Text(String(format: "%.1f W total", b.onAC ? max(b.inputWatts, b.systemWatts) : b.systemWatts))
                        .font(Brand.text(11)).foregroundStyle(pal.fg.opacity(0.6))
                }
                Sankey(adapterToBattery: b.onAC && b.isCharging ? max(0, b.watts) : 0,
                       adapterToMac: b.onAC ? max(0, b.systemWatts - max(0, -b.watts)) : 0,
                       // Без адаптера Mac живе лише від батареї, навіть якщо струм ще не оновився (буває до хвилини)
                       batteryToMac: b.onAC ? max(0, -b.watts) : max(-b.watts, b.systemWatts),
                       onAC: b.onAC,
                       adapterLabel: b.adapterWatts.map { "\($0)W" } ?? String(format: "%.0fW", b.inputWatts),
                       pal: pal,
                       animating: animating)
                    .frame(height: 150)
                    .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: b.watts)
                    .animation(.interpolatingSpring(stiffness: 120, damping: 16), value: b.systemWatts)
                if holdingOnWall {
                    Text("Holding the limit: the adapter runs the Mac and the battery is resting.")
                        .font(Brand.text(11)).foregroundStyle(Color(nsColor: .systemBlue)).fixedSize(horizontal: false, vertical: true)
                } else if warn {
                    Text("Plugged in, but the battery is still draining. The charger or cable gives less than the Mac uses — try a stronger adapter or another cable.")
                        .font(Brand.text(11)).foregroundStyle(Brand.signal).fixedSize(horizontal: false, vertical: true)
                } else if b.drainingOnAC, let a = b.adapterWatts {
                    Text("Using some battery while plugged in. The Mac draws far less than the \(a) W adapter can give, so the charger isn't the cause.")
                        .font(Brand.text(11)).foregroundStyle(pal.fg.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                } else if let a = b.adapterWatts, b.onAC, b.systemWatts > Double(a) * 0.9 {
                    Text("The Mac is close to the adapter's \(a) W limit.").font(Brand.text(11)).foregroundStyle(pal.fg.opacity(0.6))
                }
            }
        }
    }
}

/// Animatable: SwiftUI інтерполює три потоки між замірами — стрічки плавно товщають і тоншають.
struct Sankey: View, Animatable {
    var adapterToBattery: Double
    var adapterToMac: Double
    var batteryToMac: Double
    let onAC: Bool
    let adapterLabel: String
    let pal: Palette
    let animating: Bool

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { .init(adapterToBattery, .init(adapterToMac, batteryToMac)) }
        set { adapterToBattery = newValue.first; adapterToMac = newValue.second.first; batteryToMac = newValue.second.second }
    }

    private struct Flow { let from: Int; let to: Int; let w: Double }   // from: 0 адаптер, 1 батарея; to: 0 батарея, 1 Mac

    var body: some View {
        // Закритий поповер лише ховає вікно: без paused хвиля крутила б 30 кадрів/с вічно, коштом батареї.
        // Підписи — поза TimelineView, щоб не верстати текст на кожен кадр.
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(ctx: ctx, size: size, phase: phase)
            }
        }
        .overlay { labels }
    }

    private var flows: [Flow] {
        var f: [Flow] = []
        if onAC {
            if adapterToBattery > 0.05 { f.append(Flow(from: 0, to: 0, w: adapterToBattery)) }
            f.append(Flow(from: 0, to: 1, w: max(adapterToMac, 0.05)))
            if batteryToMac > 0.05 { f.append(Flow(from: 1, to: 1, w: batteryToMac)) }
        } else {
            f.append(Flow(from: 1, to: 1, w: max(batteryToMac, 0.05)))
        }
        return f
    }

    // Геометрія: вузли — колонки з великим радіусом, як на референсі
    private let nodeW: CGFloat = 54, gap: CGFloat = 12, minBand: CGFloat = 26

    private struct Layout {
        var left: [Int: CGRect] = [:], right: [Int: CGRect] = [:]
        var bands: [(Flow, CGRect, CGRect)] = []
    }

    private func layout(_ size: CGSize) -> Layout {
        let fs = flows
        let total = fs.reduce(0) { $0 + $1.w }
        // Товщини стрічок, що разом дають рівно `available`: пропорційно ватам, але не менше за minBand.
        // Нестачу тонких стрічок забираємо лише з надлишку товстих, тож без тонких пропорція точна.
        func thicknesses(_ available: CGFloat) -> [CGFloat] {
            let excess = fs.map { max(0, available * CGFloat($0.w / max(total, 0.01)) - minBand) }
            let k = (available - minBand * CGFloat(fs.count)) / max(excess.reduce(0, +), 0.01)
            return excess.map { minBand + $0 * k }
        }
        // Кожна колонка заповнює всю висоту, зі своїми проміжками між вузлами, тому краї збігаються.
        func column(_ node: (Flow) -> Int, x: CGFloat) -> (nodes: [Int: CGRect], bands: [CGFloat]) {
            let ids = [0, 1].filter { id in fs.contains { node($0) == id } }
            let bands = thicknesses(size.height - gap * CGFloat(max(0, ids.count - 1)))
            var nodes: [Int: CGRect] = [:], y: CGFloat = 0
            for id in ids {
                let hh = fs.indices.filter { node(fs[$0]) == id }.map { bands[$0] }.reduce(0, +)
                nodes[id] = CGRect(x: x, y: y, width: nodeW, height: hh); y += hh + gap
            }
            return (nodes, bands)
        }
        let src = column(\.from, x: 0)                     // адаптер зверху, батарея знизу
        let dst = column(\.to, x: size.width - nodeW)      // батарея зверху, Mac знизу
        var L = Layout(left: src.nodes, right: dst.nodes)

        var outY: [Int: CGFloat] = L.left.mapValues(\.minY), inY: [Int: CGFloat] = L.right.mapValues(\.minY)
        for (i, f) in fs.enumerated() {
            guard let a = L.left[f.from], let r = L.right[f.to] else { continue }
            let s = CGRect(x: a.maxX + 8, y: outY[f.from]!, width: 0, height: src.bands[i])
            let e = CGRect(x: r.minX - 8, y: inY[f.to]!, width: 0, height: dst.bands[i])
            outY[f.from]! += src.bands[i]; inY[f.to]! += dst.bands[i]
            L.bands.append((f, s, e))
        }
        return L
    }

    private func bandPath(_ s: CGRect, _ e: CGRect) -> Path {
        var p = Path()
        let mx = (s.minX + e.minX) / 2
        p.move(to: CGPoint(x: s.minX, y: s.minY))
        p.addCurve(to: CGPoint(x: e.minX, y: e.minY), control1: CGPoint(x: mx, y: s.minY), control2: CGPoint(x: mx, y: e.minY))
        p.addLine(to: CGPoint(x: e.minX, y: e.maxY))
        p.addCurve(to: CGPoint(x: s.minX, y: s.maxY), control1: CGPoint(x: mx, y: e.maxY), control2: CGPoint(x: mx, y: s.maxY))
        p.closeSubpath()
        return p
    }

    private func draw(ctx: GraphicsContext, size: CGSize, phase: Double) {
        let L = layout(size)
        let fill = pal.fg.opacity(pal.dark ? 0.14 : 0.1)
        for (_, s, e) in L.bands {
            let path = bandPath(s, e)
            ctx.fill(path, with: .color(fill))
            // Світла хвиля, що біжить від джерела до споживача
            var c = ctx
            c.clip(to: path)
            let x = (s.minX - 60) + CGFloat((phase * 0.6).truncatingRemainder(dividingBy: 1)) * (e.minX - s.minX + 120)
            c.fill(Path(CGRect(x: x, y: 0, width: 50, height: size.height)),
                   with: .linearGradient(Gradient(colors: [.clear, pal.fg.opacity(0.07), .clear]),
                                         startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x + 50, y: 0)))
        }
        for r in Array(L.left.values) + Array(L.right.values) {
            ctx.fill(Path(roundedRect: r, cornerRadius: 18, style: .continuous), with: .color(fill))
        }
    }

    @ViewBuilder private var labels: some View {
        GeometryReader { g in
            let L = layout(g.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(L.bands.enumerated()), id: \.offset) { _, item in
                    let (f, s, e) = item
                    Text(String(format: "%.2f W", f.w))
                        .font(Brand.text(13, .semibold)).monospacedDigit()
                        .position(x: (s.minX + e.minX) / 2, y: (s.midY + e.midY) / 2)
                        .opacity(s.height >= 22 ? 1 : 0)
                }
                if let a = L.left[0] {
                    // У низькому вузлі значок і підпис стають в один рядок, інакше вилазять за його межі
                    let stack = a.height >= 44 ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 4))
                    stack {
                        Image(systemName: "powerplug.portrait.fill").font(.system(size: 15))
                        Text(adapterLabel).font(Brand.text(12, .medium))
                    }
                    .position(x: a.midX, y: a.midY)
                }
                if let bt = L.left[1] {
                    Image(systemName: "battery.75percent").font(.system(size: 15)).position(x: bt.midX, y: bt.midY)
                }
                if let bt = L.right[0] {
                    Image(systemName: "battery.100percent.bolt").font(.system(size: 15)).position(x: bt.midX, y: bt.midY)
                }
                if let m = L.right[1] {
                    Image(systemName: "laptopcomputer").font(.system(size: 15)).position(x: m.midX, y: m.midY)
                }
            }
        }
    }
}

// MARK: Devices

struct DevicesTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var s = Settings.shared
    @Environment(\.palette) private var pal

    var body: some View {
        let visible = model.devices.filter { !s.rule($0.name).hidden }
        let hidden = model.devices.filter { s.rule($0.name).hidden }
        VStack(spacing: 10) {
            if model.devices.isEmpty {
                Stage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No devices connected").font(Brand.display(20))
                        Text("AirPods, Magic Mouse, Keyboard and Trackpad show up here while they're connected. Your iPhone and iPad appear when they're nearby. Apple Watch only reports through the iPhone, so it isn't shown.")
                            .font(Brand.text(11.5)).foregroundStyle(pal.fg.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !visible.isEmpty {
                Panel(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(visible) { d in DeviceRow(device: d) }
                    }
                }
            }
            if !hidden.isEmpty {
                HStack {
                    Text("Hidden: " + hidden.map(\.name).joined(separator: ", ")).font(Brand.text(11)).foregroundStyle(pal.muted).lineLimit(1)
                    Spacer()
                    Button("Show all") { hidden.forEach { var r = s.rule($0.name); r.hidden = false; s.deviceRules[$0.name] = r } }
                        .buttonStyle(.plain).font(Brand.text(11, .semibold))
                }
                .padding(.horizontal, 4)
            }
        }
        .onAppear { model.refreshDevices() }
    }
}

/// Рядок пристрою: назва й заряд. Правила сповіщень і приховування — у меню, що відкривається кліком по рядку.
struct DeviceRow: View {
    let device: BTDevice
    @ObservedObject var s = Settings.shared
    @Environment(\.palette) private var pal
    @State private var hover = false

    var body: some View {
        let r = s.rule(device.name)
        Menu {
            Picker(r.low > 0 ? "Low alert: \(r.low)%" : "Low alert: Off", selection: binding(\.low)) {
                Text("Off").tag(0)
                ForEach([5, 10, 15, 20, 30], id: \.self) { Text("At \($0)%").tag($0) }
            }
            Toggle("Alert when fully charged", isOn: binding(\.full))
            Divider()
            Button("Hide device") { var x = r; x.hidden = true; s.deviceRules[device.name] = x }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: device.symbol).font(.system(size: 14)).foregroundStyle(pal.muted).frame(width: 20, height: 20)
                Text(device.name).font(Brand.text(12.5, .medium)).lineLimit(1)
                Spacer(minLength: 8)
                levels.fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(pal.fg.opacity(hover ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .onHover { hover = $0 }
        .help(device.symbol == "iphone" || device.symbol == "ipad" ? "Updates every few minutes while nearby" : "")
    }

    @ViewBuilder private var levels: some View {
        if device.lowest == nil && device.caseLevel == nil {
            Text("No battery info").font(Brand.text(11)).foregroundStyle(pal.muted)
        } else {
            HStack(spacing: 8) {
                if let l = device.left { Part(label: "L", p: l) }
                if let x = device.right { Part(label: "R", p: x) }
                if let m = device.main, device.left == nil, device.right == nil { Part(label: nil, p: m) }
                if let c = device.caseLevel { Part(label: "Case", p: c) }
            }
        }
    }

    private func binding<T>(_ kp: WritableKeyPath<DeviceRule, T>) -> Binding<T> {
        Binding(get: { s.rule(device.name)[keyPath: kp] },
                set: { var x = s.rule(device.name); x[keyPath: kp] = $0; s.deviceRules[device.name] = x })
    }
}

struct Part: View {
    let label: String?, p: Int
    @Environment(\.palette) private var pal
    var body: some View {
        HStack(spacing: 3) {
            if let label { Text(label).font(Brand.text(10.5)).foregroundStyle(pal.muted) }
            Text("\(p)%").font(Brand.mono(11, .semibold)).foregroundStyle(pal.level(p))
        }
    }
}
