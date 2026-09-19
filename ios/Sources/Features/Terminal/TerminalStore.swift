import Foundation
import Observation

/// Owns the PTY and the bytes going each way.
///
/// It lives at app scope, not inside the terminal screen, so switching to the Agent tab
/// does not kill the shell — a shell that dies when you look away is not a shell, it is a
/// command runner.
///
/// Bytes arriving before the SwiftTerm view exists are buffered rather than dropped: the
/// remote shell prints its prompt the instant the PTY opens, which is reliably before
/// `makeUIView` has run on the first launch of the tab.
///
/// It also owns *when* the app is allowed to dial. Omarchy opens port 22 with
/// `ufw limit`, which bans a source address at six connections in thirty seconds, so the
/// retry loop goes through `DialSchedule` and no path around it exists — including the
/// user tapping "connect" repeatedly, which is exactly how a person locks themselves out.
@MainActor
@Observable
final class TerminalStore {
    private(set) var state: Liveness = .idle
    private(set) var banner: String = "no host"
    /// Bumped whenever the terminal should be rebuilt from scratch — currently only on a
    /// host change, which needs a clean screen rather than two boxes' scrollback merged.
    private(set) var incarnation = 0
    /// The named reason the last attempt failed, or nil while nothing is wrong. The
    /// screen renders this instead of an error string.
    private(set) var diagnosis: Diagnosis?
    /// Whether a PTY has ever opened for the current host. Until it has, there is no
    /// scrollback worth showing and the failure belongs on the whole screen.
    private(set) var everOpened = false
    /// Whether another attempt is actually scheduled. The failure screen reads this
    /// rather than `Diagnosis.worthRetrying`, because the two diverge: the loop gives up
    /// on a failure it cannot name, and a screen that keeps promising to retry after it
    /// has stopped leaves the user waiting for something that will not happen.
    private(set) var retrying = false

    /// Bytes buffered before a view exists are capped: `deliver` has no feed during the
    /// whole diagnosis/idle branch, and a `yes` or a `cargo build` in the remote shell
    /// would otherwise grow this until jetsam kills the app. A quarter-megabyte is more
    /// scrollback than a phone screen can show; dropping the oldest of it is what a
    /// terminal does anyway.
    static let backlogCap = 256 * 1024
    /// Trimmed down to here rather than to the cap, so a full buffer does not memmove a
    /// quarter-megabyte for every chunk that arrives.
    static let backlogKeep = 192 * 1024
    /// How many failures this app could not name in a row before the retry loop gives up.
    /// `.unrecognised` is worth retrying — a flap during a handshake produces one — but
    /// an unnamed failure that keeps repeating is not going to name itself, and a loop
    /// that dials forever against it spends the firewall's patience for nothing. The
    /// reconnect button is the way out.
    static let unknownFailureLimit = 5

    private let session = ShellSession()
    /// Installed by `TerminalSurface` once the UIKit view exists.
    private var feed: (([UInt8]) -> Void)?
    /// Identifies the current feed. SwiftUI does not guarantee that the old view is
    /// dismantled before the new one is made, so on a host change or a palette change the
    /// outgoing view's `dismantleUIView` can run *after* the incoming view has installed
    /// its feed. Releasing by token means a stale dismantle is ignored rather than
    /// blanking a live terminal for the rest of the process.
    private var feedToken = 0
    private var backlog: [UInt8] = []
    private var host: SSHHost?
    /// The address the live session actually attached to, which is not always the one
    /// in `host`: a MagicDNS name that did not resolve falls back to the pinned `100.x`
    /// address, and reporting an enrollment against the name that failed would be a
    /// lie. Only meaningful while `isLive`, which is what reads it — `state` leaves
    /// `.up` on every path that ends a session, so a stale address is unreachable
    /// rather than merely unlikely.
    private var attachedAddress = ""
    private var keys: [KeyRecord] = []
    private var size = (cols: 80, rows: 24)
    /// The wake generation this session was started under. A bump means the socket under
    /// it is suspect, and the session is rebuilt rather than trusted.
    private var bornAt = 0
    /// Incremented for every session this store starts or stops. Callbacks carry the
    /// epoch they were created under so a dead session cannot narrate over a live one.
    private var epoch = 0
    private var schedule = DialSchedule()
    /// Consecutive failures this app had no name for, reset by anything it could name
    /// and by a connection that worked.
    private var unknownFailures = 0
    /// The pending dial, whether it is waiting out a backoff or already running.
    private var pending: Task<Void, Never>?

    var isLive: Bool { state == .up }

    // MARK: - view wiring

    /// Install the sink the terminal view draws with, and hand back the token that
    /// identifies it. Pass the token to `release(feed:)` on dismantle.
    func install(feed: @escaping ([UInt8]) -> Void) -> Int {
        feedToken += 1
        self.feed = feed
        if !backlog.isEmpty {
            feed(backlog)
            backlog.removeAll(keepingCapacity: false)
        }
        return feedToken
    }

    /// Drop the feed, but only if it is still the one the caller installed.
    func release(feed token: Int) {
        guard token == feedToken else { return }
        feed = nil
    }

    // MARK: - session

    /// Point the terminal at a host and start dialling.
    ///
    /// Every caller of this is a person or a wake: the backoff resets, because a human
    /// asking again is new information. The thirty-second window does not reset, because
    /// ufw counts connections and does not care who asked for them.
    func connect(host: SSHHost, keys: [KeyRecord], generation: Int) {
        if self.host?.id != host.id {
            incarnation += 1
            everOpened = false
        }
        self.host = host
        self.keys = keys
        self.bornAt = generation
        banner = host.label
        diagnosis = nil
        unknownFailures = 0
        schedule.succeeded()
        dial()
    }

    func disconnect() {
        epoch += 1
        pending?.cancel()
        pending = nil
        retrying = false
        diagnosis = nil
        session.stop()
        state = .idle
        write(note: "session closed")
    }

    /// The wake pass. Only a session that believed it was live is rebuilt: a screen the
    /// user never connected should stay quiet, and a session already reporting a failure
    /// has nothing to lose by waiting for the user.
    func wake(generation: Int, keys: [KeyRecord]) {
        guard let host, state == .up || state == .working, generation != bornAt else {
            bornAt = generation
            return
        }
        write(note: "reconnecting after wake")
        session.stop()
        self.keys = keys
        connect(host: host, keys: keys, generation: generation)
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        session.send(bytes)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, (cols, rows) != (size.cols, size.rows) else { return }
        size = (cols, rows)
        session.resize(cols: cols, rows: rows)
    }

    /// Authorize one more public key on the box this terminal is connected to.
    ///
    /// Goes over the live session rather than dialling. A second dialer would keep its
    /// own view of ufw's six-connections-per-thirty-seconds window and ban the phone
    /// from the box it is enrolling, and sharing `DialSchedule` would be worse in a
    /// quieter way: its failure counter is the terminal's reconnect backoff, and a
    /// one-shot enrollment failure has no business lengthening it.
    func authorize(_ line: String) async -> AuthorizeResult {
        guard isLive, !attachedAddress.isEmpty else {
            return .failed("The terminal is not connected to that box, so there is no session to authorize over. Connect first — this route needs a box the phone can already reach.")
        }
        return await session.authorize(line: line, address: attachedAddress)
    }

    /// Start one attempt, no sooner than the schedule allows.
    ///
    /// The wait is announced rather than silent: an app that appears to do nothing for
    /// forty seconds is indistinguishable from an app that has hung, and the reason —
    /// the box's own firewall — is worth knowing.
    private func dial() {
        guard let host else { return }
        // Before anything else, and in particular before the backoff below. Bumping the
        // epoch makes `handle` discard everything the old session says, so a session
        // left running would go on filling a screen nobody repaints while `send(_:)`
        // kept forwarding keystrokes into its still-open outbox — the user typing blind
        // into a live remote shell for up to half a minute. `stop()` is idempotent.
        session.stop()
        epoch += 1
        let epoch = self.epoch
        let now = Date.timeIntervalSinceReferenceDate
        // One attempt opens one socket per candidate address, and ufw counts sockets.
        // Reserving the whole block up front is what stops a host with a fallback from
        // spending the budget twice as fast as the schedule believes.
        let connections = max(1, host.candidates().count)
        let start = schedule.earliest(after: now, connections: connections)
        let wait = start - now

        pending?.cancel()
        retrying = true
        state = .working
        if wait > 0 {
            write(note: "next attempt in \(Int(wait.rounded()))s — Omarchy's ufw limit bans at 6 connections per 30s")
        }

        pending = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.epoch == epoch else { return }
            self.session.start(host: host,
                               keys: self.keys,
                               cols: self.size.cols,
                               rows: self.size.rows,
                               charge: { [weak self] _ in
                                   // Only nil once the store is gone, which means nothing
                                   // will render the diagnosis anyway: count this socket.
                                   await self?.charge() ?? 1
                               }) { [weak self] event in
                self?.handle(event, epoch: epoch)
            }
        }
    }

    /// Record one socket about to be opened and say how many are now in the window.
    private func charge() -> Int {
        let at = Date.timeIntervalSinceReferenceDate
        schedule.connected(at: at)
        return schedule.connectionsInWindow(at: at)
    }

    private func handle(_ event: ShellEvent, epoch: Int) {
        // A session that has been replaced still reports its own death, and that report
        // arrives after its replacement is already up. Letting it land paints a live
        // terminal red and tells the user a working shell has exited.
        guard epoch == self.epoch else { return }
        switch event {
        case .opened(let attached):
            attachedAddress = attached.address
            state = .up
            everOpened = true
            diagnosis = nil
            retrying = false
            unknownFailures = 0
            schedule.succeeded()
            if let host, attached.address != host.address, !host.address.isEmpty {
                // Worth saying out loud: the MagicDNS name did not work and the pinned
                // address did. That is a Tailscale problem on the phone, not a bug here.
                write(note: "connected via \(attached.address) — the MagicDNS name did not answer")
            }
            if attached.newlyPinned, let fingerprint = attached.fingerprint {
                // The one moment a fingerprint is worth reading: it was trusted because
                // nothing contradicted it, and this is the user's chance to check.
                write(note: "pinned host key \(fingerprint)")
                write(note: "verify on the box: \(Omarchy.hostKeyCheck)")
            }
        case .data(let bytes):
            deliver(bytes)
        case .closed(let reason):
            retrying = false
            state = reason == "closed" ? .idle : .down(reason)
            write(note: reason)
        case .failed(let failure):
            schedule.failed()
            unknownFailures = failure.cause == .unrecognised ? unknownFailures + 1 : 0
            diagnosis = failure
            state = .down(failure.title)
            write(note: failure.title)
            if let remedy = failure.remedy {
                write(note: "on the box: \(remedy)")
            }
            // Retrying a refused key only spends the firewall's patience; retrying a box
            // someone is walking over to enable SSH on is the whole point of the loop.
            // An unnamed failure that keeps repeating is in the first category however
            // much it looks like the second, so the loop stops and says so.
            if failure.worthRetrying, unknownFailures < Self.unknownFailureLimit {
                dial()
                return
            }
            retrying = false
            if failure.worthRetrying {
                write(note: "stopping after \(unknownFailures) failures this app cannot name — use reconnect to try again")
            }
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        if let feed {
            feed(bytes)
            return
        }
        backlog.append(contentsOf: bytes)
        if backlog.count > Self.backlogCap {
            backlog.removeFirst(backlog.count - Self.backlogKeep)
        }
    }

    /// A line the app wrote, not the box. Dim and bracketed so it cannot be mistaken for
    /// remote output — this is a terminal, and forging shell output would be unforgivable.
    private func write(note: String) {
        deliver(Array("\r\n\u{1B}[2m[\(note)]\u{1B}[0m\r\n".utf8))
    }
}
