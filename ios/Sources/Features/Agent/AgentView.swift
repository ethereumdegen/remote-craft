import SwiftUI

/// The coding agent: a transcript, a composer, and a stop button that means it.
struct AgentView: View {
    @Environment(HostBook.self) private var hosts
    @Environment(AgentStore.self) private var agent
    @Environment(Navigator.self) private var navigator
    @Environment(Wake.self) private var wake

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                StatusBar(title: agent.banner, state: agent.state)
                if hosts.selected == nil {
                    EmptyState(icon: "server.rack",
                               title: "No host",
                               detail: "The agent runs on a box. Add one first.",
                               action: ("add a host", { navigator.tab = .hosts }))
                } else if agent.state == .idle {
                    EmptyState(icon: "bubble.left.and.text.bubble.right",
                               title: hosts.selected?.displayName ?? "agent",
                               detail: "metalcraft-agent on :\(hosts.selected?.agentPort ?? 3002), preset \(hosts.selected?.agentPreset ?? "general-agent").",
                               action: ("connect", connect))
                } else {
                    if agent.isDown { reconnectBar }
                    transcript
                    AgentComposer(store: agent)
                }
            }
        }
        .onChange(of: wake.generation) { _, generation in
            guard let host = hosts.selected else { return }
            agent.wake(generation: generation, token: hosts.token(for: host))
        }
        #if DEBUG
            // Same reason as the shell: the SSE path is only reachable by tapping, and an
            // untapped path is an unchecked one. `-RCPrompt "…"` also sends one turn, so a
            // single command exercises probe, chat creation, streaming and rendering.
            .task {
                guard UserDefaults.standard.bool(forKey: "RCConnect"),
                      agent.state == .idle, hosts.selected != nil
                else { return }
                let prompt = UserDefaults.standard.string(forKey: "RCPrompt") ?? ""
                agent.draft = prompt
                connect()
                guard !prompt.isEmpty else { return }
                for _ in 0 ..< 40 where agent.chatID == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                agent.send()
            }
        #endif
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(agent.lines) { line in
                        AgentRow(line: line).id(line.id)
                    }
                    if !agent.options.isEmpty { choices }
                    if agent.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini).tint(Theme.accent2)
                            Text(agent.phase.isEmpty ? "working" : agent.phase)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.accent2)
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: agent.lines.count) { _, _ in
                guard let last = agent.lines.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// A dropped SSE watcher cannot be recovered by typing: the stream is gone, the
    /// composer is disabled, and nothing retries on its own. The red status bar says
    /// something is wrong; this is the thing to do about it.
    private var reconnectBar: some View {
        HStack(spacing: 10) {
            Text("the agent stream dropped")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            Spacer()
            Button("reconnect", action: connect)
                .buttonStyle(CraftButton(tint: Theme.accent2))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// `awaiting_reply` with options is the agent asking a closed question. Buttons, not a
    /// hint that the user should retype one of them.
    private var choices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "the agent is waiting")
            ForEach(agent.options, id: \.self) { option in
                Button(option) { agent.choose(option) }
                    .buttonStyle(CraftButton(tint: Theme.accent2))
            }
        }
    }

    private func connect() {
        guard let host = hosts.selected else { return }
        agent.connect(host: host, token: hosts.token(for: host), generation: wake.generation)
    }
}

/// Split out only so the composer can bind to `draft` without the whole screen taking a
/// `@Bindable` dependency on a store it otherwise only reads.
private struct AgentComposer: View {
    let store: AgentStore

    var body: some View {
        @Bindable var store = store
        return HStack(spacing: 8) {
            TextField("message", text: $store.draft, axis: .vertical)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.ink)
                .lineLimit(1...5)
                .padding(8)
                .background(Theme.raised)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                .disabled(store.busy)
            // Stop, not send, while a turn runs — and the button stays `stop` until the
            // agent emits `done`, because that is the only frame that ends a turn.
            if store.busy {
                Button("stop") { store.stop() }
                    .buttonStyle(CraftButton(tint: Theme.alarm))
            } else {
                Button("send") { store.send() }
                    .buttonStyle(CraftButton())
                    .disabled(!store.canSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

struct AgentRow: View {
    let line: AgentLine

    var body: some View {
        switch line.role {
        case .you:
            bubble(text: line.text, tint: Theme.accent, trailing: true)
        case .agent:
            bubble(text: line.text, tint: Theme.ink, trailing: false)
        case .tool(let running, let failed):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: running ? "gearshape" : (failed ? "xmark.octagon" : "checkmark"))
                    .font(.system(size: 10))
                    .foregroundStyle(running ? Theme.accent2 : (failed ? Theme.alarm : Theme.live))
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.text)
                        .font(Theme.mono(11, weight: .semibold))
                        .foregroundStyle(Theme.dim)
                    if !line.detail.isEmpty {
                        Text(line.detail)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
        case .note:
            VStack(alignment: .leading, spacing: 2) {
                Text(line.text).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                if !line.detail.isEmpty {
                    Text(line.detail).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                }
            }
        case .problem:
            Text(line.text)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.alarm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(padding: 8)
        }
    }

    private func bubble(text: String, tint: Color, trailing: Bool) -> some View {
        HStack {
            if trailing { Spacer(minLength: 32) }
            Text(text)
                .font(Theme.mono(12))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                .padding(10)
                .background(trailing ? Theme.raised : Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.line, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            if !trailing { Spacer(minLength: 32) }
        }
    }
}
