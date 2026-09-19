import Foundation

/// When this app is allowed to open a TCP connection to port 22.
///
/// Two rules, and the second one is not negotiable.
///
/// **Exponential backoff**, because a box that just refused a connection will refuse the
/// next one too, and hammering it is how a reconnect loop turns one failure into a
/// hundred.
///
/// **A hard ceiling of five connections in any thirty-second window**, because
/// `omarchy-setup-security-sshd` runs `ufw limit 22/tcp`, and ufw's `limit` rule *bans
/// the source address* at six connections in thirty seconds. An app that trips that rule
/// locks the user out of their own machine for minutes at a time and looks, from the
/// phone, exactly like a box that has gone down. Five is the largest number that cannot
/// trip it; the one-second slack below keeps the app clear of the boundary, since ufw
/// counts in whole seconds and this app counts in fractions of one.
///
/// The unit is a **connection**, not an "attempt", and the difference is the whole point:
/// one attempt on a host with a MagicDNS name and a pinned fallback opens *two* sockets,
/// and a schedule that charged one would let three retries make six connections and ban
/// the phone in fifteen seconds. Callers reserve the whole block up front with
/// `earliest(after:connections:)` and then charge each socket as it is actually opened.
///
/// A value type with time passed in, so the whole schedule can be simulated in a test
/// rather than waited out.
struct DialSchedule {
    /// One below ufw's ban threshold of six per thirty seconds.
    static let connectionsPerWindow = 5
    /// ufw's window, to the second.
    static let window: TimeInterval = 30
    /// The first wait after a failure. Never faster: four of these fit in the window
    /// alongside the attempt that started it.
    static let firstBackoff: TimeInterval = 5
    /// Where the doubling stops. A box someone is walking over to fix should be picked up
    /// within a couple of minutes of them running the command.
    static let maximumBackoff: TimeInterval = 120
    /// Keeps a rescheduled attempt off the exact edge of the window.
    static let slack: TimeInterval = 1

    /// When each recent connection was opened, oldest first. Pruned to the window: one
    /// older than that can never constrain a future one.
    private var connections: [TimeInterval] = []
    /// Consecutive failures since the last success, which is the backoff exponent.
    private var failures = 0

    init() {}

    /// Connections opened within the last window, `now` included.
    func connectionsInWindow(at now: TimeInterval) -> Int {
        connections.filter { $0 >= now - Self.window }.count
    }

    /// The earliest moment the next attempt may begin, given that it will open
    /// `connections` sockets. Never earlier than `now`, and never earlier than the last
    /// connection — a caller whose clock has not moved (a user tapping "connect" twice in
    /// the same instant) must not be handed a slot it has already used, or the window
    /// bookkeeping goes backwards and stops counting.
    ///
    /// The whole block is reserved at once. The sockets themselves open over the next few
    /// seconds as each address is tried, which only ever moves them later than the moment
    /// checked here — and no window that starts at or after the returned time can contain
    /// an older connection, so a block that fits at `T` fits wherever its members land.
    func earliest(after now: TimeInterval, connections wanted: Int = 1) -> TimeInterval {
        // What may still be in the window once this attempt's own sockets are counted.
        // Clamped at zero: a host with more candidate addresses than the whole budget
        // cannot be dialled without exceeding it, and refusing to dial at all would be a
        // terminal that never connects.
        let room = max(0, Self.connectionsPerWindow - max(1, wanted))
        var candidate = max(now, connections.last ?? now)
        if failures > 0, let last = connections.last {
            let backoff = min(Self.firstBackoff * pow(2, Double(failures - 1)), Self.maximumBackoff)
            candidate = max(candidate, last + backoff)
        }
        // Evaluated at the candidate time rather than at `now`: waiting for backoff also
        // empties the window, and charging for both would compound two delays that are
        // really one. At most two passes — pushing past the k-th oldest connection in the
        // window can only leave fewer behind it.
        while true {
            let recent = connections.filter { $0 >= candidate - Self.window }
            guard recent.count > room else { return candidate }
            let blocking = recent[recent.count - room - 1]
            candidate = max(candidate, blocking + Self.window + Self.slack)
        }
    }

    /// Record that a socket is being opened. Charged per address, not per attempt: ufw
    /// counts SYNs and does not know that two of them were one user gesture.
    mutating func connected(at now: TimeInterval) {
        connections.removeAll { $0 < now - Self.window }
        connections.append(now)
    }

    mutating func failed() {
        failures += 1
    }

    /// A connection came up. The backoff resets; the window does not, because ufw counts
    /// connections and does not care whether they worked.
    mutating func succeeded() {
        failures = 0
    }
}
