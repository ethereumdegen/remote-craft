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

    private let session = ShellSession()
    /// Installed by `TerminalSurface` once the UIKit view exists.
    private var feed: (([UInt8]) -> Void)?
    private var backlog: [UInt8] = []
    private var host: SSHHost?
    private var keys: [KeyRecord] = []
    private var size = (cols: 80, rows: 24)
    /// The wake generation this session was started under. A bump means the socket under
    /// it is suspect, and the session is rebuilt rather than trusted.
    private var bornAt = 0
    /// Incremented for every session this store starts or stops. Callbacks carry the
    /// epoch they were created under so a dead session cannot narrate over a live one.
    private var epoch = 0
    private var schedule = DialSchedule()
    /// The pending dial, whether it is waiting out a backoff or already running.
    private var pending: Task<Void, Never>?

    var isLive: Bool { state == .up }

    // MARK: - view wiring

    func install(feed: @escaping ([UInt8]) -> Void) {
        self.feed = feed
        if !backlog.isEmpty {
            feed(backlog)
            backlog.removeAll(keepingCapacity: false)
        }
    }

    func releaseFeed() { feed = nil }

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
        schedule.succeeded()
        dial()
    }

    func disconnect() {
        epoch += 1
        pending?.cancel()
        pending = nil
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

    /// Start one attempt, no sooner than the schedule allows.
    ///
    /// The wait is announced rather than silent: an app that appears to do nothing for
    /// forty seconds is indistinguishable from an app that has hung, and the reason —
    /// the box's own firewall — is worth knowing.
    private func dial() {
        guard let host else { return }
        epoch += 1
        let epoch = self.epoch
        let now = Date.timeIntervalSinceReferenceDate
        let start = schedule.earliest(after: now)
        let wait = start - now

        pending?.cancel()
        state = .working
        if wait > 0 {
            write(note: "next attempt in \(Int(wait.rounded()))s — Omarchy's ufw limit bans at 6 connections per 30s")
        }

        pending = Task { [weak self] in
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let self, self.epoch == epoch else { return }
            let at = Date.timeIntervalSinceReferenceDate
            self.schedule.attempted(at: at)
            self.session.start(host: host,
                               keys: self.keys,
                               cols: self.size.cols,
                               rows: self.size.rows,
                               attemptsInWindow: self.schedule.attemptsInWindow(at: at)) { [weak self] event in
                self?.handle(event, epoch: epoch)
            }
        }
    }

    private func handle(_ event: ShellEvent, epoch: Int) {
        // A session that has been replaced still reports its own death, and that report
        // arrives after its replacement is already up. Letting it land paints a live
        // terminal red and tells the user a working shell has exited.
        guard epoch == self.epoch else { return }
        switch event {
        case .opened(let attached):
            state = .up
            everOpened = true
            diagnosis = nil
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
            state = reason == "closed" ? .idle : .down(reason)
            write(note: reason)
        case .failed(let failure):
            schedule.failed()
            diagnosis = failure
            state = .down(failure.title)
            write(note: failure.title)
            if let remedy = failure.remedy {
                write(note: "on the box: \(remedy)")
            }
            // Retrying a refused key only spends the firewall's patience; retrying a box
            // someone is walking over to enable SSH on is the whole point of the loop.
            if failure.worthRetrying { dial() }
        }
    }

    private func deliver(_ bytes: [UInt8]) {
        if let feed {
            feed(bytes)
        } else {
            backlog.append(contentsOf: bytes)
        }
    }

    /// A line the app wrote, not the box. Dim and bracketed so it cannot be mistaken for
    /// remote output — this is a terminal, and forging shell output would be unforgivable.
    private func write(note: String) {
        deliver(Array("\r\n\u{1B}[2m[\(note)]\u{1B}[0m\r\n".utf8))
    }
}
