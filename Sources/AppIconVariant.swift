import AppKit

/// App icon. The first variant is built into the bundle as the glass icon (Assets.car): macOS 26+ adapts it itself
/// to the dark, clear and tinted themes. macOS doesn't allow changing the glass icon on the fly, so the other variants are
/// ready-made PNGs that we set on the bundle as a custom Finder icon.
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

    /// Choice in settings: the icon in the app's windows and in Finder.
    func apply() {
        setRunningIcon()
        setFinderIcon()
    }

    /// At launch, touch Finder only when the icon got lost: an app update replaces the bundle along with it.
    func applyOnLaunch() {
        setRunningIcon()
        let custom = FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r")
        if custom == (self == Self.standard) { setFinderIcon() }
    }

    private func setRunningIcon() {
        // nil returns the icon from the bundle
        NSApp.applicationIconImage = self == Self.standard ? nil : image
    }

    private func setFinderIcon() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        // nil removes the custom icon, and the system shows the glass icon again
        if NSWorkspace.shared.setIcon(self == Self.standard ? nil : image, forFile: path) {
            NSWorkspace.shared.noteFileSystemChanged(path)
        } else {
            NSLog("Lynx Battery: couldn't set the Finder icon on \(path)")
        }
    }
}
