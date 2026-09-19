import Foundation
import Observation

/// One line of the agent transcript.
///
/// Tool calls are rows rather than decorations because they are most of what a coding
/// agent does; a chat that only showed prose would be a progress bar with extra steps.
struct AgentLine: Identifiable, Equatable {
    enum Role: Equatable {
        case you
        case agent
        case tool(running: Bool, failed: Bool)
        case note
        case problem
    }

    let id = UUID()
    var role: Role
    var text: String
    var detail: String = ""
    /// Set on tool rows so a `tool_completed` updates the row its `tool_started` made,
    /// instead of appending a second one.
    var callID: String = ""
}

/// Drives metalcraft-agent's workshop API and folds its frames into a transcript.
///
/// App-scoped for the same reason the terminal store is: a turn takes minutes, and the
/// user will look at the terminal while it runs.
@MainActor
@Observable
final class AgentStore {
    private(set) var state: Liveness = .idle
    private(set) var banner: String = "no agent"
    private(set) var lines: [AgentLine] = []
    /// Locked while a turn is in flight. Unlocked **only** by `done` — not by a `reply`,
    /// which can be followed by more tools, and not by the interrupt response, which only
    /// means the agent has been asked to stop.
    private(set) var busy = false
    /// Choices from the last `reply{awaiting_reply:true}`. Tapping one sends it as the
    /// next message, which is what the agent is waiting for.
    private(set) var options: [String] = []
    private(set) var phase = ""

    var draft = ""

    private var client: Workshop?
    private var chat: String?
    /// The chat this store is attached to, read-only. Connecting is asynchronous, so
    /// anything that must not act before a chat exists waits on this rather than a timer.
    var chatID: String? { chat }
    private var host: SSHHost?
    private var turn: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var bornAt = 0

    var canSend: Bool { client != nil && !busy && !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - connection

    func connect(host: SSHHost, token: String, generation: Int) {
        if self.host?.id != host.id {
            lines.removeAll()
            chat = nil
        }
        self.host = host
        bornAt = generation
        banner = "\(host.displayName):\(host.agentPort)"
        state = .working
        stopStreams()

        Task { [self] in
            do {
                let (client, summary) = try await Workshop.resolve(host: host, token: token)
                self.client = client
                banner = "\(summary) · \(client.base.host() ?? host.displayName)"
                let id: String
                if let existing = chat {
                    id = existing
                } else {
                    id = try await client.createChat(preset: host.agentPreset)
                    chat = id
                    note("chat \(id) · \(host.agentPreset)")
                }
                state = .up
                watch(chat: id)
            } catch {
                state = .down(Workshop.short(error))
                problem(Workshop.short(error))
            }
        }
    }

    /// The wake pass. An SSE stream whose socket iOS killed never returns and never
    /// throws, so the only safe move is to drop both streams, re-probe the agent — the
    /// address that answered before may not be the one that answers now — and re-attach.
    func wake(generation: Int, token: String) {
        guard let host, generation != bornAt, state != .idle else {
            bornAt = generation
            return
        }
        bornAt = generation
        // A turn may have finished while the app was suspended. Re-attaching to the chat's
        // broadcast is what discovers that; leaving `busy` set would lock the composer
        // forever on a turn that ended an hour ago.
        busy = false
        connect(host: host, token: token, generation: generation)
    }

    func disconnect() {
        stopStreams()
        client = nil
        state = .idle
        busy = false
    }

    // MARK: - turns

    func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        draft = ""
        send(message: message)
    }

    func choose(_ option: String) {
        options = []
        send(message: option)
    }

    private func send(message: String) {
        guard let client, let chat else {
            problem("Not connected to an agent yet.")
            return
        }
        options = []
        lines.append(AgentLine(role: .you, text: message))
        busy = true
        phase = ""

        turn?.cancel()
        turn = Task { [self] in
            do {
                for try await frame in client.turn(chat: chat, message: message) {
                    apply(frame)
                }
                // The stream ended without `done` — a dropped socket, not a finished turn.
                // Say so and unlock, rather than leaving a composer nobody can type in.
                if busy {
                    busy = false
                    problem("The turn stream ended without a result. Pull to reconnect.")
                }
            } catch is CancellationError {
                busy = false
            } catch {
                busy = false
                problem(Workshop.short(error))
            }
        }
    }

    /// Stop. The agent acknowledges with `{stopping}` and keeps streaming until it emits
    /// `done`; the composer stays locked until then, because the turn is still running.
    func stop() {
        guard let client, let chat else { return }
        note("asked the agent to stop")
        Task { [self] in
            do { try await client.interrupt(chat: chat) }
            catch { problem(Workshop.short(error)) }
        }
    }

    private func watch(chat id: String) {
        watcher?.cancel()
        guard let client else { return }
        watcher = Task { [self] in
            do {
                for try await frame in client.watch(chat: id) {
                    // A turn this phone did not start — a schedule, a laptop, the box's
                    // own CLI — arrives here. Showing it is the point of watching.
                    apply(frame)
                }
            } catch is CancellationError {
            } catch {
                state = .down(Workshop.short(error))
            }
        }
    }

    private func stopStreams() {
        turn?.cancel()
        turn = nil
        watcher?.cancel()
        watcher = nil
    }

    // MARK: - the fold

    /// Internal rather than private: the rules about what locks and unlocks the composer
    /// are the part of this store most likely to be got wrong, and they are testable
    /// without a network only from here.
    func apply(_ frame: WorkshopFrame) {
        switch frame {
        case .turnStarted:
            busy = true
        case .llmStarted:
            phase = "thinking"
        case .llmCompleted:
            // Explicitly nothing. `llm_completed` fires for every model call in a turn,
            // including the ones that only chose a tool. The user-visible text is `reply`.
            break
        case .toolStarted(let id, let name, let detail):
            phase = name
            lines.append(AgentLine(role: .tool(running: true, failed: false),
                                   text: name, detail: detail, callID: id))
        case .toolCompleted(let id, let name, let detail, let failed):
            phase = ""
            if let index = lines.lastIndex(where: { $0.callID == id && !id.isEmpty }) {
                lines[index].role = .tool(running: false, failed: failed)
                lines[index].detail = detail
            } else {
                lines.append(AgentLine(role: .tool(running: false, failed: failed),
                                       text: name, detail: detail, callID: id))
            }
        case .reply(let text, let awaiting, let choices):
            if !text.isEmpty { lines.append(AgentLine(role: .agent, text: text)) }
            options = awaiting ? choices : []
        case .phase(let name):
            phase = name
        case .queued(let message, let position):
            note(position.map { "\(message) — position \($0)" } ?? message)
        case .plan(let steps):
            guard !steps.isEmpty else { break }
            lines.append(AgentLine(role: .note, text: "plan",
                                   detail: steps.enumerated()
                                       .map { "\($0.offset + 1). \($0.element)" }
                                       .joined(separator: "\n")))
        case .injected(let text):
            note(text.isEmpty ? "context injected" : text)
        case .done(let status):
            busy = false
            phase = ""
            if status != "completed" && !status.isEmpty { note("turn \(status)") }
        case .failure(let code, let message, let retryable):
            problem("\(code): \(message)\(retryable ? " (retryable)" : "")")
            busy = false
        case .unknown:
            // A frame from a newer agent. Ignoring it is the whole compatibility policy.
            break
        }
    }

    private func note(_ text: String) {
        lines.append(AgentLine(role: .note, text: text))
    }

    private func problem(_ text: String) {
        lines.append(AgentLine(role: .problem, text: text))
    }
}
