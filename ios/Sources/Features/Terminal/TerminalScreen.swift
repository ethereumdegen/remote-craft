import SwiftUI
import UIKit

/// The shell. A status bar, a terminal, and as little else as possible.
struct TerminalScreen: View {
    @Environment(HostBook.self) private var hosts
    @Environment(KeyRing.self) private var keys
    @Environment(TerminalStore.self) private var terminal
    @Environment(Navigator.self) private var navigator
    @Environment(Wake.self) private var wake

    @State private var enrolling = false

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                StatusBar(title: terminal.banner, state: terminal.state)
                content
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .sheet(isPresented: $enrolling) { EnrollView() }
        .onChange(of: wake.generation) { _, generation in
            terminal.wake(generation: generation, keys: keys.keys)
        }
        #if DEBUG
            // `-RCConnect YES` dials on launch. The SSH path cannot be reached by a unit
            // test and needs a tap to reach by hand, which is exactly the combination
            // that leaves a transport broken for a week.
            .task {
                guard UserDefaults.standard.bool(forKey: "RCConnect"),
                      terminal.state == .idle,
                      let host = hosts.selected, host.isUsable
                else { return }
                connect(host)
            }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if let host = hosts.selected, host.isUsable {
            if let diagnosis = terminal.diagnosis, !terminal.everOpened {
                // Nothing has ever been on this screen for this box, so there is no
                // scrollback to preserve and the failure gets the whole screen.
                DiagnosisPanel(diagnosis: diagnosis,
                               address: host.label,
                               retrying: terminal.retrying,
                               enroll: { enrolling = true },
                               retry: { connect(host) })
            } else if terminal.state == .idle {
                EmptyState(icon: "terminal",
                           title: host.displayName,
                           detail: host.label,
                           action: ("connect", { connect(host) }))
            } else {
                TerminalSurface(store: terminal)
                    // A different box gets a different terminal, rather than two
                    // machines' scrollback interleaved in one buffer.
                    .id(terminal.incarnation)
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        } else if hosts.hosts.isEmpty {
            EmptyState(icon: "server.rack",
                       title: "No hosts yet",
                       detail: "Connect this phone to an Omarchy box: one command there switches SSH on, opens the firewall and authorizes this key. Or add a box you can already reach.",
                       action: ("connect this phone", { enrolling = true }),
                       secondary: ("add a host", { navigator.tab = .hosts }))
        } else {
            EmptyState(icon: "exclamationmark.triangle",
                       title: "That host is incomplete",
                       detail: "It needs a username and at least one address.",
                       action: ("open hosts", { navigator.tab = .hosts }))
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if terminal.state == .idle {
                Button("connect") { if let host = hosts.selected { connect(host) } }
                    .buttonStyle(CraftButton())
                    .disabled(hosts.selected?.isUsable != true)
            } else {
                Button("disconnect") { terminal.disconnect() }
                    .buttonStyle(CraftButton(tint: Theme.alarm))
                Button("reconnect") { if let host = hosts.selected { connect(host) } }
                    .buttonStyle(CraftButton())
            }
            Spacer()
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil, from: nil, for: nil)
            } label: {
                Image(systemName: "keyboard.chevron.compact.down")
            }
            .buttonStyle(CraftButton(tint: Theme.dim))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func connect(_ host: SSHHost) {
        terminal.connect(host: host, keys: keys.keys, generation: wake.generation)
    }
}
