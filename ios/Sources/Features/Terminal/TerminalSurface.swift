import SwiftTerm
import SwiftUI
import UIKit

/// SwiftTerm's UIKit terminal, wrapped for SwiftUI.
///
/// Written by hand because SwiftTerm does not ship a usable SwiftUI view: the
/// `SwiftUITerminalView` in the package is `internal` and inside `#if DEBUG`, so it does
/// not exist in any build that depends on the package. The wrapper is small anyway — the
/// interesting part is the three-way wiring, and all three directions matter:
///
///     box → app    TTYOutput bytes → TerminalStore → feed(byteArray:)
///     app → box    TerminalViewDelegate.send → TTYStdinWriter.write
///     layout       sizeChanged → SSH window-change, so `vim` and `htop` fit the screen
///
/// The last one is the one that is easy to skip and impossible to live without: a remote
/// program told it has 80 columns while the phone shows 52 draws a wrapped mess.
struct TerminalSurface: UIViewRepresentable {
    let store: TerminalStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(
            frame: .zero,
            font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.backgroundColor = UIColor(Theme.bg)
        view.nativeBackgroundColor = UIColor(Theme.bg)
        view.nativeForegroundColor = UIColor(Theme.ink)
        view.caretColor = UIColor(Theme.accent)
        view.selectedTextBackgroundColor = UIColor(Theme.raised)
        // The palette reaches the emulator too: sixteen ANSI slots, so `ls --color`, a
        // diff, and a themed prompt are in the same palette as the app around them.
        view.installColors(Theme.current.ansi.map { slot in
            let (r, g, b) = slot.rgb16
            return SwiftTerm.Color(red: r, green: g, blue: b)
        })
        // SwiftTerm installs its own `TerminalAccessory` above the keyboard — esc, ctrl,
        // tab and the four arrows. Keeping it is not laziness: without those keys the app
        // cannot exit vim, and anything hand-rolled would be the same bar with new bugs.
        context.coordinator.attach(view)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.store = store
    }

    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        coordinator.releaseFeed()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var store: TerminalStore
        /// The feed this coordinator installed. The store has one feed slot and SwiftUI
        /// may make the replacement view before dismantling this one, so releasing by
        /// token is what stops a dying terminal from nilling the live one's feed — which
        /// leaves a session still running, still taking keystrokes, and a blank screen.
        private var token = 0

        init(store: TerminalStore) {
            self.store = store
        }

        /// `TerminalViewDelegate` is not main-actor annotated, but every call it makes
        /// comes out of UIKit on the main thread, and the store it forwards to is
        /// `@MainActor`. `assumeIsolated` states that fact once per hop rather than
        /// hopping asynchronously — which for keystrokes would mean reordering them.
        @MainActor
        func attach(_ view: SwiftTerm.TerminalView) {
            // Weak: the store outlives the view (it is app-scoped, the view is per-tab),
            // and a strong capture here would keep a dismantled terminal alive and being
            // fed for the rest of the process.
            token = store.install { [weak view] bytes in
                view?.feed(byteArray: ArraySlice(bytes))
            }
        }

        @MainActor
        func releaseFeed() {
            store.release(feed: token)
        }

        // MARK: - TerminalViewDelegate

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { store.resize(cols: newCols, rows: newRows) }
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { store.send(data) }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            // The remote shell's title is not shown: the status bar already says which box
            // this is, and a title that changes with every `cd` is noise.
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return }
            UIApplication.shared.open(url)
        }
    }
}
