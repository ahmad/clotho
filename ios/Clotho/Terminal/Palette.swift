import ClothoKit
import SwiftTerm
import SwiftUI
import UIKit

/// The terminal's colours in each appearance: ClothoKit's ClothoPalette, shared with the Mac app.
typealias TerminalPalette = ClothoPalette

extension ClothoPalette {
    static func current(_ traits: UITraitCollection) -> ClothoPalette {
        traits.userInterfaceStyle == .light ? .light : .dark
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
