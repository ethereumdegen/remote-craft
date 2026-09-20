import SwiftUI
import UIKit

/// Connect this iPhone to an Omarchy box.
///
/// One route now, not two. It used to branch on "this phone's key" versus "my GitHub
/// keys", and the second branch ended by importing a private key off a laptop — the app
/// then held real private bytes, which is strictly weaker than an Enclave key nothing
/// can extract from the chip. Signing in to GitHub folds the branches together: the app
/// publishes the *Enclave* key to the account, and `--gh-keys` authorizes that.
///
/// The screen is ordered by cost, cheapest first, because the right answer depends on
/// something the app already knows:
///
/// 1. **A box the terminal is on right now** — one tap, no new connection, no walk.
/// 2. **The first box** — one command, typed at its keyboard. Nothing can remove this
///    one: a stock Omarchy install has sshd off and port 22 closed by `ufw default deny
///    incoming`, and no credential presented over a network opens a closed port. Signing
///    in only shortens the command from a hundred characters of base64 to a username.
struct EnrollView: View {
    @Environment(KeyRing.self) private var keys
    @Environment(GitHubAccount.self) private var github
    @Environment(TerminalStore.self) private var terminal
    @Environment(HostBook.self) private var hosts
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    @State private var enrollment = Enrollment()

    /// The Enclave key this phone would enroll. First one wins: a second Enclave key is
    /// a thing a user can make, but only one of them can be "this phone's key" on a
    /// screen whose whole job is to be unambiguous.
    private var enclaveKey: KeyRecord? {
        keys.keys.first { $0.isEnclave && !$0.publicLine.isEmpty }
    }

    /// Once the key is on the account, the box command is the short one. Before that it
    /// has to carry the whole key.
    private var published: Bool {
        github.isSignedIn && (enrollment.publish?.isUsable ?? false)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let key = enclaveKey {
                            if terminal.isLive { liveBox(key) }
                            signIn(key)
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
        // A device-flow login polls for up to fifteen minutes, and GitHub allows the
        // whole registration only 50 verifications an hour. A sheet the user swiped away
        // must not keep spending that on their behalf.
        .onDisappear { enrollment.cancelSignIn() }
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

    @ViewBuilder
    private func signIn(_ key: KeyRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "shorten the box command")
            if !GitHubApp.isConfigured {
                Text("\(GitHubApp.unconfigured) Without it the box command below carries the whole key, which is what the QR code is for.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
            } else if let login = github.login {
                Text("Signed in as \(login). Publishing this phone's key to that account puts it at github.com/\(login).keys, which is the URL Omarchy's `--gh-keys` reads — so the box command becomes a username instead of a hundred characters of base64.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                HStack(spacing: 10) {
                    Button(enrollment.publishing ? "publishing" : "publish this phone's key") {
                        Task { await enrollment.publishKey(key, as: github) }
                    }
                    .buttonStyle(CraftButton())
                    .disabled(enrollment.publishing)
                    Button("sign out") {
                        github.signOut()
                        enrollment.forgetResults()
                    }
                    .buttonStyle(CraftButton(tint: Theme.dim))
                }
                if let outcome = enrollment.publish {
                    Text(outcome.summary)
                        .font(Theme.mono(11))
                        .foregroundStyle(outcome.isUsable ? Theme.live : Theme.alarm)
                }
            } else {
                Text("Sign in and the app publishes this phone's Enclave key to your account, so the box command becomes `--gh-keys <you>` — short enough to type at the box's own keyboard. Nothing is imported: the private half still never leaves this chip.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                if let code = enrollment.code {
                    deviceCode(code)
                } else {
                    Button(enrollment.signingIn ? "starting" : "sign in with github") {
                        enrollment.signInToGitHub(as: github)
                    }
                    .buttonStyle(CraftButton())
                    .disabled(enrollment.signingIn)
                }
            }
            if let note = enrollment.signIn {
                Text(note)
                    .font(Theme.mono(11))
                    .foregroundStyle(github.isSignedIn ? Theme.live : Theme.alarm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// The device code, which the user types on github.com.
    ///
    /// Shown big and selectable rather than only opened in a browser: the sign-in can
    /// legitimately be completed on a different machine, and a code that only exists
    /// inside a tap target cannot be.
    private func deviceCode(_ code: DeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(code.userCode)
                .font(Theme.mono(22, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Text("Enter it at \(code.verificationURL.absoluteString). This screen is waiting — it will notice by itself.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
            HStack(spacing: 10) {
                Button("open github") { openURL(code.verificationURL) }
                    .buttonStyle(CraftButton())
                Button("cancel") { enrollment.cancelSignIn() }
                    .buttonStyle(CraftButton(tint: Theme.dim))
            }
        }
    }

    // MARK: - the one command that cannot be avoided

    /// The command for a box that has never heard of this phone.
    ///
    /// A stock Omarchy install has sshd off and `ufw default deny incoming` with only
    /// LocalSend's 53317 open. No sign-in reaches that box, so somebody opens a terminal
    /// on it with `Super + Return` once. What sign-in changes is the length: a published
    /// key means `--gh-keys andrew`, which a person reads off a phone and types. Without
    /// one it is the whole `authorized_keys` line, and the QR code exists because
    /// retyping a hundred characters of base64 is how this step actually fails.
    private func boxCommand(_ key: KeyRecord) -> some View {
        let command = published
            ? Omarchy.githubCommand(username: github.login ?? "")
            : Omarchy.enrollCommand(publicLine: key.publicLine)
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "one command on the box")
            Text("Open a terminal on the box with \(Omarchy.terminalKeybind) and run this. It switches sshd on, opens port 22 in the firewall, and authorizes this phone — all three, in one command. A stock Omarchy install has SSH off and port 22 closed, so this is the step that makes everything else possible.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.dim)
            CommandBlock(command: command, caption: "paste it into a terminal on the box")
            if published {
                Text("Short because your key is on GitHub — no QR needed, and `--gh-keys` authorizes every key published on that account, not only this one. The second half runs only on an Omarchy too old for that flag, where the same script asks for the username instead.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    QRCode(text: command)
                    Text("The same command as a QR, for pointing a camera at rather than retyping.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            Text("No terminal handy? \(Omarchy.menuPath), then “Paste key manually”, and paste the key from the Keys tab.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
