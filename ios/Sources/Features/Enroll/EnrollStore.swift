import Foundation
import Observation

/// The state of the enrollment screen.
///
/// There is one key — the Secure Enclave P-256 key this phone made on first use — and
/// three ways to get a box to trust it, none of which this app can do on the user's
/// behalf without something the user provides. Only one of them has state worth holding:
/// authorizing over a live SSH session, which is a command running on another machine
/// and can fail halfway.
///
/// The other two are stateless by construction. Pasting the key into GitHub happens in
/// Safari, on the account's own settings page, with the app holding no token and
/// therefore having nothing to remember. Typing the `--key=` command at the box's
/// keyboard happens off-device entirely. Both used to be routed through a device-flow
/// sign-in that published the key with `POST /user/keys`; that traded write access to
/// every SSH key on the account, held indefinitely, for a copy the user can perform in
/// two taps, and it is gone.
///
/// What none of them removes is the one trip to the box. A stock Omarchy install has
/// sshd off and `ufw default deny incoming`; no credential presented over a network can
/// open a port that is closed. After that first trip, `RemoteEnroll` handles every
/// subsequent key over the connection that already works.
///
/// Screen-scoped, held as `@State` by the view.
@MainActor
@Observable
final class Enrollment {
    private(set) var authorize: AuthorizeResult?
    private(set) var authorizing = false

    /// Append this key to `~/.ssh/authorized_keys` on the box the terminal is on.
    ///
    /// The second-device answer, and the one no amount of GitHub gets you: Omarchy's
    /// `curl` of `github.com/<user>.keys` is a snapshot, so a box that already ran it
    /// will never see a key added afterwards. This rides the SSH connection that is
    /// already up, costs no new socket, and therefore cannot trip Omarchy's
    /// `ufw limit 22/tcp` ban.
    func authorizeOnLiveBox(_ record: KeyRecord, over terminal: TerminalStore) async {
        guard !authorizing else { return }
        authorize = nil
        authorizing = true
        defer { authorizing = false }
        authorize = await terminal.authorize(record.publicLine)
    }

    func forgetResults() {
        authorize = nil
    }
}
