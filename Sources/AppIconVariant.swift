import AppKit

/// Значок апки. Перший варіант вшито в бандл як скляну іконку (Assets.car): macOS 26+ сама підлаштовує її
/// під темну, прозору й тоновану теми. Змінювати скляну іконку на льоту macOS не дає, тож решта варіантів —
/// готові PNG, які ставимо бандлу як власний значок Finder.
enum AppIconVariant: String, CaseIterable, Identifiable {
    case greenEyes = "green-eyes"
    case whiteEyes = "white-eyes"
    case plain
    case greenCells = "green-cells"

    static let standard = AppIconVariant.greenEyes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .greenEyes: "Green eyes"
        case .whiteEyes: "White eyes"
        case .plain: "Plain"
        case .greenCells: "Green cells"
        }
    }

    var image: NSImage? {
        Bundle.main.url(forResource: rawValue, withExtension: "png", subdirectory: "Icons").flatMap(NSImage.init(contentsOf:))
    }

    /// Вибір у налаштуваннях: значок у вікнах апки й у Finder.
    func apply() {
        setRunningIcon()
        setFinderIcon()
    }

    /// Під час запуску Finder чіпаємо лише тоді, коли значок загубився: оновлення апки замінює бандл разом із ним.
    func applyOnLaunch() {
        setRunningIcon()
        let custom = FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r")
        if custom == (self == Self.standard) { setFinderIcon() }
    }

    private func setRunningIcon() {
        // nil повертає значок із бандла
        NSApp.applicationIconImage = self == Self.standard ? nil : image
    }

    private func setFinderIcon() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        // nil прибирає власний значок, і система знову показує скляну іконку
        if NSWorkspace.shared.setIcon(self == Self.standard ? nil : image, forFile: path) {
            NSWorkspace.shared.noteFileSystemChanged(path)
        } else {
            NSLog("Lynx Battery: couldn't set the Finder icon on \(path)")
        }
    }
}
