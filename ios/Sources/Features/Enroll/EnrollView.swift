import SwiftUI
import UIKit

/// Connect this iPhone to an Omarchy box.
///
/// One key — the Secure Enclave P-256 key, whose private half cannot leave the chip —
/// and three ways to make a box trust it. The screen is ordered by cost, cheapest
/// first, because the right answer depends on something the app already knows:
///
/// 1. **A box the terminal is on right now** — one tap, no new connection, no walk.
/// 2. **Your GitHub account** — paste the public key at `github.com/settings/ssh/new`
///    and the box command shrinks to a username, because Omarchy already knows how to
///    fetch keys from there. The app holds no token and touches no account; the copy
///    stays on this phone, clipboard to Safari.
/// 3. **The first box, the long way** — one command carrying the whole key, typed at
///    its keyboard. Nothing can remove this one: a stock Omarchy install has sshd off
///    and port 22 closed by `ufw default deny incoming`, and no credential presented
///    over a network opens a closed port.
struct EnrollView: View {
    @Environment(KeyRing.self) private var keys
    @Environment(TerminalStore.self) private var terminal
    @Environment(HostBook.self) private var hosts
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var enrollment = Enrollment()

    /// The GitHub account the key was pasted into, typed once and kept.
    ///
    /// Typed because this route never obtains a token: nothing but the user can say
    /// whose account the key now sits on. Stored rather than asked for every time
    /// because the box command is the thing a user comes back to this screen to re-read.
    @AppStorage("github.pasted.login") private var pastedLogin = ""

    /// The Enclave key this phone would enroll. First one wins: a second Enclave key is
    /// a thing a user can make, but only one of them can be "this phone's key" on a
    /// screen whose whole job is to be unambiguous.
    private var enclaveKey: KeyRecord? {
        keys.keys.first { $0.isEnclave && !$0.publicLine.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let key = enclaveKey {
                            if terminal.isLive { liveBox(key) }
                            pasteToGitHub(key)
                            boxCommand(key)
                            identity(key)
                        } else {
                            generate
                        }
                        if let failure = keys.failure {
                            Text(failure)
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.alarm)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .panel()
                        }
                    }
                    .padding(12)
                }
            }
            .navigationTitle("connect to omarchy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }.tint(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
    }

    // MARK: - the key

    private var generate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "first, a key for this phone")
            Text("A P-256 key made inside the Secure Enclave. The private half never leaves the chip: it cannot be copied off this phone, backed up, or restored onto another device. Everything below authorizes *this* key — the app never needs to hold a private key of yours again.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            Button("generate this phone's key") {
                keys.generateEnclaveKey(named: UIDevice.current.name)
            }
            .buttonStyle(CraftButton())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func identity(_ key: KeyRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "this phone's key")
            if let fingerprint = OpenSSHWire.fingerprint(ofPublicLine: key.publicLine) {
                Text(fingerprint)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
                    .textSelection(.enabled)
            }
            Text("Compare it with what the box trusts: \(Omarchy.listAuthorizedKeys)")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - a box the phone can already reach

    /// One tap, when the terminal is connected to a box.
    ///
    /// This is the answer for every device after the first, and the one `--gh-keys`
    /// structurally cannot give: Omarchy's script `curl`s `github.com/<user>.keys` once,
    /// when it runs, so a key published afterwards is invisible to a box that already
    /// ran it. Appending over the live session needs no script, no sudo, and no new
    /// socket — so it cannot trip the firewall's six-connections-in-thirty-seconds ban
    /// either.
    private func liveBox(_ key: KeyRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "the box you are connected to")
            Text("The shell is live on \(hosts.selected?.displayName ?? "this box"), which means this key can be authorized over that connection right now — no command, no walking anywhere. It opens no new connection, so it cannot trip the firewall's rate limit.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            Button(enrollment.authorizing ? "authorizing" : "authorize this key over the live session") {
                Task { await enrollment.authorizeOnLiveBox(key, over: terminal) }
            }
            .buttonStyle(CraftButton())
            .disabled(enrollment.authorizing)
            switch enrollment.authorize {
            case .authorized(let address):
                Text("Authorized on \(address). The box trusts this phone.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.live)
            case .failed(let why):
                Text(why)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.alarm)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - github

    /// Put the key on GitHub **by hand**: no token, no account access, no app
    /// registration to keep alive.
    ///
    /// This ends where a device-flow sign-in would have — this phone's public key
    /// listed at `github.com/<you>.keys`, the URL Omarchy fetches — for none of the
    /// cost. `POST /user/keys` needs write access to *every* SSH key on the account,
    /// granted to an app, indefinitely, so that it can add one key once. Pasting does
    /// not: the app copies a public key to the clipboard and opens Safari, and the
    /// account is touched only by its owner.
    ///
    /// It also keeps the copy *on one device*. The awkward step this whole screen is
    /// fighting is a hundred characters of base64 crossing from a phone to a keyboard
    /// somewhere else; clipboard-to-Safari stays on the phone, and what crosses to the
    /// box afterwards is a GitHub username.
    ///
    /// The username is typed rather than discovered because without a token there is
    /// nothing to ask. It is sanitized on the way into the command by
    /// `Omarchy.githubUsername`, since that command is pasted into a root-capable shell.
    @ViewBuilder
    private func pasteToGitHub(_ key: KeyRecord) -> some View {
        let login = Omarchy.githubUsername(pastedLogin)
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "or put the key on github yourself")
            Text("Same destination, no access granted to anything: copy this phone's public key, paste it at github.com/settings/ssh/new, and leave the type on *Authentication*. The app never holds a token and never touches your account — GitHub is only being used as the place Omarchy already knows how to fetch keys from.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            CommandBlock(command: key.publicLine, caption: "copy, then paste it into the Key field")
            Button("open github.com/settings/ssh/new") { openURL(Omarchy.githubNewKeyURL) }
                .buttonStyle(CraftButton())
            CraftField(label: "your github username", text: $pastedLogin, placeholder: "octocat")
            if !login.isEmpty {
                Text("Once the key is listed, run this at the box's keyboard. It authorizes every key on that account, not only this phone's.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                CommandBlock(command: Omarchy.githubCommand(username: login),
                             caption: "paste it into a terminal on the box")
                if let listing = Omarchy.githubKeysURL(username: login) {
                    Button("check github.com/\(login).keys") { openURL(listing) }
                        .buttonStyle(CraftButton(tint: Theme.dim))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    // MARK: - the one command that cannot be avoided

    /// The command for a box that has never heard of this phone, carrying the whole key.
    ///
    /// A stock Omarchy install has sshd off and `ufw default deny incoming` with only
    /// LocalSend's 53317 open. Nothing reaches that box over a network, so somebody
    /// opens a terminal on it with `Super + Return` once. This is the form that needs
    /// nothing else to exist — no GitHub account, no second machine — and the QR code
    /// is here because retyping a hundred characters of base64 is how the step
    /// actually fails. The panel above shortens it to a username, when you want that.
    private func boxCommand(_ key: KeyRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "one command on the box")
            Text("Open a terminal on the box with \(Omarchy.terminalKeybind) and run this. It switches sshd on, opens port 22 in the firewall, and authorizes this phone — all three, in one command. A stock Omarchy install has SSH off and port 22 closed, so this is the step that makes everything else possible.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            CommandBlock(command: Omarchy.enrollCommand(publicLine: key.publicLine),
                         caption: "paste it into a terminal on the box")
            VStack(alignment: .leading, spacing: 6) {
                QRCode(text: Omarchy.enrollCommand(publicLine: key.publicLine))
                Text("The same command as a QR, for pointing a camera at rather than retyping.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Text("No terminal handy? \(Omarchy.menuPath), then “Paste key manually”, and paste the key from the Keys tab.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
