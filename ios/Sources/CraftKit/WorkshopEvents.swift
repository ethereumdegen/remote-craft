import Foundation

/// One frame of metalcraft-agent's turn stream.
///
/// The agent sends bare `data: {json}` lines with **no `event:` name**, so the frame's
/// meaning is entirely in its `kind` field. Two facts about this protocol are easy to get
/// wrong and both are load-bearing here:
///
/// 1. **The chat bubble is `reply.content`, not `llm_completed`.** `llm_completed` fires
///    for every model call in a turn, including the ones that only decided which tool to
///    run. Rendering those would show the user the agent's internal monologue as if it
///    were an answer.
/// 2. **A turn is over on `done`, and nothing else.** Not on `reply`, which can be
///    followed by more tools, and not on the response to `interrupt`, which only means the
///    agent was asked to stop.
///
/// An unknown `kind` is a frame from a newer agent, not an error: it decodes to `.unknown`
/// and is ignored. A build that fell over on one would break every time the box updates.
enum WorkshopFrame: Equatable {
    case turnStarted
    case llmStarted
    case llmCompleted
    case toolStarted(id: String, name: String, detail: String)
    case toolCompleted(id: String, name: String, detail: String, failed: Bool)
    case reply(text: String, awaiting: Bool, options: [String])
    case phase(String)
    case queued(message: String, position: Int?)
    case plan([String])
    case injected(String)
    case done(status: String)
    case failure(code: String, message: String, retryable: Bool)
    case unknown(String)

    /// The one frame that ends a turn.
    var isTerminal: Bool {
        if case .done = self { return true }
        return false
    }
}

extension WorkshopFrame: Decodable {
    private enum Key: String, CodingKey {
        case kind
        case content, awaitingReply = "awaiting_reply", options
        case toolCallID = "tool_call_id", name, args, result, durationMS = "duration_ms"
        case phase, message, position, steps, status, reason, code, retryable, error
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Key.self)
        let kind = (try? box.decode(String.self, forKey: .kind)) ?? ""

        switch kind {
        case "turn_started": self = .turnStarted
        case "llm_started": self = .llmStarted
        case "llm_completed": self = .llmCompleted

        case "tool_started":
            self = .toolStarted(
                id: (try? box.decode(String.self, forKey: .toolCallID)) ?? "",
                name: (try? box.decode(String.self, forKey: .name)) ?? "tool",
                detail: Self.flatten(box, .args))

        case "tool_completed":
            let result = Self.flatten(box, .result)
            let ms = try? box.decode(Int.self, forKey: .durationMS)
            let detail = [ms.map { "\($0)ms" }, result.isEmpty ? nil : result]
                .compactMap { $0 }.joined(separator: " · ")
            self = .toolCompleted(
                id: (try? box.decode(String.self, forKey: .toolCallID)) ?? "",
                name: (try? box.decode(String.self, forKey: .name)) ?? "tool",
                detail: detail,
                // The agent reports a failed tool inside the result rather than with a
                // frame of its own; treating it as success would show a green tick over
                // an error the user needs to read.
                failed: result.lowercased().hasPrefix("error"))

        case "reply":
            self = .reply(
                text: (try? box.decode(String.self, forKey: .content)) ?? "",
                awaiting: (try? box.decode(Bool.self, forKey: .awaitingReply)) ?? false,
                options: Self.choices(box))

        case "phase":
            self = .phase((try? box.decode(String.self, forKey: .phase)) ?? "")

        case "queued":
            self = .queued(message: (try? box.decode(String.self, forKey: .message)) ?? "queued",
                           position: try? box.decode(Int.self, forKey: .position))

        case "plan":
            self = .plan(Self.steps(box))

        case "injected":
            self = .injected((try? box.decode(String.self, forKey: .message)) ?? "")

        case "done":
            self = .done(status: (try? box.decode(String.self, forKey: .status)) ?? "completed")

        case "error":
            self = .failure(
                code: (try? box.decode(String.self, forKey: .code)) ?? "error",
                message: (try? box.decode(String.self, forKey: .message))
                    ?? (try? box.decode(String.self, forKey: .error)) ?? "the agent reported an error",
                retryable: (try? box.decode(Bool.self, forKey: .retryable)) ?? false)

        default:
            self = .unknown(kind)
        }
    }

    /// `options` may be plain strings or labelled objects depending on what asked the
    /// question. Both become tappable buttons, so both decode to the same thing.
    private static func choices(_ box: KeyedDecodingContainer<Key>) -> [String] {
        if let plain = try? box.decode([String].self, forKey: .options) { return plain }
        if let rich = try? box.decode([[String: JSONLeaf]].self, forKey: .options) {
            return rich.compactMap { entry in
                for field in ["label", "value", "text", "title"] {
                    if case .text(let value)? = entry[field] { return value }
                }
                return nil
            }
        }
        return []
    }

    private static func steps(_ box: KeyedDecodingContainer<Key>) -> [String] {
        if let plain = try? box.decode([String].self, forKey: .steps) { return plain }
        if let rich = try? box.decode([[String: JSONLeaf]].self, forKey: .steps) {
            return rich.compactMap { entry in
                for field in ["title", "step", "description", "content"] {
                    if case .text(let value)? = entry[field] { return value }
                }
                return nil
            }
        }
        return []
    }

    /// A field that may be a string, a number, or a whole object, rendered as one line.
    ///
    /// Tool arguments and results are free-form JSON. The transcript shows them as a
    /// subtitle under the tool name, so all that is needed is something short and true.
    private static func flatten(_ box: KeyedDecodingContainer<Key>, _ key: Key) -> String {
        guard let leaf = try? box.decode(JSONLeaf.self, forKey: key) else { return "" }
        let text = leaf.line
        return text.count > 240 ? String(text.prefix(240)) + "…" : text
    }
}

/// Just enough JSON to render an unknown value as one line of text.
///
/// `JSONSerialization` would do this too, but not from inside a `Decodable`, and pulling a
/// full JSON value type in for two fields would be the larger thing.
indirect enum JSONLeaf: Decodable, Equatable {
    case text(String)
    case number(Double)
    case flag(Bool)
    case list([JSONLeaf])
    case object([String: JSONLeaf])
    case nothing

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .nothing }
        else if let value = try? single.decode(String.self) { self = .text(value) }
        else if let value = try? single.decode(Bool.self) { self = .flag(value) }
        else if let value = try? single.decode(Double.self) { self = .number(value) }
        else if let value = try? single.decode([JSONLeaf].self) { self = .list(value) }
        else if let value = try? single.decode([String: JSONLeaf].self) { self = .object(value) }
        else { self = .nothing }
    }

    var line: String {
        switch self {
        case .text(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .flag(let value): return value ? "true" : "false"
        case .list(let items): return items.map(\.line).joined(separator: ", ")
        case .object(let fields):
            // The pod wraps tool results in a ChatMessageWire and plan steps in a
            // PlanStep. Spelling the whole envelope out puts `role=tool_result id=t1`
            // next to the one word the user wanted, so the readable field wins when
            // there is one and the full dump is the fallback for shapes we do not know.
            for key in ["result", "step", "command", "content", "text", "message"] {
                if let found = fields[key], found != .nothing {
                    return found.line
                }
            }
            return fields.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.line)" }
                .joined(separator: " ")
        case .nothing: return ""
        }
    }
}

/// The SSE line parser.
///
/// Anything that is not a `data:` line — the blank separators, and the `:` keep-alive
/// comments a long watch depends on to stay open — is skipped rather than treated as a
/// malformed frame. An undecodable payload is skipped too: a live turn must not end
/// because one frame in it was unreadable.
enum SSE {
    static func frame(_ line: String) -> WorkshopFrame? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkshopFrame.self, from: data)
    }
}
