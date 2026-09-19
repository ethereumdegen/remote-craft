import SwiftUI

/// The active palette, read the way the rest of the app reads colours.
///
/// **Why a mutable static and not `@Environment`**: three of the readers have no
/// environment to read from. `TerminalSurface` builds a UIKit `TerminalView` inside
/// `makeUIView` and has to install sixteen `UIColor`s on it; the `.tint` applied above the
/// window is evaluated outside any view; and a couple of default argument values are
/// evaluated before a view exists at all. `ThemeStore` sets `current` and keys the root
/// view on the palette id, which rebuilds the tree when — and only when — the theme
/// changes, so every read below is correct by construction.
enum Theme {
    static var current: Palette = ThemeStore.saved

    static var bg: Color { current.bg }
    static var surface: Color { current.surface }
    static var raised: Color { current.raised }
    static var line: Color { current.line }
    static var ink: Color { current.ink }
    static var dim: Color { current.dim }
    static var faint: Color { current.faint }
    static var accent: Color { current.accent }
    static var accent2: Color { current.accent2 }
    static var live: Color { current.live }
    static var alarm: Color { current.alarm }
    static var corner: CGFloat { current.corner }

    /// The one type face the app uses for anything the box said. A proportional font in a
    /// terminal transcript is not a style choice, it is a lie about column alignment.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Reads and writes the chosen palette.
///
/// Persisted under `rc.theme` — one of the handful of things about this app that is not a
/// secret and therefore does not belong in the Keychain.
@MainActor
@Observable
final class ThemeStore {
    static let key = "rc.theme"

    /// Read before any store exists, because `Theme.current` has to be valid from the
    /// first line of `body` in the first view — which is why it is `nonisolated`.
    nonisolated static var saved: Palette {
        Themes.named(UserDefaults.standard.string(forKey: key) ?? "") ?? Themes.tokyoNight
    }

    private(set) var palette: Palette = ThemeStore.saved

    func select(_ palette: Palette) {
        self.palette = palette
        Theme.current = palette
        UserDefaults.standard.set(palette.id, forKey: Self.key)
    }
}

/// What sits behind every screen: the canvas colour and a hairline grid, faint enough to
/// read as texture rather than pattern. The tiling-window-manager look, which is what the
/// box on the other end of the SSH connection looks like.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            GeometryReader { geo in
                Path { path in
                    let step: CGFloat = 28
                    var x: CGFloat = 0
                    while x < geo.size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: geo.size.height))
                        x += step
                    }
                    var y: CGFloat = 0
                    while y < geo.size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geo.size.width, y: y))
                        y += step
                    }
                }
                .stroke(Theme.line.opacity(0.18), lineWidth: 0.5)
            }
            .ignoresSafeArea()
        }
    }
}

/// A panel: something sitting on the canvas. Solid fill, one-point border, sharp corners.
struct Panel: ViewModifier {
    var padding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.corner)
                    .stroke(Theme.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
    }
}

extension View {
    func panel(padding: CGFloat = 12) -> some View { modifier(Panel(padding: padding)) }
}
