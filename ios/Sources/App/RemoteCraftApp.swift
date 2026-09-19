import SwiftUI

@main
struct RemoteCraftApp: App {
    /// Both sessions are app-scoped, not screen-scoped. A shell that dies when you switch
    /// to the agent tab is not a shell, and an agent turn that dies when you go and look
    /// at the shell is worse — the box keeps working and the phone loses the transcript.
    @State private var hosts = HostBook()
    @State private var keys = KeyRing()
    @State private var terminal = TerminalStore()
    @State private var agent = AgentStore()
    @State private var navigator = Navigator()
    @State private var themes = ThemeStore()
    @State private var wake = Wake()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hosts)
                .environment(keys)
                .environment(terminal)
                .environment(agent)
                .environment(navigator)
                .environment(themes)
                .environment(wake)
                #if DEBUG
                    .task { Launch.seed(hosts: hosts, keys: keys, navigator: navigator) }
                #endif
                // Every palette is dark. A light system appearance must not repaint a
                // terminal's canvas out from under it.
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // One place, one counter. The screens decide what to do with it — the shell
            // rebuilds its PTY, the agent re-probes and re-attaches — because only they
            // know whether they had anything live to lose.
            switch phase {
            case .active: wake.active()
            case .background: wake.background()
            case .inactive:
                // Not a wake and not a backgrounding. `.inactive` is Control Centre, the
                // app switcher, a call banner, a permission alert — the process keeps
                // running and its sockets keep working. Counting it as a backgrounding
                // made every glance at Control Centre kill the user's PTY, cwd and
                // whatever was running in it.
                break
            @unknown default: break
            }
        }
    }
}
