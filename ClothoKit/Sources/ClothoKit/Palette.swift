import Foundation

/// Clotho's colours for both appearances, as 0xRRGGBB values, shared so the Mac and iOS apps match.
/// Dark is Warp's Adeberry, toned down; light keeps the same hues at text-safe contrast on its
/// background (the accent and every ANSI colour from 1 to 6 are at least 4.5:1 on `background`).
public struct ClothoPalette: Equatable, Sendable {
    public enum Appearance: String, Sendable, CaseIterable {
        case light, dark
    }

    /// The terminal's background and text.
    public var background: UInt32
    public var foreground: UInt32
    public var caret: UInt32
    /// The selection highlight; nil keeps the terminal's own.
    public var selection: UInt32?
    /// Sidebar and tab bar.
    public var chrome: UInt32
    public var hover: UInt32
    public var divider: UInt32
    /// Secondary text in the chrome.
    public var dimText: UInt32
    /// Links, the focus ring, running agents, section headers.
    public var accent: UInt32
    /// ANSI colours 0–15.
    public var ansi: [UInt32]

    public static let dark = ClothoPalette(
        background: 0x1D2022, foreground: 0xC5CDD4, caret: 0x6C96B4, selection: nil,
        chrome: 0x191C1E, hover: 0x24282B, divider: 0x343A3F, dimText: 0x7F888F, accent: 0x6C96B4,
        ansi: [
            0x121212, 0xC76156, 0x57C78A, 0xC8A35A, 0x5785C7, 0xC756A9, 0x57C7C3, 0xA9B0B6,
            0x292929, 0xD22D1E, 0x1CA05A, 0xE5A01A, 0x1458B8, 0xA43787, 0x4D9989, 0xD6DCE1,
        ])

    public static let light = ClothoPalette(
        background: 0xF7F7F5, foreground: 0x2B3035, caret: 0x3F6E8F, selection: 0xC9D9E5,
        chrome: 0xECEDEB, hover: 0xE1E3E1, divider: 0xD0D3D1, dimText: 0x636A70, accent: 0x3F6E8F,
        ansi: [
            // "White" is a mid grey, so text a program prints in white (expecting a dark background) stays readable.
            0x2B3035, 0xB3392F, 0x2E7D4F, 0x8A6400, 0x2F62A8, 0x9C3B86, 0x1E7A75, 0x80878D,
            0x5E666C, 0xD0453A, 0x379A5E, 0xA87C00, 0x3B78C8, 0xB24C9C, 0x28948E, 0xA9AFB4,
        ])

    public static func `for`(_ appearance: Appearance) -> ClothoPalette { appearance == .dark ? dark : light }

    /// WCAG contrast ratio between two colours, 1…21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ shift: UInt32) -> Double {
                let c = Double((rgb >> shift) & 0xff) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// The colours a client shows terminals in, as the daemon reports them to applications that ask
/// (`client.colors`, docs/protocol.md): Claude Code's "auto" theme, vim's background detection and so on
/// then match a light or dark pane.
public struct TerminalColors: Equatable, Sendable {
    public var foreground: UInt32
    public var background: UInt32
    public var cursor: UInt32?
    /// ANSI 0–15; exactly 16 when set.
    public var ansi: [UInt32]?

    public init(foreground: UInt32, background: UInt32, cursor: UInt32? = nil, ansi: [UInt32]? = nil) {
        precondition(ansi == nil || ansi!.count == 16, "ANSI colours are 16")
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
    }

    /// The colours a pane shows in `palette`.
    public init(_ palette: ClothoPalette) {
        self.init(foreground: palette.foreground, background: palette.background, cursor: palette.caret, ansi: palette.ansi)
    }

    /// `client.colors`' `colors` object: "#rrggbb" strings.
    public var json: [String: Any] {
        func hex(_ value: UInt32) -> String { String(format: "#%06x", value & 0xFFFFFF) }
        var object: [String: Any] = ["foreground": hex(foreground), "background": hex(background)]
        if let cursor { object["cursor"] = hex(cursor) }
        if let ansi { object["ansi"] = ansi.map(hex) }
        return object
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
