import SwiftTerm
import SwiftUI
import UIKit

/// The terminal's colours in each appearance, the same values as the Mac app's (ClothoPalette, once it's in
/// ClothoKit). Light maps ANSI white to mid greys, so programs that print white on an assumed dark
/// background stay readable.
struct TerminalPalette {
    var background: UInt32
    var foreground: UInt32
    var caret: UInt32
    /// Nil keeps SwiftTerm's own selection colour (as the Mac does in dark).
    var selection: UInt32?
    var ansi: [UInt32]

    static let dark = TerminalPalette(
        background: 0x1D2022, foreground: 0xC5CDD4, caret: 0x6C96B4, selection: nil,
        ansi: [0x121212, 0xC76156, 0x57C78A, 0xC8A35A, 0x5785C7, 0xC756A9, 0x57C7C3, 0xA9B0B6,
               0x292929, 0xD22D1E, 0x1CA05A, 0xE5A01A, 0x1458B8, 0xA43787, 0x4D9989, 0xD6DCE1])

    static let light = TerminalPalette(
        background: 0xF7F7F5, foreground: 0x2B3035, caret: 0x3F6E8F, selection: 0xC9D9E5,
        ansi: [0x2B3035, 0xB3392F, 0x2E7D4F, 0x8A6400, 0x2F62A8, 0x9C3B86, 0x1E7A75, 0x80878D,
               0x5E666C, 0xD0453A, 0x379A5E, 0xA87C00, 0x3B78C8, 0xB24C9C, 0x28948E, 0xA9AFB4])

    static func current(_ traits: UITraitCollection) -> TerminalPalette {
        traits.userInterfaceStyle == .light ? light : dark
    }

    /// SwiftTerm's selection colour, put back when leaving light.
    private static let swiftTermSelection = UIColor(red: 0, green: 166.0 / 255.0, blue: 178.0 / 255.0, alpha: 1.0)

    func apply(to terminal: TerminalView) {
        terminal.installColors(ansi.map { hex in
            SwiftTerm.Color(red8: UInt16(hex >> 16 & 0xFF), green8: UInt16(hex >> 8 & 0xFF), blue8: UInt16(hex & 0xFF))
        })
        terminal.nativeBackgroundColor = UIColor(hex: background)
        terminal.nativeForegroundColor = UIColor(hex: foreground)
        terminal.caretColor = UIColor(hex: caret)
        terminal.selectedTextBackgroundColor = selection.map { UIColor(hex: $0) } ?? Self.swiftTermSelection
        terminal.setNeedsDisplay()
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The app's appearance: the system's, or one chosen in the app (as on the Mac).
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// UIKit's override, which reaches sheets and the keyboard too (SwiftUI's preferredColorScheme(nil)
    /// doesn't always undo an earlier choice).
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    static let storageKey = "Appearance"

    static var saved: AppearanceChoice {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppearanceChoice.init(rawValue:)) ?? .system
    }

    /// Every window of the app takes the saved choice (each new window does too, from RootView).
    @MainActor static func applyToAllWindows() {
        let style = saved.interfaceStyle
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            scene.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}

/// Picks the appearance; in the Machines toolbar.
struct AppearanceMenu: View {
    @AppStorage(AppearanceChoice.storageKey) private var choice = AppearanceChoice.system

    var body: some View {
        Menu {
            Picker("Appearance", selection: $choice) {
                ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
        }
        .onChange(of: choice) { AppearanceChoice.applyToAllWindows() }
    }
}

/// The same choice as a submenu, inside another menu.
struct AppearancePicker: View {
    @AppStorage(AppearanceChoice.storageKey) private var choice = AppearanceChoice.system

    var body: some View {
        Picker(selection: $choice) {
            ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
        } label: {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
        }
        .pickerStyle(.menu)
        .onChange(of: choice) { AppearanceChoice.applyToAllWindows() }
    }
}
