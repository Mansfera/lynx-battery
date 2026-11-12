import AppKit

enum MenuIcon {
    static func color(for b: BatterySnapshot, holdingOnWall: Bool = false) -> NSColor? {
        guard Settings.shared.smartColors else { return nil }
        // Зелений — заряджається, синій — лише «ліміт тримається від розетки»
        if b.isCharging { return .systemGreen }
        if holdingOnWall { return .systemBlue }
        if b.lowPower { return .systemYellow }
        if b.percent <= 20 { return .systemRed }
        return nil
    }

    /// Іконка в стилі iPhone: заповнення за рівнем, відсоток усередині.
    /// Заповнення приглушене, щоб число було одного кольору: межа заливки не ріже цифру надвоє.
    static func image(for b: BatterySnapshot, style: IconStyle, phase: Int = -1, holdingOnWall: Bool = false) -> NSImage {
        let showNumber = style == .inside
        let bodyW: CGFloat = showNumber ? 27 : 22, bodyH: CGFloat = 12.5
        let size = NSSize(width: bodyW + 3, height: 16)
        let accent = color(for: b, holdingOnWall: holdingOnWall)

        let img = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let base = NSColor.labelColor
            let body = NSRect(x: 0.5, y: (16 - bodyH) / 2, width: bodyW, height: bodyH)
            let radius: CGFloat = 4

            base.withAlphaComponent(showNumber ? 0.16 : 0.22).setFill()
            NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
            base.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.8, y: body.midY - 2.2, width: 1.8, height: 4.4), xRadius: 0.9, yRadius: 0.9).fill()

            let fillW = max(2.5, body.width * CGFloat(b.percent) / 100)
            let fillRect = NSRect(x: body.minX, y: body.minY, width: fillW, height: body.height)
            ctx.saveGState()
            NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
            let fill = accent ?? base
            (showNumber ? fill.withAlphaComponent(accent == nil ? 0.42 : 0.55) : fill).setFill()
            fillRect.fill()
            // Зарядка: світла смуга біжить по заповненню
            if phase >= 0 {
                let x = fillRect.minX + (fillRect.width + 8) * CGFloat(phase) / 9 - 6
                NSColor.white.withAlphaComponent(showNumber ? 0.3 : 0.55).setFill()
                NSRect(x: x, y: body.minY, width: 4, height: body.height).intersection(fillRect).fill()
            }
            ctx.restoreGState()

            if showNumber {
                let font = NSFont.systemFont(ofSize: b.percent == 100 ? 9 : 10, weight: .bold)
                let str = NSAttributedString(string: "\(b.percent)", attributes: [.font: font, .foregroundColor: NSColor.textColor])
                let ts = str.size()
                str.draw(at: NSPoint(x: body.midX - ts.width / 2, y: body.midY - ts.height / 2 + 0.3))
            } else if b.isCharging {
                let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .black)
                        .applying(.init(paletteColors: [accent == .systemYellow ? .black : (accent != nil ? .white : .windowBackgroundColor)])))
                bolt?.draw(in: NSRect(x: body.midX - 3.5, y: body.midY - 4.5, width: 7, height: 9))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Знак стану ліворуч від батареї: ⚡ — заряджається, вилка — підключено, але заряд на паузі.
    static func withStatus(_ battery: NSImage, for b: BatterySnapshot) -> NSImage {
        let symbol: String
        if b.isCharging { symbol = "bolt.fill" }
        else if b.onAC { symbol = "powerplug.fill" }
        else { return battery }
        let gap: CGFloat = 2.5, glyphW: CGFloat = b.isCharging ? 7.5 : 10
        let size = NSSize(width: glyphW + gap + battery.size.width, height: battery.size.height)
        let img = NSImage(size: size, flipped: false) { _ in
            let colour = NSColor.labelColor
            let cfg = NSImage.SymbolConfiguration(pointSize: b.isCharging ? 10 : 9, weight: .bold)
                .applying(.init(paletteColors: [colour]))
            if let g = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let h = g.size.height * glyphW / max(g.size.width, 1)
                g.draw(in: NSRect(x: 0, y: (size.height - h) / 2, width: glyphW, height: h))
            }
            battery.draw(in: NSRect(x: glyphW + gap, y: 0, width: battery.size.width, height: battery.size.height))
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Mac без батареї: вилка й потужність. Пристрій, що сідає, стає поруч: іншого місця сказати про нього тут немає.
    /// Потужності не знаємо — найслабший пристрій або сама вилка, але ніколи не «0 W».
    static func desktop(devices: [BTDevice], watts: Double?) -> (NSImage, NSAttributedString) {
        let weakest = devices.first { $0.lowest != nil }
        let device = weakest.flatMap { d in watts == nil || (d.lowest ?? 100) <= 20 ? d : nil }
        let lvl = device?.lowest ?? 100
        let low = lvl <= 20 && Settings.shared.smartColors

        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let title = NSMutableAttributedString()
        if device != nil {
            title.append(NSAttributedString(string: " \(lvl)%", attributes: [.font: font, .foregroundColor: low ? NSColor.systemRed : NSColor.labelColor]))
        }
        if let watts {
            title.append(NSAttributedString(string: " \(Int(watts.rounded())) W", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }

        guard let device else {
            let img = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "On power")!
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!
            img.isTemplate = true
            return (img, title)
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(.init(paletteColors: [low ? .systemRed : .labelColor]))
        let img = NSImage(systemSymbolName: device.symbol, accessibilityDescription: device.name)?.withSymbolConfiguration(cfg)
            ?? NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: nil)!
        img.isTemplate = false
        return (img, title)
    }
}
