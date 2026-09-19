import Foundation
import SwiftUI

/// The counter every live connection watches.
///
/// iOS suspends this process and, while it is suspended, quietly tears down its sockets.
/// The damage is not that the connection dies — it is that **nothing observes it dying**:
/// a task parked in `for try await line in bytes.lines` on a socket the system has
/// discarded does not return, does not throw, and does not time out. The app comes back to
/// a terminal that looks attached, a status dot that says live, and a keyboard whose
/// keystrokes go nowhere.
///
/// So every return to `.active` bumps this counter, and the terminal and agent screens
/// treat a bump as "drop what you are holding, it is probably a corpse; re-probe and
/// re-attach". Coalescing matters because `scenePhase` also reaches `.active` for things
/// that are not a wake at all — dismissing a sheet, closing Control Centre, the app
/// switcher — and each of those must not tear down a healthy session.
@MainActor
@Observable
final class Wake {
    private(set) var generation = 0
    private var last = Date.distantPast
    /// A cold launch reaches `.active` too, and it is the one activation that is not a
    /// wake: nothing has been suspended and there is nothing to recover. Bumping there
    /// tears down the session the launch itself just opened, which shows up as a shell
    /// that connects, dies and reconnects before the user has touched anything.
    private var coldStart = true

    /// One bump per genuine return to the foreground.
    func active() {
        let now = Date()
        if coldStart {
            coldStart = false
            last = now
            return
        }
        guard now.timeIntervalSince(last) > 1.5 else { return }
        last = now
        generation += 1
    }

    /// Called when the app leaves the foreground, so the next `.active` always counts as a
    /// wake however briefly the app was away — a phone that locks for ten seconds kills a
    /// socket just as dead as one that locks overnight.
    func background() {
        last = .distantPast
    }
}
