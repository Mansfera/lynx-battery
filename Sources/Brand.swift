import AppKit
import SwiftUI
import CoreText

/// Система etherlynx.xyz / volodymyr.buzz: білий фон, Ink, небесна сцена (sky), Onest.
/// Червоний — лише функціональний: мало заряду.
enum Brand {
    static let ink = Color(hex: 0x0E0E10)
    static let ink2 = Color(hex: 0x3A3D45)
    static let paper = Color.white
    static let muted = Color(hex: 0x6A6F7C)
    static let mist = Color(hex: 0xB3BCCD)
    static let skyTop = Color(hex: 0xA9B3C6)
    static let skyMid = Color(hex: 0xC9D0DC)
    static let skyLow = Color(hex: 0xEEF0F3)
    static let signal = Color(hex: 0xE8271E)

    static let nsSignal = NSColor(hex: 0xE8271E)
    static let nsMist = NSColor(hex: 0xB3BCCD)
    static let nsInk = NSColor(hex: 0x0E0E10)

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return }
        registerFonts(in: dir)
    }

    static func registerFonts(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    /// Великі цифри й заголовки: Onest medium, тісно, як заголовки на сайті.
    static func display(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .custom("Onest", size: size).weight(weight)
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Onest", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
    }

    static func nsText(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont(name: "Onest", size: size) ?? .systemFont(ofSize: size, weight: weight)
        return NSFontManager.shared.convert(base, toHaveTrait: weight >= .semibold ? .boldFontMask : [])
    }
}

/// Кольори світлої й темної теми — ті самі токени, що й на сайті.
struct Palette {
    let scheme: ColorScheme
    var dark: Bool { scheme == .dark }
    var bg: Color { dark ? Color(hex: 0x101012) : .white }
    var panel: Color { dark ? Color(hex: 0x1A1A1D) : .white }
    var sunk: Color { dark ? Color(hex: 0x17171A) : Color(hex: 0xF1F3F7) }
    var fg: Color { dark ? .white : Brand.ink }
    var line: Color { dark ? .white.opacity(0.1) : Brand.ink.opacity(0.12) }
    var muted: Color { dark ? Color.white.opacity(0.55) : Brand.muted }
    /// Стан батареї кольором, як на iPhone: заряджається — зелений, енергозбереження — жовтий,
    /// від розетки без заряду — синій, мало — червоний. Узгоджено з іконкою в меню-барі.
    var charging: Color { Color(nsColor: .systemGreen) }
    func state(_ b: BatterySnapshot) -> Color {
        if b.isCharging { return Color(nsColor: .systemGreen) }
        if b.lowPower { return Color(nsColor: .systemYellow) }
        if b.percent <= 20 { return Brand.signal }
        if b.onAC { return Color(nsColor: .systemBlue) }
        return fg
    }
    /// Колір увімкненого перемикача: білий трек у темній темі ховає білий повзунок.
    var toggleTint: Color { dark ? Brand.mist : Brand.ink }
    /// Заряд: звичайний — Ink, мало — червоний, зарядка — slate.
    func level(_ p: Int, charging isCharging: Bool = false) -> Color {
        if isCharging { return charging }
        if p <= 20 { return Brand.signal }
        return fg
    }
    /// Небесна сцена: вертикальний sky-градієнт, у темній — темна радіальна, як .obj на сайті.
    @ViewBuilder var stage: some View {
        if dark {
            RadialGradient(colors: [Color(hex: 0x2A2D35), Color(hex: 0x0E0E10)], center: .bottom, startRadius: 0, endRadius: 360)
        } else {
            LinearGradient(colors: [Brand.skyTop, Brand.skyMid, Brand.skyLow], startPoint: .top, endPoint: .bottom)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// Рись із комірок батареї (Marks/lynx-ink.svg), той самий рисунок, що й значок апки.
struct LynxMark: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "lynx-ink", withExtension: "svg", subdirectory: "Marks"),
           let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
        }
    }
}

/// Кнопка-пігулка з сайту: Ink, білий текст, біле коло зі стрілкою праворуч.
struct InkPill: View {
    let title: String
    var symbol: String = "arrow.right"
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // На темному тлі пігулка інвертується: біла з Ink-колом (як on-dark на сайті)
        let fill: Color = scheme == .dark ? .white : Brand.ink
        let ink: Color = scheme == .dark ? Brand.ink : .white
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(Brand.text(12, .medium))
                ZStack {
                    Circle().fill(ink)
                    Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(fill)
                }
                .frame(width: 22, height: 22)
            }
            .padding(.leading, 14).padding(.trailing, 4).padding(.vertical, 4)
            .background(fill, in: Capsule())
            .foregroundStyle(ink)
        }
        .buttonStyle(.plain)
    }
}
