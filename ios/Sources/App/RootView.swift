import SwiftUI

enum RootTab: Hashable {
    case hosts, terminal, agent, keys, settings
}

/// Which tab is showing, as state rather than a binding passed down four levels.
///
/// Screens send the user elsewhere — "no host yet, go and add one" — and a dead-end empty
/// state with no way out of it is the commonest way a first launch goes wrong.
@MainActor
@Observable
final class Navigator {
    var tab: RootTab = .terminal
    /// The enrollment sheet, which the Keys screen owns and anything can ask for. It is
    /// routed rather than kept local because "this box has never heard of this phone" is
    /// asked from three screens and answered on one.
    var enrolling = false
}

struct RootView: View {
    @Environment(Navigator.self) private var navigator
    @Environment(ThemeStore.self) private var themes

    var body: some View {
        @Bindable var navigator = navigator
        return TabView(selection: $navigator.tab) {
            TerminalScreen()
                .tabItem { Label("shell", systemImage: "terminal") }
                .tag(RootTab.terminal)
            AgentView()
                .tabItem { Label("agent", systemImage: "bubble.left.and.text.bubble.right") }
                .tag(RootTab.agent)
            HostsView()
                .tabItem { Label("hosts", systemImage: "server.rack") }
                .tag(RootTab.hosts)
            KeysView()
                .tabItem { Label("keys", systemImage: "key") }
                .tag(RootTab.keys)
            SettingsView()
                .tabItem { Label("settings", systemImage: "slider.horizontal.3") }
                .tag(RootTab.settings)
        }
        .tint(Theme.accent)
        // Keyed on the palette: `Theme` is a static read, so the tree has to be rebuilt
        // for a theme change to reach the hundred places that read it — including the
        // UIKit terminal, which takes its sixteen ANSI colours at construction.
        .id(themes.palette.id)
    }
}
