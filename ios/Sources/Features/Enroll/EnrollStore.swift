import Foundation
import Observation

/// The state of the enrollment screen.
///
/// There used to be two routes here — this phone's Enclave key via `--key=`, and "my
/// GitHub keys" via `--gh-keys` — and the second one ended by importing a private key
/// off a laptop, which is strictly weaker than the key the Secure Enclave will not let
/// anyone extract. Signing in to GitHub collapses them into one: the app publishes the
/// *Enclave* key to the account, and then `--gh-keys` authorizes the key that cannot be
/// stolen from this phone. There is no longer any reason for the app to hold private
/// bytes, so it no longer offers to.
///
/// What sign-in does not do is remove the one trip to the box. A stock Omarchy install
/// has sshd off and `ufw default deny incoming`; no credential presented over a network
/// can open a port that is closed. It makes that trip *typeable* — a username instead of
/// a hundred characters of base64 — and after it, `RemoteEnroll` handles every
/// subsequent key over the connection that already works.
///
/// Screen-scoped, held as `@State` by the view: a half-finished device-flow login is not
/// worth resuming across a dismissal, and the token that would be worth keeping is in
/// the Keychain the moment it exists.
@MainActor
@Observable
final class Enrollment {
    /// The code GitHub wants typed at `github.com/login/device`, while it is live.
    private(set) var code: DeviceCode?
    /// Nil until something has been attempted. Set for every terminal outcome of a
    /// sign-in, including the ones that are this build's fault rather than the user's.
    private(set) var signIn: String?
    private(set) var signingIn = false

    private(set) var publish: PublishOutcome?
    private(set) var publishing = false

    private(set) var authorize: AuthorizeResult?
    private(set) var authorizing = false

    /// The polling loop. Held so dismissing the sheet stops it: the loop runs for up to
    /// fifteen minutes and GitHub rate-limits verification to 50 submissions an hour per
    /// application, so an abandoned login that keeps polling spends a budget shared by
    /// every user of the registration.
    /// Cancellation is `cancelSignIn`, called from the sheet's `onDisappear`, and not a
    /// `deinit`: `poller` is main-actor isolated and a `deinit` is not, so reaching it
    /// from there does not compile. The loop holds `self` weakly and stops at
    /// `expiresAt` regardless, so the worst case of a missed cancel is bounded.
    private var poller: Task<Void, Never>?

    // MARK: - sign in

    /// Ask GitHub for a device code, then poll until it is answered.
    ///
    /// The device flow, not the web flow, because GitHub still requires `client_secret`
    /// at the token endpoint even with PKCE — so a web-flow app needs a server to hold
    /// that secret, and this app has deliberately never had one. The device flow
    /// exchanges a `client_id` alone, which is not a secret and ships in the bundle.
    ///
    /// The schedule lives here rather than inside `GitHubAuth.poll`, which performs
    /// exactly one request: a network helper that sleeps in a loop cannot be cancelled
    /// cleanly and cannot be tested without waiting.
    func signInToGitHub(as account: GitHubAccount) {
        guard !signingIn else { return }
        poller?.cancel()
        signIn = nil
        signingIn = true

        poller = Task { [weak self] in
            defer { self?.signingIn = false; self?.code = nil }

            switch await GitHubAuth.requestDeviceCode() {
            case .issued(let issued):
                self?.code = issued
                await self?.pollUntilAnswered(issued, as: account)
            case let other:
                self?.signIn = other.summary
            }
        }
    }

    /// One request per interval until GitHub answers or the code dies.
    ///
    /// Bounded by `expiresAt` rather than by an attempt count: the interval grows on
    /// `slow_down`, so counting attempts would end the login at a different real time
    /// depending on how the server felt, and the user is looking at a code with a
    /// deadline on it.
    private func pollUntilAnswered(_ issued: DeviceCode, as account: GitHubAccount) async {
        var interval = issued.interval

        while !Task.isCancelled, Date() < issued.expiresAt {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }

            switch await GitHubAuth.poll(issued) {
            case .pending:
                continue
            case .slowDown:
                // GitHub's documented remedy, and the only one: a client that ignores
                // this keeps the offending rate and gets rejected again.
                interval += GitHubAuth.slowDownPenalty
            case .token(let token):
                guard let login = await GitHubAuth.login(token: token) else {
                    signIn = "Signed in, but GitHub would not say which account. Try again."
                    return
                }
                account.store(token: token, login: login)
                signIn = "Signed in as \(login)."
                return
            case .denied:
                signIn = "That sign-in was refused on github.com."
                return
            case .expired:
                signIn = "The code expired before it was entered. Start again."
                return
            case .failed(let why):
                signIn = why
                return
            }
        }
        if !Task.isCancelled {
            signIn = "The code expired before it was entered. Start again."
        }
    }

    /// Stop polling and forget the code. Called when the sheet goes away.
    func cancelSignIn() {
        poller?.cancel()
        poller = nil
        signingIn = false
        code = nil
    }

    // MARK: - publish

    /// Put this phone's public key on the GitHub account, so `--gh-keys` authorizes it.
    ///
    /// The Enclave key is `ecdsa-sha2-nistp256`, which GitHub accepts as an
    /// authentication key and therefore publishes at `github.com/<user>.keys` — the URL
    /// Omarchy's script reads. A *signing* key is not published there, and that single
    /// word used to be the commonest way this route silently authorized nothing; going
    /// through `POST /user/keys` removes the choice, and with it the trap.
    func publishKey(_ record: KeyRecord, as account: GitHubAccount) async {
        guard !publishing else { return }
        publish = nil
        publishing = true
        defer { publishing = false }

        guard let token = account.token() else {
            publish = .unauthorized
            return
        }
        publish = await GitHubAuth.publish(line: record.publicLine,
                                           title: record.name,
                                           token: token)
        // A token GitHub no longer honours is worse than no token: the screen would go
        // on saying "signed in as …" over a button that fails every time it is pressed.
        if publish == .unauthorized { account.signOut() }
    }

    // MARK: - authorize over the live session

    /// Append this key to `~/.ssh/authorized_keys` on the box the terminal is on.
    ///
    /// The second-device answer, and the one no amount of GitHub gets you: `--gh-keys`
    /// is a snapshot, so a box that already ran it will never see a key published
    /// afterwards. This rides the SSH connection that is already up, costs no new
    /// socket, and therefore cannot trip Omarchy's `ufw limit 22/tcp` ban.
    func authorizeOnLiveBox(_ record: KeyRecord, over terminal: TerminalStore) async {
        guard !authorizing else { return }
        authorize = nil
        authorizing = true
        defer { authorizing = false }
        authorize = await terminal.authorize(record.publicLine)
    }

    func forgetResults() {
        publish = nil
        authorize = nil
        signIn = nil
    }
}
