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
/// So every return to the foreground **from a real backgrounding** bumps this counter,
/// and the terminal and agent screens treat a bump as "drop what you are holding, it is
/// probably a corpse; re-probe and re-attach".
///
/// What counts is the narrow part. `scenePhase` reaches `.inactive` for every transient
/// interruption — Control Centre, Notification Centre, the app switcher, a call banner,
/// a permission alert — and none of those suspends the process or touches its sockets.
/// Treating them as wakes tore down healthy PTYs, losing the user's cwd, environment and
/// whatever was running in the foreground, and cleared `busy` in the middle of an agent
/// turn. A timing heuristic cannot separate the two either: a session that has been up
/// for an hour and is interrupted for two seconds clears any elapsed-time guard just as
/// easily as a genuine overnight suspend. Only `.background` is evidence, so only
/// `.background` is recorded.
@MainActor
@Observable
final class Wake {
    private(set) var generation = 0
    /// Set by `background()` and cleared by the bump it causes. Starting `false` is also
    /// the cold-start suppression: a launch reaches `.active` without ever having been
    /// backgrounded, and bumping there would tear down the session the launch itself
    /// just opened — a shell that connects, dies and reconnects before the user has
    /// touched anything.
    private var wasBackgrounded = false

    /// One bump per genuine return to the foreground.
    func active() {
        guard wasBackgrounded else { return }
        wasBackgrounded = false
        generation += 1
    }

    /// Called when the app actually leaves the foreground, so the next `.active` counts
    /// as a wake however briefly the app was away — a phone that locks for ten seconds
    /// kills a socket just as dead as one that locks overnight.
    func background() {
        wasBackgrounded = true
    }
}
