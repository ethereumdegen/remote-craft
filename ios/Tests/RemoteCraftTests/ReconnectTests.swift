import XCTest

@testable import RemoteCraft

/// The reconnect schedule has one hard safety property and it is worth proving rather
/// than reading: `ufw limit 22/tcp`, which Omarchy's SSHD setup installs, bans a source
/// address at six connections in thirty seconds. An app that trips that locks its user
/// out of their own machine and looks, from the phone, exactly like a box that has died.
final class DialScheduleTests: XCTestCase {
    /// The adversarial caller: dials the instant it is allowed to, forever, and every
    /// attempt fails. This is the worst a retry loop can behave.
    func testAlwaysFailingGreedyCallerNeverExceedsTheCapInAnyWindow() {
        var schedule = DialSchedule()
        var clock: TimeInterval = 0
        var attempts: [TimeInterval] = []

        for _ in 0..<60 {
            clock = schedule.earliest(after: clock)
            schedule.connected(at: clock)
            attempts.append(clock)
            schedule.failed()
        }

        assertWithinLimit(attempts)
        XCTAssertGreaterThan(clock, 30 * 60, "backoff should have stretched an hour of failures out")
    }

    /// The nastier caller: every attempt *succeeds* and the link drops immediately, so
    /// the exponential backoff resets every time and only the window rule is left to
    /// hold the line. A flapping tailnet produces exactly this.
    func testFlappingConnectionIsStillHeldUnderTheCap() {
        var schedule = DialSchedule()
        var clock: TimeInterval = 0
        var attempts: [TimeInterval] = []

        for _ in 0..<60 {
            clock = schedule.earliest(after: clock)
            schedule.connected(at: clock)
            attempts.append(clock)
            schedule.succeeded()
        }

        assertWithinLimit(attempts)
    }

    /// The case the schedule originally got wrong, and the one that matters most on a
    /// real Omarchy box. A host with a MagicDNS name *and* a pinned `100.x` fallback —
    /// which the host editor pushes every user towards — opens **two** sockets per
    /// attempt, not one. ufw counts sockets. A schedule that charged one per attempt let
    /// three retries make six connections in fifteen seconds and banned the phone from
    /// the box, after which the app dialled into a ban it had created itself.
    func testATwoCandidateHostNeverExceedsTheCapInConnections() {
        var schedule = DialSchedule()
        var clock: TimeInterval = 0
        var sockets: [TimeInterval] = []
        // A failing address burns the whole connect timeout before the next is tried, so
        // the second socket of an attempt is opened ten seconds after the first.
        let perAddress = TimeInterval(Omarchy.connectTimeout)

        for _ in 0..<40 {
            clock = schedule.earliest(after: clock, connections: 2)
            for address in 0..<2 {
                let at = clock + TimeInterval(address) * perAddress
                schedule.connected(at: at)
                sockets.append(at)
            }
            clock += perAddress
            schedule.failed()
        }

        assertWithinLimit(sockets)
    }

    /// And the same host with a user hammering "connect": every attempt succeeds
    /// immediately, so backoff never engages and only the connection budget is holding
    /// the line.
    func testATwoCandidateHostIsHeldUnderTheCapWithNoBackoffToHelp() {
        var schedule = DialSchedule()
        var sockets: [TimeInterval] = []
        var clock: TimeInterval = 500

        for _ in 0..<40 {
            clock = schedule.earliest(after: clock, connections: 2)
            schedule.connected(at: clock)
            sockets.append(clock)
            // The first address answered, so the second is never dialled — the budget
            // was reserved for two and only one was spent, which must not leak.
            schedule.succeeded()
        }

        assertWithinLimit(sockets)
    }

    /// A user hammering the connect button is the third caller, and it goes through the
    /// same schedule — which is the point of the schedule living in the store rather
    /// than in the retry path.
    func testImpatientUserIsDelayedRatherThanBanned() {
        var schedule = DialSchedule()
        var attempts: [TimeInterval] = []
        let now: TimeInterval = 1_000

        for _ in 0..<12 {
            let at = schedule.earliest(after: now)
            schedule.connected(at: at)
            attempts.append(at)
            schedule.succeeded()
        }

        assertWithinLimit(attempts)
        XCTAssertEqual(attempts.prefix(DialSchedule.connectionsPerWindow).count,
                       DialSchedule.connectionsPerWindow)
        XCTAssertTrue(attempts.prefix(DialSchedule.connectionsPerWindow).allSatisfy { $0 == now },
                      "the first five taps should not be delayed at all")
    }

    /// The first retry is never faster than five seconds, and the wait grows.
    func testBackoffStartsAtFiveSecondsAndDoubles() {
        var schedule = DialSchedule()
        schedule.connected(at: 0)
        schedule.failed()
        XCTAssertEqual(schedule.earliest(after: 0), 5)

        schedule.connected(at: 5)
        schedule.failed()
        XCTAssertEqual(schedule.earliest(after: 5), 15)

        schedule.connected(at: 15)
        schedule.failed()
        XCTAssertEqual(schedule.earliest(after: 15), 35)
    }

    /// Backoff has a ceiling: a box someone is walking over to enable SSH on has to be
    /// picked up within a couple of minutes of them running the command.
    func testBackoffIsCapped() {
        var schedule = DialSchedule()
        var clock: TimeInterval = 0
        for _ in 0..<20 {
            clock = schedule.earliest(after: clock)
            schedule.connected(at: clock)
            schedule.failed()
        }

        XCTAssertEqual(schedule.earliest(after: clock) - clock, DialSchedule.maximumBackoff)
    }

    /// A success clears the backoff, because a connection that worked is new information.
    func testSuccessResetsTheBackoff() {
        var schedule = DialSchedule()
        schedule.connected(at: 0)
        schedule.failed()
        schedule.connected(at: 5)
        schedule.failed()
        schedule.succeeded()

        XCTAssertEqual(schedule.earliest(after: 5), 5, "no backoff is owed after a success")
    }

    /// Slid over every attempt, inclusive at both ends: ufw counts in whole seconds and
    /// a schedule that is only safe for half-open windows is not safe.
    private func assertWithinLimit(_ attempts: [TimeInterval],
                                   file: StaticString = #filePath, line: UInt = #line) {
        for start in attempts {
            let inWindow = attempts.filter { $0 >= start && $0 <= start + DialSchedule.window }
            XCTAssertLessThanOrEqual(
                inWindow.count, DialSchedule.connectionsPerWindow,
                "\(inWindow.count) attempts inside the 30s window starting at \(start)",
                file: file, line: line)
        }
    }
}
