import SwiftUI
import UIKit

/// Connect this iPhone to an Omarchy box.
///
/// This is the screen the whole app depends on, because the first thing a stock Omarchy
/// box does to a new SSH client is refuse it: sshd is disabled and `ufw default deny
/// incoming` closes port 22. Nothing else in this app works until someone runs one
/// command on the machine, so that command is the screen — copyable, scannable, and
/// spelled out rather than described.
///
/// Two routes, both ending in `omarchy-setup-security-sshd`, because Omarchy has exactly
/// one remote-in feature and those are its two flags. The Secure Enclave route is first
/// and is the better one; the GitHub route is here because "use my git keys" is what
/// people actually ask for, and because pretending it does not exist would not stop them
/// using it.
struct EnrollView: View {
    @Environment(KeyRing.self) private var keys
    @Environment(\.dismiss) private var dismiss

    @State private var enrollment = Enrollment()
    @State private var importing = false

    /// The Enclave key this phone would enroll. First one wins: a second Enclave key is
    /// a thing a user can make, but only one of them can be "this phone's key" on a
    /// screen whose whole job is to be unambiguous.
    private var enclaveKey: KeyRecord? {
        keys.keys.first { $0.isEnclave && !$0.publicLine.isEmpty }
    }

    private var importedKeys: [KeyRecord] {
        keys.keys.filter { !$0.isEnclave }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        routes
                        switch enrollment.route {
                        case .thisPhone: thisPhone
                        case .githubKeys: githubKeys
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
            .sheet(isPresented: $importing) { KeyImporter() }
        }
        .tint(Theme.accent)
    }

    private var routes: some View {
        HStack(spacing: 8) {
            ForEach(Enrollment.Route.allCases) { route in
                Button(route.label) { enrollment.route = route }
                    .buttonStyle(CraftButton(tint: enrollment.route == route ? Theme.accent : Theme.dim))
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - the Secure Enclave route

    @ViewBuilder
    private var thisPhone: some View {
        if let key = enclaveKey {
            let command = Omarchy.enrollCommand(publicLine: key.publicLine)
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "one command on the box")
                Text("Open a terminal on the box with \(Omarchy.terminalKeybind) and run this. It switches sshd on, opens port 22 in the firewall and authorizes this phone — all three, in one command. A stock Omarchy install has SSH off and port 22 closed, so this is the step that makes everything else possible.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                CommandBlock(command: command, caption: "paste it into a terminal on the box")
                VStack(alignment: .leading, spacing: 6) {
                    QRCode(text: command)
                    Text("The same command as a QR, for pointing a camera at rather than retyping.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                if let fingerprint = OpenSSHWire.fingerprint(ofPublicLine: key.publicLine) {
                    Text("this phone's key · \(fingerprint)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                        .textSelection(.enabled)
                }
                Text("No terminal handy? \(Omarchy.menuPath), then “Paste key manually”, and paste the key from the Keys tab.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "first, a key for this phone")
                Text("A P-256 key made inside the Secure Enclave. The private half never leaves the chip: it cannot be copied off this phone, backed up, or restored onto another device. That is why this route is the good one — the box ends up trusting a key nothing can steal from the app.")
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
    }

    // MARK: - the GitHub route

    private var githubKeys: some View {
        let user = Omarchy.githubUsername(enrollment.username)
        let command = Omarchy.githubCommand(username: user)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "authorize your github keys")
                Text("Omarchy's own `--gh-keys` flag fetches https://github.com/<user>.keys and appends every key it finds to authorized_keys. Run this on the box after \(Omarchy.terminalKeybind):")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                HStack(alignment: .bottom, spacing: 10) {
                    CraftField(label: "github username", text: $enrollment.username,
                               placeholder: "octocat")
                    Button(enrollment.checking ? "checking" : "check") {
                        Task { await enrollment.check() }
                    }
                    .buttonStyle(CraftButton())
                    .disabled(enrollment.checking || user.isEmpty)
                }
                if let lookup = enrollment.lookup {
                    Text(lookup.summary)
                        .font(Theme.mono(11))
                        .foregroundStyle(lookup.isUsable ? Theme.live : Theme.alarm)
                }
                Text("Checking here beats finding out at the box: a username that does not exist, and a user who has published nothing, both leave `--gh-keys` authorizing precisely nothing.")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.faint)
                CommandBlock(command: command, caption: "paste it into a terminal on the box")
                VStack(alignment: .leading, spacing: 6) {
                    QRCode(text: command)
                    Text("The same command as a QR.")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "then bring the private key here")
                Text("This route authorizes keys whose private half is on your laptop, not on this phone — so the box will trust a key this app does not have. To use it, you have to import that private key, and then the app holds the real private bytes itself. That is weaker than the Secure Enclave key, which cannot be extracted from this device at all.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                Button("import a private key") { importing = true }
                    .buttonStyle(CraftButton())
                if !importedKeys.isEmpty {
                    Text("imported: " + importedKeys.map(\.name).joined(separator: ", "))
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.faint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "if github publishes nothing")
                Text("Only keys of type *authentication* appear at https://github.com/<user>.keys. A key added as a *signing* key is invisible there, so `--gh-keys` silently authorizes nothing. Publish it properly:")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
                CommandBlock(command: Omarchy.publishAuthenticationKey,
                             caption: "run on the machine that holds the key")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}
