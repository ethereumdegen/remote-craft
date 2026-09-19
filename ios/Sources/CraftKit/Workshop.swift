import Foundation

enum WorkshopError: LocalizedError {
    case noToken
    case unreachable(String)
    case http(status: Int, detail: String)
    case transport(String)
    case noChatID

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "This host has no agent key. Paste the workshop API key in the host editor."
        case .unreachable(let detail):
            return "No metalcraft-agent answered: \(detail). Check it is running on the box and that Tailscale is up on this phone."
        case .http(let status, let detail) where status == 401 || status == 403:
            return "The agent refused the key (HTTP \(status)). \(detail)"
        case .http(let status, let detail):
            return "The agent answered HTTP \(status). \(detail)"
        case .transport(let detail):
            return detail
        case .noChatID:
            return "The agent created a chat but did not say which one. Check its version."
        }
    }
}

/// metalcraft-agent's workshop API, which is the one agent in this product with a real
/// network interface.
///
/// OMP has none — it speaks ACP over an SSH exec channel — and starkbot-neo has none
/// either. So this client is HTTP, everything under `/api/v1/`, `Authorization: Bearer`,
/// and it is the only part of the app that is not tunnelled through SSH. The transport is
/// plain HTTP because the tailnet is already the encrypted, authenticated network; the
/// bearer is what distinguishes *this* user on it.
///
/// A value type holding a resolved base: which of the host's candidate addresses actually
/// answered is decided once by `resolve`, and every later call uses that answer instead of
/// re-racing two addresses per request.
struct Workshop {
    let base: URL
    let token: String

    private var session: URLSession { .shared }

    /// Probe the host's candidate addresses and keep the one that answers.
    ///
    /// The probe is `GET /info` — cheap, unauthenticated-ish, and it fails fast on the
    /// address that does not resolve, which is the whole reason the fallback exists.
    static func resolve(host: SSHHost, token: String) async throws -> (Workshop, String) {
        guard !token.isEmpty else { throw WorkshopError.noToken }
        let bases = host.agentBases()
        guard !bases.isEmpty else { throw WorkshopError.unreachable("this host has no address") }

        var failures: [String] = []
        for base in bases {
            let client = Workshop(base: base, token: token)
            do {
                let summary = try await client.info()
                return (client, summary)
            } catch {
                failures.append("\(base.host() ?? base.absoluteString): \(Self.short(error))")
            }
        }
        throw WorkshopError.unreachable(failures.joined(separator: " · "))
    }

    /// `GET /info` — also the wake probe, because it is the cheapest call that proves the
    /// socket path still works end to end.
    func info() async throws -> String {
        let data = try await send(request("info", method: "GET"), timeout: 8)
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "agent"
        }
        let name = fields["name"] as? String ?? fields["agent"] as? String ?? "metalcraft-agent"
        if let version = fields["version"] as? String { return "\(name) \(version)" }
        return name
    }

    func createChat(preset: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["agent_preset": preset])
        let data = try await send(request("chats", method: "POST", body: body), timeout: 20)
        guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkshopError.noChatID
        }
        if let id = fields["id"] as? String { return id }
        if let id = fields["chat_id"] as? String { return id }
        if let id = fields["id"] as? Int { return String(id) }
        throw WorkshopError.noChatID
    }

    /// `POST /interrupt`. Note what this does **not** do: end the turn. The agent replies
    /// `{stopping:…}` and keeps streaming until it emits `done`, so the composer stays
    /// locked until that frame arrives.
    func interrupt(chat: String) async throws {
        _ = try await send(request("chats/\(chat)/interrupt", method: "POST", body: Data("{}".utf8)),
                           timeout: 15)
    }

    /// Send a message and stream the turn it produces.
    ///
    /// The status code is a fork in the protocol, not a detail:
    /// **200** means the response body *is* the SSE stream for this turn.
    /// **202** means another turn was already running; the body is
    /// `{"queued":true,"position":N}` and this turn's frames will appear on the chat's
    /// shared events channel instead. Reading the 202 body as SSE — the obvious mistake —
    /// yields one unparseable line and then silence for the entire turn.
    ///
    /// On a 202 this stream says "queued" and ends. Attaching to `/events` here would be
    /// the *second* connection to a broadcast the caller already watches: every frame
    /// folded twice, duplicate replies and tool rows, and — since a completion resolves
    /// only the last row with its id — a gear spinning forever on the other copy. The
    /// broadcast's `done` would also be the *previous* turn's, unlocking the composer
    /// while this phone's message is still sitting in the queue.
    func turn(chat: String, message: String) -> AsyncThrowingStream<WorkshopFrame, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let body = try JSONSerialization.data(withJSONObject: ["message": message])
                    var urlRequest = request("chats/\(chat)/turn", method: "POST", body: body)
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.timeoutInterval = 300

                    let (bytes, response) = try await open(urlRequest)
                    switch response.statusCode {
                    case 200:
                        try await drain(bytes, into: continuation, stopAtDone: true)
                    case 202:
                        var payload = ""
                        for try await line in bytes.lines { payload += line }
                        let fields = (try? JSONSerialization.jsonObject(with: Data(payload.utf8)))
                            as? [String: Any]
                        continuation.yield(.queued(message: "another turn is already running",
                                                   position: fields?["position"] as? Int))
                    default:
                        throw WorkshopError.http(status: response.statusCode,
                                                 detail: try await firstLine(bytes))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Attach to the chat's broadcast channel and stay attached.
    ///
    /// Deliberately does not stop at `done`: a turn started from somewhere else — a
    /// laptop, a schedule, the box's own CLI — arrives on the same channel, and a session
    /// left open on a phone should show it rather than pretending nothing happened.
    func watch(chat: String) -> AsyncThrowingStream<WorkshopFrame, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    var urlRequest = request("chats/\(chat)/events", method: "GET")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // An hour, not a minute: a watch is idle most of its life and the
                    // agent holds it open with `:` comments. A short timeout here would
                    // tear down a healthy stream every time nobody typed.
                    urlRequest.timeoutInterval = 3600
                    let (bytes, response) = try await open(urlRequest)
                    guard response.statusCode == 200 else {
                        throw WorkshopError.http(status: response.statusCode,
                                                 detail: try await firstLine(bytes))
                    }
                    try await drain(bytes, into: continuation, stopAtDone: false)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - plumbing

    private func drain(_ bytes: URLSession.AsyncBytes,
                       into continuation: AsyncThrowingStream<WorkshopFrame, Error>.Continuation,
                       stopAtDone: Bool) async throws {
        for try await line in bytes.lines {
            guard let frame = SSE.frame(line) else { continue }
            continuation.yield(frame)
            if stopAtDone, frame.isTerminal { return }
        }
    }

    private func firstLine(_ bytes: URLSession.AsyncBytes) async throws -> String {
        for try await line in bytes.lines { return line }
        return ""
    }

    private func request(_ path: String, method: String, body: Data? = nil) -> URLRequest {
        var urlRequest = URLRequest(url: base.appendingPathComponent(path))
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    private func open(_ urlRequest: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw WorkshopError.transport(Self.short(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw WorkshopError.transport("the agent gave no HTTP response")
        }
        return (bytes, http)
    }

    private func send(_ urlRequest: URLRequest, timeout: TimeInterval) async throws -> Data {
        var urlRequest = urlRequest
        urlRequest.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw WorkshopError.transport(Self.short(error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw WorkshopError.transport("the agent gave no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WorkshopError.http(status: http.statusCode,
                                     detail: String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    /// URLError's own descriptions are the only network strings a user ever reads here, and
    /// "The operation couldn't be completed" is not one of them.
    static func short(_ error: Error) -> String {
        if let workshop = error as? WorkshopError { return workshop.localizedDescription }
        guard let url = error as? URLError else { return error.localizedDescription }
        switch url.code {
        case .cannotFindHost: return "that name does not resolve — MagicDNS may be down; a 100.x fallback fixes it"
        case .cannotConnectToHost: return "nothing is listening on that port"
        case .timedOut: return "timed out"
        case .networkConnectionLost: return "the connection dropped"
        case .notConnectedToInternet: return "this phone has no network"
        default: return url.localizedDescription
        }
    }
}
