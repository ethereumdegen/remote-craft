import XCTest

@testable import RemoteCraft

/// A wake generation is not a notification, it is a demolition order: the terminal store
/// tears down its PTY and the agent store clears `busy` and re-probes. Getting the
/// *trigger* wrong is therefore not cosmetic — it costs the user their cwd, their
/// environment, and whatever was running in the foreground of the remote shell.
@MainActor
final class WakeTests: XCTestCase {
    /// Control Centre, Notification Centre, the app switcher, a call banner, a
    /// permission alert: every one of those is `.inactive`, the process keeps running,
    /// and every socket it holds keeps working. Counting one as a wake killed a healthy
    /// shell for the sin of the user glancing at their notifications.
    func testATransientInterruptionDoesNotCountAsAWake() {
        let wake = Wake()
        wake.active()

        // `.inactive` is deliberately not wired to anything, so a transient interruption
        // is a pair of phase changes with no call in between.
        wake.active()

        XCTAssertEqual(wake.generation, 0)
    }

    /// A real backgrounding is the one thing that suspends the process, and iOS discards
    /// the sockets of a suspended process without telling anyone.
    func testARealBackgroundingCountsAsAWake() {
        let wake = Wake()
        wake.active()

        wake.background()
        wake.active()

        XCTAssertEqual(wake.generation, 1)
    }

    /// A cold launch reaches `.active` too, and it is the one activation that is not a
    /// wake: nothing was suspended and there is nothing to recover. Bumping there tears
    /// down the session the launch itself just opened.
    func testAColdStartIsNotAWake() {
        let wake = Wake()

        wake.active()

        XCTAssertEqual(wake.generation, 0)
    }

    /// The old implementation used elapsed time, which cannot work: a session that has
    /// been up for hours and is interrupted for two seconds clears any plausible guard
    /// just as easily as a genuine overnight suspend. Length of absence is not evidence;
    /// having been backgrounded is.
    func testTheBumpDependsOnBackgroundingNotOnHowLongTheAppWasAway() {
        let wake = Wake()
        wake.active()

        // Away long enough that any elapsed-time debounce would have expired, but never
        // actually backgrounded.
        wake.active()
        wake.active()
        XCTAssertEqual(wake.generation, 0)

        // Away for no time at all, but genuinely backgrounded.
        wake.background()
        wake.active()
        XCTAssertEqual(wake.generation, 1)
    }

    /// One bump per backgrounding. A second `.active` without another `.background` — an
    /// alert dismissed just after the app came forward — must not tear the session down
    /// a second time.
    func testOneBackgroundingProducesExactlyOneBump() {
        let wake = Wake()
        wake.active()

        wake.background()
        wake.active()
        wake.active()
        wake.active()

        XCTAssertEqual(wake.generation, 1)
    }
}
