import Foundation

/// When this app is allowed to dial.
///
/// Two rules, and the second one is not negotiable.
///
/// **Exponential backoff**, because a box that just refused a connection will refuse the
/// next one too, and hammering it is how a reconnect loop turns one failure into a
/// hundred.
///
/// **A hard ceiling of five attempts in any thirty-second window**, because
/// `omarchy-setup-security-sshd` runs `ufw limit 22/tcp`, and ufw's `limit` rule *bans
/// the source address* at six connections in thirty seconds. An app that trips that rule
/// locks the user out of their own machine for minutes at a time and looks, from the
/// phone, exactly like a box that has gone down. Five is the largest number that cannot
/// trip it; the one-second slack below keeps the app clear of the boundary, since ufw
/// counts in whole seconds and this app counts in fractions of one.
///
/// A value type with time passed in, so the whole schedule can be simulated in a test
/// rather than waited out.
struct DialSchedule {
    /// One below ufw's ban threshold of six per thirty seconds.
    static let attemptsPerWindow = 5
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

    /// When each recent attempt started, oldest first. Pruned to the window: an attempt
    /// older than that can never constrain a future one.
    private var attempts: [TimeInterval] = []
    /// Consecutive failures since the last success, which is the backoff exponent.
    private var failures = 0

    init() {}

    /// Attempts started within the last window, `now` included.
    func attemptsInWindow(at now: TimeInterval) -> Int {
        attempts.filter { $0 >= now - Self.window }.count
    }

    /// The earliest moment the next attempt may begin. Never earlier than `now`, and
    /// never earlier than the last attempt — a caller whose clock has not moved (a user
    /// tapping "connect" twice in the same instant) must not be handed a slot it has
    /// already used, or the window bookkeeping goes backwards and stops counting.
    func earliest(after now: TimeInterval) -> TimeInterval {
        var candidate = max(now, attempts.last ?? now)
        if failures > 0, let last = attempts.last {
            let backoff = min(Self.firstBackoff * pow(2, Double(failures - 1)), Self.maximumBackoff)
            candidate = max(candidate, last + backoff)
        }
        // Evaluated at the candidate time rather than at `now`: waiting for backoff also
        // empties the window, and charging for both would compound two delays that are
        // really one. At most two passes — pushing past the k-th oldest attempt in the
        // window can only leave fewer behind it.
        while true {
            let recent = attempts.filter { $0 >= candidate - Self.window }
            guard recent.count >= Self.attemptsPerWindow else { return candidate }
            let blocking = recent[recent.count - Self.attemptsPerWindow]
            candidate = max(candidate, blocking + Self.window + Self.slack)
        }
    }

    /// Record that an attempt is starting.
    mutating func attempted(at now: TimeInterval) {
        attempts.removeAll { $0 < now - Self.window }
        attempts.append(now)
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
