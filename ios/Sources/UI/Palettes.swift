import SwiftUI
import UIKit

/// One complete look for the app.
///
/// A palette restyles everything at once — the host list, the agent transcript, and the
/// sixteen ANSI colours the terminal emulator paints with. That last slot is why this type
/// is not just "some colours for the chrome": a terminal whose red is not the theme's red
/// looks like a different app pasted into the middle of this one.
///
/// Nothing outside `Sources/UI/` names a colour. If a view needs one, it needs a slot here.
struct Palette: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// Who made the original, and under what terms. Shown in Settings.
    let credit: String

    /// The canvas.
    let bg: Color
    /// A panel sitting on the canvas.
    let surface: Color
    /// Something raised above a panel: a selected row, a pressed key on the accessory bar.
    let raised: Color
    /// Hairline borders and dividers.
    let line: Color

    /// Text, in three weights.
    let ink: Color
    let dim: Color
    let faint: Color

    /// The theme's two signature colours.
    let accent: Color
    let accent2: Color

    /// The only two states with a colour of their own: a live session, and a dead one.
    let live: Color
    let alarm: Color

    /// The sixteen ANSI colours, in the order a terminal indexes them: black, red, green,
    /// yellow, blue, magenta, cyan, white, then the eight bright variants. SwiftTerm is
    /// installed with exactly this array, so a theme change repaints scrollback too.
    let ansi: [Color]

    /// Flat by design — this is the Omarchy look and also simply easier to read behind
    /// monospaced text than any amount of blur.
    var corner: CGFloat { 6 }
}

extension Color {
    /// `Color(hex: 0x1a1b26)` — every palette below is written this way so the values can
    /// be checked against their upstream sources at a glance.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// The three components SwiftTerm's `Color` initialiser wants, as 16-bit channels.
    ///
    /// Going through `UIColor` rather than keeping the hex around is deliberate: a slot may
    /// one day hold a dynamic or asset colour, and this keeps that from silently painting
    /// the terminal black.
    var rgb16: (UInt16, UInt16, UInt16) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt16(max(0, min(1, r)) * 65535),
                UInt16(max(0, min(1, g)) * 65535),
                UInt16(max(0, min(1, b)) * 65535))
    }
}

/// The packs. Ports of well-known community themes, all MIT, values taken from each
/// theme's own published palette rather than eyeballed.
enum Themes {
    /// folke/tokyonight.nvim, enkia/tokyo-night-vscode-theme. The default, and the one the
    /// Omarchy box this app talks to is themed with out of the box.
    static let tokyoNight = Palette(
        id: "tokyo-night", name: "Tokyo Night", credit: "enkia & folke · MIT",
        bg: Color(hex: 0x1A1B26), surface: Color(hex: 0x1F2335), raised: Color(hex: 0x292E42),
        line: Color(hex: 0x3B4261),
        ink: Color(hex: 0xC0CAF5), dim: Color(hex: 0xA9B1D6), faint: Color(hex: 0x737AA2),
        accent: Color(hex: 0x7AA2F7), accent2: Color(hex: 0xBB9AF7),
        live: Color(hex: 0x9ECE6A), alarm: Color(hex: 0xF7768E),
        ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xFF7A93, 0xB9F27C, 0xFF9E64, 0x7DA6FF, 0xBB9AF7, 0x0DB9D7, 0xC0CAF5]
            .map(Color.init(hex:)))

    /// catppuccin/catppuccin, Mocha flavour.
    static let catppuccin = Palette(
        id: "catppuccin", name: "Catppuccin", credit: "Catppuccin · MIT",
        bg: Color(hex: 0x1E1E2E), surface: Color(hex: 0x313244), raised: Color(hex: 0x45475A),
        line: Color(hex: 0x45475A),
        ink: Color(hex: 0xCDD6F4), dim: Color(hex: 0xBAC2DE), faint: Color(hex: 0x9399B2),
        accent: Color(hex: 0xCBA6F7), accent2: Color(hex: 0xF5C2E7),
        live: Color(hex: 0xA6E3A1), alarm: Color(hex: 0xF38BA8),
        ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
               0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8]
            .map(Color.init(hex:)))

    /// morhetz/gruvbox, dark.
    static let gruvbox = Palette(
        id: "gruvbox", name: "Gruvbox", credit: "Pavel Pertsev · MIT",
        bg: Color(hex: 0x282828), surface: Color(hex: 0x3C3836), raised: Color(hex: 0x504945),
        line: Color(hex: 0x504945),
        ink: Color(hex: 0xEBDBB2), dim: Color(hex: 0xD5C4A1), faint: Color(hex: 0xA89984),
        accent: Color(hex: 0xFE8019), accent2: Color(hex: 0xFABD2F),
        live: Color(hex: 0xB8BB26), alarm: Color(hex: 0xFB4934),
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]
            .map(Color.init(hex:)))

    /// arcticicestudio/nord. Nord ships no mid-weight text colour, so `faint` is nord4
    /// dimmed, which is how most Nord ports fill the same gap.
    static let nord = Palette(
        id: "nord", name: "Nord", credit: "Arctic Ice Studio · MIT",
        bg: Color(hex: 0x2E3440), surface: Color(hex: 0x3B4252), raised: Color(hex: 0x434C5E),
        line: Color(hex: 0x4C566A),
        ink: Color(hex: 0xECEFF4), dim: Color(hex: 0xD8DEE9), faint: Color(hex: 0x9AA5BA),
        accent: Color(hex: 0x88C0D0), accent2: Color(hex: 0xB48EAD),
        live: Color(hex: 0xA3BE8C), alarm: Color(hex: 0xBF616A),
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]
            .map(Color.init(hex:)))

    /// The one true monochrome: no hue anywhere in the chrome, ANSI left saturated so
    /// `ls --color` and a diff still read.
    static let ashes = Palette(
        id: "ashes", name: "Ashes", credit: "remote-craft original",
        bg: Color(hex: 0x0B0B0C), surface: Color(hex: 0x151517), raised: Color(hex: 0x222225),
        line: Color(hex: 0x2E2E33),
        ink: Color(hex: 0xE4E4E7), dim: Color(hex: 0xA1A1AA), faint: Color(hex: 0x6B6B73),
        accent: Color(hex: 0xE4E4E7), accent2: Color(hex: 0x9CA3AF),
        live: Color(hex: 0x7BC47F), alarm: Color(hex: 0xE06C75),
        ansi: [0x1B1B1D, 0xE06C75, 0x7BC47F, 0xD9B26F, 0x7FA9D9, 0xB08FD9, 0x6FC7C7, 0xC9C9CE,
               0x3A3A40, 0xF08792, 0x9AD99E, 0xEBC98A, 0x9CC2EA, 0xC6ABEA, 0x8FDCDC, 0xF4F4F6]
            .map(Color.init(hex:)))

    static let all: [Palette] = [tokyoNight, catppuccin, gruvbox, nord, ashes]

    static func named(_ id: String) -> Palette? { all.first { $0.id == id } }
}
